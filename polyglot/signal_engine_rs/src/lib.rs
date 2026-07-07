//! signal_engine_rs — Rust hot path for Blaque Baux signal engine.
//!
//! Ports from Python (signal_engine.py):
//!   EnhancedKalmanFilter      → KalmanFilter3State
//!   FastBayesianUpdater       → NigBayesianUpdater
//!   StreamingFeatureEngine    → WelfordStreamer
//!   AdaptiveShrinkageEstimator→ JamesSteinShrinkage
//!   HybridSignalEngine        → HybridEngine
//!
//! All hot-path math runs in Rust. Python orchestrator calls
//! `engine.update_bar(returns)` and gets back (alpha, uncertainty, active_mask)
//! as numpy arrays — zero-copy via PyO3 numpy integration.
//!
//! Build: `maturin develop --release` (or `pip install .`)
//! Import: `from signal_engine_rs import HybridEngine`

use std::collections::VecDeque;
use pyo3::prelude::*;
use pyo3::types::PyDict;
use numpy::{PyArray1, PyReadonlyArray1};
use nalgebra::{Matrix3, Matrix1x3, Matrix3x1, Vector3};

// ══════════════════════════════════════════════════════════════════════════════
// LAYER 1 — ENHANCED KALMAN FILTER (every bar, target <5μs)
// ══════════════════════════════════════════════════════════════════════════════
//
// 3-state Kalman: [alpha, beta, gamma]
//   alpha = signal estimate (passed to QP)
//   beta  = trend (persistent drift)
//   gamma = decaying seasonality (0.95× decay)
//
// Adaptive noise: every 20 updates, Q and R recalibrated from
// realized innovation variance. Prevents stale filter in regime shifts.

#[pyclass]
#[derive(Clone)]
struct KalmanFilter3State {
    // State transition matrix F
    f: Matrix3<f32>,
    // Observation matrix H (1×3)
    h: Matrix1x3<f32>,
    // Process noise Q (adaptive)
    q: Matrix3<f32>,
    // Observation noise R (adaptive, scalar stored as f32)
    r: f32,
    // State vector x (3×1)
    x: Vector3<f32>,
    // Error covariance P (3×3)
    p: Matrix3<f32>,
    // Innovation history for adaptive noise
    innovations: VecDeque<f32>,
    update_count: u32,
}

impl KalmanFilter3State {
    fn new() -> Self {
        // F: alpha += beta, beta unchanged, gamma *= 0.95
        let f = Matrix3::new(
            1.0, 1.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 0.95,
        );
        let h = Matrix1x3::new(1.0, 0.0, 0.0);

        Self {
            f,
            h,
            q: Matrix3::identity() * 0.001,
            r: 0.01,
            x: Vector3::zeros(),
            p: Matrix3::identity() * 10.0,
            innovations: VecDeque::with_capacity(100),
            update_count: 0,
        }
    }

    /// One Kalman update. Returns (alpha, uncertainty, innovation).
    fn update(&mut self, observation: f32) -> (f32, f32, f32) {
        // ── Predict ──
        let x_pred = self.f * self.x;
        let p_pred = self.f * self.p * self.f.transpose() + self.q;

        // ── Innovation ──
        let y_pred = (self.h * x_pred)[(0, 0)];
        let innovation = observation - y_pred;

        // ── Kalman gain ──
        let s = (self.h * p_pred * self.h.transpose())[(0, 0)] + self.r + 1e-10;
        // K = P_pred * H^T / S  (3×1)
        let k = (p_pred * self.h.transpose()) / s;

        // ── Update ──
        self.x = x_pred + k * innovation;
        // P = P_pred - K * H * P_pred
        let k_col = Matrix3x1::new(k[(0, 0)], k[(1, 0)], k[(2, 0)]);
        self.p = p_pred - k_col * self.h * p_pred;

        // ── Adaptive noise (every 20 updates) ──
        if self.innovations.len() >= 100 {
            self.innovations.pop_front();
        }
        self.innovations.push_back(innovation.abs());
        self.update_count += 1;

        if self.update_count % 20 == 0 {
            self.adapt_noise();
        }

        let alpha = self.x[0];
        let uncertainty = self.p[(0, 0)].max(0.0).sqrt();
        (alpha, uncertainty, innovation)
    }

