;; blaque_baux/rule_engine_hy/strategy_gate.hy
;; ──────────────────────────────────────────
;; Hy (Lisp) DSL for distribution regime strategy gating.
;;
;; Replaces the Python decision tree in distribution_regime.py with
;; S-expressions that are simultaneously executable and inspectable data.
;;
;; Why Hy:
;;   - Rules are data. You can serialize them, log them, diff them.
;;   - The LLM can generate new rules as S-expressions.
;;   - Composable: combine TAR rules with cascade rules with RNIV rules.
;;   - Compiles to Python AST — no IPC, no serialization boundary.
;;
;; Usage from Python:
;;   import hy
;;   from rule_engine_hy.strategy_gate import evaluate-strategy-gate
;;   gate = evaluate-strategy-gate risk-snap cascade rniv
;;
;; Build: pip install hy

(import logging)
(setv logger (.getLogger logging "strategy_gate"))


;; ══════════════════════════════════════════════════════════════════════════════
;; CONSTANTS — thresholds as named values, not magic numbers
;; ══════════════════════════════════════════════════════════════════════════════

(setv TAR-LONG-TAIL   2.0)   ; gain tail dominates above this
(setv TAR-SHORT-TAIL  0.5)   ; loss tail dominates below this
(setv STRONG-BULL     0.70)  ; cascade signal thresholds
(setv STRONG-BEAR    -0.70)
(setv KELLY-CAP       0.30)  ; max Kelly-driven capital commitment


;; ══════════════════════════════════════════════════════════════════════════════
;; HEDGE BASKETS — data, not code
;; ══════════════════════════════════════════════════════════════════════════════

(setv NULL-ZONE-HEDGE      {"GLD" 0.45  "TLT" 0.35  "UUP" 0.20})
(setv VOL-CAPTURE-BASKET   {"GLD" 0.50  "TLT" 0.30  "UUP" 0.20})
(setv BARBELL-SAFETY       {"GLD" 0.40  "TLT" 0.35  "SHY" 0.25})
(setv BARBELL-TAIL-BULL    {"QQQ" 0.60  "IWM" 0.40})
(setv BARBELL-TAIL-BEAR    {"GLD" 0.50  "TLT" 0.50})
(setv BARBELL-TAIL-NEUTRAL {"GLD" 0.40  "TLT" 0.35  "QQQ" 0.25})

;; Loss-tail defensive basket (TAR < 0.5: maximum safety for the tail hedge)
(setv LOSS-TAIL-DEFENSIVE  {"GLD" 0.50  "TLT" 0.35  "SHY" 0.15})


;; ══════════════════════════════════════════════════════════════════════════════
;; TAR CLASSIFIER — the single most important decision
;; ══════════════════════════════════════════════════════════════════════════════

(defn classify-tar [tar]
  "Classify which tail dominates.
   Returns :long-tail, :short-tail, or :neutral."
  (cond
    [(> tar TAR-LONG-TAIL)  :long-tail]
    [(< tar TAR-SHORT-TAIL) :short-tail]
    [True                   :neutral]))


;; ══════════════════════════════════════════════════════════════════════════════
;; DISTRIBUTION SHAPE → BASE STRATEGY
;; ══════════════════════════════════════════════════════════════════════════════

(defn shape->base-strategy [shape]
  "Map AIC best-fit distribution to base strategy type.
   This is the first-order decision before TAR refines it."
  (cond
    [(= shape "normal")    :directional-with-null-hedge]
    [(= shape "student_t") :directional-with-vol-capture]
    [(= shape "skewnorm")  :directional-with-tail-hedge]
    [(= shape "gev")       :barbell]
    [True                  :directional-with-null-hedge]))


;; ══════════════════════════════════════════════════════════════════════════════
;; BELL CURVE GATE — normal returns, standard L/S
;; ══════════════════════════════════════════════════════════════════════════════

(defn bell-curve-gate [cascade rniv]
  "Normal returns: standard L/S + null-zone hedge.
   The large null zone (|z| < threshold) funds GLD/TLT/UUP."
  {:strategy       :directional-with-null-hedge
   :dir-fraction   0.70
   :null-fraction  0.20
   :vol-fraction   0.0
   :safety-fraction 0.10
   :tail-fraction  0.0
   :null-weights   NULL-ZONE-HEDGE
   :safety-weights BARBELL-SAFETY
   :position-limit 0.10
   :invert?        False})


;; ══════════════════════════════════════════════════════════════════════════════
;; INVERTED BELL GATE — fat tails forming, add vol capture
;; ══════════════════════════════════════════════════════════════════════════════

(defn inverted-bell-gate [cascade rniv]
  "Student-t: both tails fire constantly. Add vol capture
   alongside L/S to offset simultaneous sleeve losses."
  {:strategy       :directional-with-vol-capture
   :dir-fraction   0.55
   :null-fraction  0.15
   :vol-fraction   0.20
   :safety-fraction 0.10
   :tail-fraction  0.0
   :null-weights   NULL-ZONE-HEDGE
   :vol-weights    VOL-CAPTURE-BASKET
   :safety-weights BARBELL-SAFETY
   :position-limit 0.08
   :invert?        False})