    fn adapt_noise(&mut self) {
        if self.innovations.len() < 10 {
            return;
        }
        // Use last 20 innovations
        let recent: Vec<f32> = self.innovations.iter()
            .rev()
            .take(20)
            .copied()
            .collect();
        let n = recent.len() as f32;
        let mean = recent.iter().sum::<f32>() / n;
        let emp_var = recent.iter().map(|v| (v - mean).powi(2)).sum::<f32>() / n;

        // Observation noise tracks 10% of empirical innovation variance
        self.r = (emp_var * 0.10).max(0.001);

        // Process noise: expand in high-noise, contract in calm
        if emp_var > 0.10 {
            self.q *= 1.1;
            self.q = self.q.map(|v| v.clamp(0.0001, 0.1));
        } else if emp_var < 0.01 {
            self.q *= 0.9;
            self.q = self.q.map(|v| v.clamp(0.0001, 0.1));
        }
    }

    fn reset(&mut self, alpha: f32, uncertainty: f32) {
        self.x = Vector3::new(alpha, 0.0, 0.0);
        self.p = Matrix3::identity() * uncertainty;
    }
}


// ══════════════════════════════════════════════════════════════════════════════
// LAYER 2 — FAST BAYESIAN UPDATER (NIG conjugate, target <1μs)
// ══════════════════════════════════════════════════════════════════════════════
//
// Normal-Inverse-Gamma conjugate prior — closed-form O(1) update.
// Each asset maintains its own posterior (mu, kappa, alpha, beta).
// Posterior predictive is Student-t (naturally fat-tailed uncertainty).

#[derive(Clone, Debug)]
struct NigPosterior {
    mu: f64,
    kappa: f64,
    alpha: f64,
    beta: f64,
}

impl NigPosterior {
    fn new(mu_0: f64, kappa_0: f64, alpha_0: f64, beta_0: f64) -> Self {
        Self { mu: mu_0, kappa: kappa_0, alpha: alpha_0, beta: beta_0 }
    }

    /// O(1) conjugate update. Returns (posterior_mean, posterior_std).
    #[inline(always)]
    fn update(&mut self, observation: f64) -> (f64, f64) {
        let kappa_n = self.kappa + 1.0;
        let mu_n = (self.kappa * self.mu + observation) / kappa_n;
        let alpha_n = self.alpha + 0.5;
        let beta_n = self.beta
            + (self.kappa * (observation - self.mu).powi(2)) / (2.0 * kappa_n);

        self.mu = mu_n;
        self.kappa = kappa_n;
        self.alpha = alpha_n;
        self.beta = beta_n;

        let post_var = beta_n / (alpha_n * kappa_n);
        (mu_n, post_var.max(1e-10).sqrt())
    }

    fn belief(&self) -> (f64, f64) {
        let post_var = self.beta / (self.alpha * self.kappa);
        (self.mu, post_var.max(1e-10).sqrt())
    }
}


// ══════════════════════════════════════════════════════════════════════════════
// STREAMING FEATURES — WELFORD'S ALGORITHM (O(1), zero-alloc after init)
// ══════════════════════════════════════════════════════════════════════════════

#[derive(Clone, Debug)]
struct WelfordStreamer {
    decay: f64,
    count: u64,
    mean: f64,
    m2: f64,
    ewm_mean: f64,
    ewm_var: f64,
}

impl WelfordStreamer {
    fn new(decay: f64) -> Self {
        Self { decay, count: 0, mean: 0.0, m2: 0.0, ewm_mean: 0.0, ewm_var: 0.0 }
    }

    /// O(1) update. Returns (ewm_mean, ewm_vol, z_score, global_mean, global_std).
    #[inline(always)]
    fn update(&mut self, value: f64) -> (f64, f64, f64, f64, f64) {
        self.count += 1;

        // Welford's online mean/variance
        let delta = value - self.mean;
        self.mean += delta / (self.count as f64);
        let delta2 = value - self.mean;
        self.m2 += delta * delta2;

        // EWM
        let alpha = 1.0 - self.decay;
        self.ewm_mean = self.decay * self.ewm_mean + alpha * value;
        self.ewm_var = self.decay * self.ewm_var
            + alpha * (value - self.ewm_mean).powi(2);

        let variance = if self.count > 1 {
            self.m2 / (self.count as f64 - 1.0)
        } else {
            0.0
        };
        let ewm_vol = self.ewm_var.max(0.0).sqrt();
        let z_score = (value - self.ewm_mean) / (ewm_vol + 1e-8);
        let global_std = variance.max(0.0).sqrt();

        (self.ewm_mean, ewm_vol, z_score, self.mean, global_std)
    }

    fn reset(&mut self) {
        self.count = 0;
        self.mean = 0.0;
        self.m2 = 0.0;
        self.ewm_mean = 0.0;
        self.ewm_var = 0.0;
    }
}


// ══════════════════════════════════════════════════════════════════════════════
// JAMES-STEIN SHRINKAGE (cross-sectional, per-bar)
// ══════════════════════════════════════════════════════════════════════════════

#[derive(Clone, Debug)]
struct JamesSteinShrinkage {
    prior_mean: f64,
    prior_std: f64,
    ema_decay: f64,
}

impl JamesSteinShrinkage {
    fn new() -> Self {
        Self { prior_mean: 0.0, prior_std: 0.05, ema_decay: 0.95 }
    }

    /// Cross-sectional shrinkage. Mutates estimates in-place.
    /// Returns shrinkage intensity.
    fn shrink(
        &mut self,
        estimates: &mut [f32],
        std_errors: &mut [f32],
    ) -> f64 {
        let n = estimates.len();
        if n < 3 {
            return 0.5;
        }

        // Update empirical Bayes prior
        let cross_mean: f64 = estimates.iter().map(|v| *v as f64).sum::<f64>() / n as f64;
        let cross_std: f64 = {
            let var = estimates.iter()
                .map(|v| (*v as f64 - cross_mean).powi(2))
                .sum::<f64>() / n as f64;
            var.sqrt()
        };
        self.prior_mean = self.ema_decay * self.prior_mean
            + (1.0 - self.ema_decay) * cross_mean;
        self.prior_std = self.ema_decay * self.prior_std
            + (1.0 - self.ema_decay) * cross_std;

        // z-scores relative to prior
        let z_sq_sum: f64 = estimates.iter().zip(std_errors.iter())
            .map(|(e, s)| {
                let z = (*e as f64 - self.prior_mean) / (*s as f64 + 1e-8);
                z * z
            })
            .sum();

        // James-Stein intensity
        let intensity = if z_sq_sum > 0.0 {
            (1.0 - (n as f64 - 2.0) / z_sq_sum).max(0.0)
        } else {
            0.5
        };

        // Apply shrinkage
        let pm = self.prior_mean as f32;
        let scale = intensity as f32;
        let std_scale = (1.0 - intensity).max(1e-4).sqrt() as f32;
        for i in 0..n {
            estimates[i] = pm + scale * (estimates[i] - pm);
            std_errors[i] *= std_scale;
        }

        intensity
    }
}


// ══════════════════════════════════════════════════════════════════════════════
// PER-ASSET STATE (combines all layers)
// ══════════════════════════════════════════════════════════════════════════════

#[derive(Clone)]
struct AssetState {
    ticker: String,
    kalman: KalmanFilter3State,
    bayesian: NigPosterior,
    streamer: WelfordStreamer,
}