;; ══════════════════════════════════════════════════════════════════════════════
;; L-CURVE GATE — power-law world, TAR refines the barbell
;; ══════════════════════════════════════════════════════════════════════════════
;;
;; This is the most complex gate and the one TAR was designed for.
;; The decision tree:
;;
;;   TAR > 2.0  (gain tail dominant)
;;     → bet WITH the tail: retain/extend directional
;;     → Kelly positive: mathematically justified to stay long
;;     → "hold through the 19 losers for the 1 outsized win"
;;
;;   TAR < 0.5  (loss tail dominant)
;;     → bet AGAINST: INVERT the directional book
;;     → longs become shorts, shorts become longs
;;     → Kelly negative: math confirms reversal
;;     → "harvest 19 small wins, hedge the 1 catastrophe"
;;
;;   TAR 0.5–2.0 (symmetric L-curve)
;;     → standard barbell, cascade picks the tail sleeve
;;

(defn l-curve-gate [cascade rniv tar kelly tail-exponent]
  "GEV regime: power-law tails. TAR determines the barbell shape."
  (let [tar-class     (classify-tar tar)

        ;; Base directional fraction from GEV tail heaviness
        dir-base      (cond
                        [(and tail-exponent (> tail-exponent 0.5)) 0.15]
                        [(and tail-exponent (> tail-exponent 0.3))
                         (max 0.15 (- 0.30 (* tail-exponent 0.15)))]
                        [True 0.30])

        ;; TAR overlay
        [dir-frac invert? safety-frac tail-frac tail-weights]
        (cond
          ;; ── GAIN TAIL DOMINANT ──────────────────────────────────
          [(= tar-class :long-tail)
           (let [df  (min 0.35 (+ dir-base 0.05))
                 sf  0.50
                 tf  (- 1.0 df sf)
                 tw  (if (>= cascade STRONG-BULL)
                       BARBELL-TAIL-BULL
                       BARBELL-TAIL-NEUTRAL)]
             [df False sf tf tw])]

          ;; ── LOSS TAIL DOMINANT ──────────────────────────────────
          [(= tar-class :short-tail)
           (let [df       dir-base
                 kelly-x  (min 0.15 (abs kelly))
                 tf       (min 0.30 (+ (- 1.0 df 0.50) kelly-x))
                 sf       (- 1.0 df tf)]
             [df True sf tf LOSS-TAIL-DEFENSIVE])]

          ;; ── SYMMETRIC L-CURVE ──────────────────────────────────
          [True
           (let [sf  0.50
                 tf  (- 1.0 dir-base sf)
                 tw  (cond
                       [(>= cascade STRONG-BULL) BARBELL-TAIL-BULL]
                       [(<= cascade STRONG-BEAR) BARBELL-TAIL-BEAR]
                       [True BARBELL-TAIL-NEUTRAL])]
             [dir-base False sf tf tw])])]

    ;; Log the decision
    (when invert?
      (.warning logger
        f"⚠ L-CURVE TAR={tar:.2f} Kelly={kelly:+.3f} → INVERTED directional"))

    {:strategy        :barbell
     :dir-fraction    dir-frac
     :null-fraction   0.0
     :vol-fraction    0.0
     :safety-fraction safety-frac
     :tail-fraction   tail-frac
     :safety-weights  BARBELL-SAFETY
     :tail-weights    tail-weights
     :position-limit  (if invert? 0.04 0.05)
     :invert?         invert?
     :tar             tar
     :tar-signal      tar-class
     :kelly           kelly
     :tail-exponent   tail-exponent}))


;; ══════════════════════════════════════════════════════════════════════════════
;; TOP-LEVEL EVALUATOR — the single entry point
;; ══════════════════════════════════════════════════════════════════════════════

(defn evaluate-strategy-gate
  [shape cascade rniv
   &optional [tar 1.0] [kelly 0.0] [tail-exponent None]]
  "Evaluate the strategy gate for one window.

   Args:
     shape:          AIC best-fit distribution name (str)
     cascade:        cascade signal strength [-1, +1]
     rniv:           risk-not-in-VaR dispersion [0, 1]
     tar:            Tail Asymmetry Ratio from RealTimeRiskManager
     kelly:          Kelly-optimal fraction (negative = short justified)
     tail-exponent:  GEV shape parameter ξ (None if not GEV)

   Returns:
     dict — the StrategyGate fields.
     This dict is the S-expression output: data you can log, diff, serialize.

   Called from Python:
     import hy
     from rule_engine_hy.strategy_gate import evaluate_strategy_gate
     gate = evaluate_strategy_gate('gev', 0.3, 0.15, tar=0.4, kelly=-0.08)
  "
  (let [base   (shape->base-strategy shape)
        gate   (cond
                 [(= base :directional-with-null-hedge)
                  (bell-curve-gate cascade rniv)]
                 [(= base :directional-with-vol-capture)
                  (inverted-bell-gate cascade rniv)]
                 [(= base :barbell)
                  (l-curve-gate cascade rniv tar kelly tail-exponent)]
                 ;; Asymmetric (skewnorm) — handled like inverted bell with tail hedge
                 [True
                  (inverted-bell-gate cascade rniv)])]

    ;; Stamp TAR onto all gates (even non-barbell)
    (setv (get gate :tar)        tar)
    (setv (get gate :tar-signal) (classify-tar tar))
    (setv (get gate :kelly)      kelly)
    gate))