impl AssetState {
    fn new(ticker: String, decay: f64) -> Self {
        Self {
            ticker,
            kalman: KalmanFilter3State::new(),
            bayesian: NigPosterior::new(0.0, 1.0, 2.0, 0.01),
            streamer: WelfordStreamer::new(decay),
        }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
// HYBRID ENGINE — PyO3 exported class
// ══════════════════════════════════════════════════════════════════════════════
//
// This is the single entry point Python calls. It replaces
// HybridSignalEngine from signal_engine.py for the hot path.
//
// Usage from Python:
//   from signal_engine_rs import HybridEngine
//   engine = HybridEngine(tickers=["AAPL","MSFT",...], z_threshold=1.5)
//   alpha, unc, mask = engine.update_bar(returns_array)

#[pyclass]
struct HybridEngine {
    tickers: Vec<String>,
    n_assets: usize,
    z_threshold: f32,
    assets: Vec<AssetState>,
    shrinkage: JamesSteinShrinkage,

    // ADVI corrections (set from Python after session-end ADVI runs)
    advi_corrections: Vec<f32>,
    advi_unc: f32,

    // Latency tracking (microseconds)
    bar_times_us: VecDeque<u64>,
}

#[pymethods]
impl HybridEngine {
    /// Create a new HybridEngine.
    ///
    /// Args:
    ///     tickers: list of asset ticker strings
    ///     z_threshold: signal threshold (default 1.5)
    ///     decay: EWM decay for streaming features (default 0.95)
    #[new]
    #[pyo3(signature = (tickers, z_threshold=1.5, decay=0.95))]
    fn new(tickers: Vec<String>, z_threshold: f32, decay: f64) -> Self {
        let n = tickers.len();
        let assets = tickers.iter()
            .map(|t| AssetState::new(t.clone(), decay))
            .collect();

        Self {
            tickers,
            n_assets: n,
            z_threshold,
            assets,
            shrinkage: JamesSteinShrinkage::new(),
            advi_corrections: vec![0.0; n],
            advi_unc: 0.03,
            bar_times_us: VecDeque::with_capacity(500),
        }
    }

    /// Process one 15-minute bar across all assets.
    ///
    /// Args:
    ///     returns: numpy array of realized returns [n_assets], ordered
    ///              by the ticker list passed at construction.
    ///
    /// Returns:
    ///     (alpha, uncertainty, active_mask) — three numpy arrays [n_assets]
    ///     alpha: hybrid signal estimate per asset
    ///     uncertainty: combined uncertainty per asset
    ///     active_mask: bool array, True where |z| > threshold
    fn update_bar<'py>(
        &mut self,
        py: Python<'py>,
        returns: PyReadonlyArray1<'py, f32>,
    ) -> PyResult<(
        Bound<'py, PyArray1<f32>>,
        Bound<'py, PyArray1<f32>>,
        Bound<'py, PyArray1<bool>>,
    )> {
        let t0 = std::time::Instant::now();
        let rets = returns.as_slice()?;
        let n = self.n_assets;

        // ── Layer 1 + 2: Kalman + Bayesian per asset ──
        let mut alpha_kalman = vec![0.0f32; n];
        let mut unc_kalman = vec![0.0f32; n];
        let mut alpha_bayes = vec![0.0f32; n];
        let mut unc_bayes = vec![0.0f32; n];

        for i in 0..n {
            let ret = if i < rets.len() { rets[i] } else { 0.0 };
            let asset = &mut self.assets[i];

            // Layer 1: Kalman
            let (ak, uk, _innovation) = asset.kalman.update(ret);
            alpha_kalman[i] = ak;
            unc_kalman[i] = uk.max(1e-6);

            // Layer 2: NIG Bayesian
            let (ab, ub) = asset.bayesian.update(ret as f64);
            alpha_bayes[i] = ab as f32;
            unc_bayes[i] = ub as f32;

            // Streaming features (computed but stored internally)
            asset.streamer.update(ret as f64);
        }

        // ── Layer 2b: James-Stein shrinkage (cross-sectional) ──
        let mut alpha_shrunk = alpha_kalman.clone();
        let mut unc_shrunk = unc_kalman.clone();
        self.shrinkage.shrink(&mut alpha_shrunk, &mut unc_shrunk);

        // ── Inverse variance weighting: Kalman × Bayesian × Shrunk × ADVI ──
        let mut alpha_hybrid = vec![0.0f32; n];
        let mut uncertainty_hybrid = vec![0.0f32; n];
        let mut active_mask = vec![false; n];

        for i in 0..n {
            let prec_k = 1.0 / (unc_kalman[i].powi(2) + 1e-8);
            let prec_b = 1.0 / (unc_bayes[i].powi(2) + 1e-8);
            let prec_s = 1.0 / (unc_shrunk[i].powi(2) + 1e-8);
            let prec_a = 1.0 / (self.advi_unc.powi(2));

            let total_prec = prec_k + prec_b + prec_s + prec_a;

            alpha_hybrid[i] = (
                prec_k * alpha_shrunk[i]
                + prec_b * alpha_bayes[i]
                + prec_s * alpha_shrunk[i]
                + prec_a * self.advi_corrections[i]
            ) / (total_prec + 1e-8);

            uncertainty_hybrid[i] = 1.0 / (total_prec + 1e-8).sqrt();

            // Signal threshold: |z| > threshold
            let z = (alpha_hybrid[i] - self.shrinkage.prior_mean as f32).abs()
                / (uncertainty_hybrid[i] + 1e-8);
            active_mask[i] = z > self.z_threshold;
        }

        // Track latency
        let elapsed_us = t0.elapsed().as_micros() as u64;
        if self.bar_times_us.len() >= 500 {
            self.bar_times_us.pop_front();
        }
        self.bar_times_us.push_back(elapsed_us);

        // Return as numpy arrays (zero-copy where possible)
        Ok((
            PyArray1::from_vec_bound(py, alpha_hybrid),
            PyArray1::from_vec_bound(py, uncertainty_hybrid),
            PyArray1::from_vec_bound(py, active_mask),
        ))
    }

    /// Set ADVI corrections from Python (after session-end ADVI runs).
    /// ADVI still runs in Python/numpy — this just injects the result.
    fn set_advi_corrections(
        &mut self,
        corrections: PyReadonlyArray1<f32>,
    ) -> PyResult<()> {
        let corr = corrections.as_slice()?;
        self.advi_corrections = corr.to_vec();
        Ok(())
    }

    /// Reset Kalman priors (called after ADVI session correction).
    fn reset_kalman_from_advi(&mut self) {
        for (i, asset) in self.assets.iter_mut().enumerate() {
            if i < self.advi_corrections.len() {
                asset.kalman.reset(self.advi_corrections[i], 0.01);
            }
        }
    }

    /// Reset a single asset's Bayesian prior (session open).
    fn reset_asset(&mut self, index: usize) {
        if index < self.n_assets {
            let asset = &mut self.assets[index];
            asset.kalman.reset(0.0, 0.01);
            asset.bayesian = NigPosterior::new(0.0, 1.0, 2.0, 0.01);
            asset.streamer.reset();
        }
    }

    /// Get diagnostics dict.
    fn diagnostics<'py>(&self, py: Python<'py>) -> PyResult<Bound<'py, PyDict>> {
        let dict = PyDict::new_bound(py);
        dict.set_item("n_assets", self.n_assets)?;

        let n_active: usize = self.assets.iter()
            .enumerate()
            .filter(|(i, _)| {
                // Approximate: check if last hybrid alpha exceeded threshold
                // Full state would require storing active_mask
                *i < self.n_assets
            })
            .count();
        dict.set_item("n_tracked", n_active)?;

        if !self.bar_times_us.is_empty() {
            let avg_us: f64 = self.bar_times_us.iter().sum::<u64>() as f64
                / self.bar_times_us.len() as f64;
            dict.set_item("avg_bar_us", avg_us)?;
            dict.set_item("avg_bar_ms", avg_us / 1000.0)?;

            // P95
            let mut sorted: Vec<u64> = self.bar_times_us.iter().copied().collect();
            sorted.sort_unstable();
            let p95_idx = (sorted.len() as f64 * 0.95) as usize;
            let p95 = sorted.get(p95_idx.min(sorted.len() - 1)).copied().unwrap_or(0);
            dict.set_item("p95_bar_us", p95)?;
        }

        dict.set_item("z_threshold", self.z_threshold)?;
        Ok(dict)
    }

    /// Get per-asset state for debugging.
    fn get_asset_state<'py>(
        &self,
        py: Python<'py>,
        index: usize,
    ) -> PyResult<Bound<'py, PyDict>> {
        let dict = PyDict::new_bound(py);
        if index >= self.n_assets {
            return Ok(dict);
        }
        let asset = &self.assets[index];
        dict.set_item("ticker", &asset.ticker)?;
        dict.set_item("kalman_alpha", asset.kalman.x[0])?;
        dict.set_item("kalman_trend", asset.kalman.x[1])?;
        dict.set_item("kalman_uncertainty", asset.kalman.p[(0, 0)].max(0.0).sqrt())?;

        let (bay_mu, bay_std) = asset.bayesian.belief();
        dict.set_item("bayesian_mean", bay_mu)?;
        dict.set_item("bayesian_std", bay_std)?;

        dict.set_item("streamer_count", asset.streamer.count)?;
        dict.set_item("streamer_ewm_mean", asset.streamer.ewm_mean)?;
        dict.set_item("streamer_ewm_vol", asset.streamer.ewm_var.max(0.0).sqrt())?;
        Ok(dict)
    }
}


// ══════════════════════════════════════════════════════════════════════════════
// REAL-TIME PORTFOLIO OPTIMIZER (fast QP fallback, closed-form MVO)
// ══════════════════════════════════════════════════════════════════════════════
//
// Ports RealTimePortfolioOptimizer from signal_engine.py.
// Used when CVXPY/JuMP is too slow for the bar budget.
// w* = (1/λ) Σ⁻¹ α  (unconstrained) → projected onto L/S constraints.

#[pyclass]
struct FastMvoSolver {
    long_ratio: f64,
    max_position_wt: f64,
    risk_aversion: f64,
}

#[pymethods]
impl FastMvoSolver {
    #[new]
    #[pyo3(signature = (long_ratio=0.50, max_position_wt=0.08, risk_aversion=1.0))]
    fn new(long_ratio: f64, max_position_wt: f64, risk_aversion: f64) -> Self {
        Self { long_ratio, max_position_wt, risk_aversion }
    }

    /// Signal-to-noise ratio weights — no matrix ops at all.
    /// Ultra-fast high-vol regime fallback. Latency: <10μs.
    fn snr_weights<'py>(
        &self,
        py: Python<'py>,
        alphas: PyReadonlyArray1<'py, f64>,
        uncertainties: PyReadonlyArray1<'py, f64>,
        long_mask: PyReadonlyArray1<'py, bool>,
        short_mask: PyReadonlyArray1<'py, bool>,
    ) -> PyResult<Bound<'py, PyArray1<f64>>> {
        let a = alphas.as_slice()?;
        let u = uncertainties.as_slice()?;
        let lm = long_mask.as_slice()?;
        let sm = short_mask.as_slice()?;
        let n = a.len();

        let mut weights = vec![0.0f64; n];

        // SNR = |alpha| / uncertainty
        let mut long_sum = 0.0f64;
        let mut short_sum = 0.0f64;
        for i in 0..n {
            let snr = a[i].abs() / (u[i] + 1e-8);
            if lm[i] {
                weights[i] = snr;
                long_sum += snr;
            } else if sm[i] {
                weights[i] = -snr;
                short_sum += snr;
            }
        }

        // Normalise each book
        if long_sum > 0.0 {
            for i in 0..n {
                if lm[i] {
                    weights[i] = (weights[i] / long_sum * self.long_ratio)
                        .min(self.max_position_wt);
                }
            }
        }
        if short_sum > 0.0 {
            for i in 0..n {
                if sm[i] {
                    weights[i] = (weights[i] / short_sum * (self.long_ratio - 1.0))
                        .max(-self.max_position_wt);
                }
            }
        }

        Ok(PyArray1::from_vec_bound(py, weights))
    }
}


// ══════════════════════════════════════════════════════════════════════════════
// MODULE REGISTRATION
// ══════════════════════════════════════════════════════════════════════════════

#[pymodule]
fn signal_engine_rs(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<HybridEngine>()?;
    m.add_class::<FastMvoSolver>()?;
    Ok(())
}
