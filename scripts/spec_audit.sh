#!/usr/bin/env bash
# SmallClaw weekly spec-maintenance work order.
# Mechanically re-derives what it can and appends dated findings to HONEST-ASSESSMENT.md.
# It does NOT edit the matrix — it surfaces drift for a human to resolve.
#
# Checks:
#   1. Orphan REQs      — defined in Requirements.md but absent from the design.md matrix
#   2. Orphan modules   — src/module_* never named in design.md (no REQ claims them)
#   3. Test drift       — test_*.jl files referenced in design.md that don't exist,
#                         and test files that exist but no REQ cites
#   4. Staleness        — design.md "Last updated" older than STALE_WEEKS
#
# Usage:  bash scripts/spec_audit.sh   (run from repo root)
# Schedule weekly (macOS launchd / cron / SmallClaw predictive agent).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQ="$ROOT/Requirements.md"
DESIGN="$ROOT/design.md"
OUT="$ROOT/HONEST-ASSESSMENT.md"
STALE_WEEKS="${STALE_WEEKS:-2}"
TODAY="$(date +%Y-%m-%d)"

# Modules that intentionally carry no safety invariant (pipeline transforms).
# Documented in design.md; listed here so the weekly report doesn't re-flag them.
ACK_ORPHAN_MODULES="${ACK_ORPHAN_MODULES:-module_2_smoothing module_3_pca}"

# REQs defined (bolded) in Requirements.md, split invariants vs features:
defined_inv="$(grep -oE '\*\*REQ-(DATA|SIM|RISK|EXEC|AUDIT|REGIME|GOV)-[0-9]+\*\*' "$REQ" 2>/dev/null | tr -d '*' | sort -u)"
defined_feat="$(grep -oE '\*\*REQ-FEAT-[0-9]+\*\*' "$REQ" 2>/dev/null | tr -d '*' | sort -u)"
matrix_reqs="$(grep -oE 'REQ-[A-Z]+-[0-9]+' "$DESIGN" 2>/dev/null | sort -u)"

# Orphan = defined INVARIANT absent from the matrix (features are informational only).
orphan_reqs="$(comm -23 <(echo "$defined_inv") <(echo "$matrix_reqs") | grep . || true)"
feat_not_in_matrix="$(comm -23 <(echo "$defined_feat") <(echo "$matrix_reqs") | grep . || true)"

modules="$(find "$ROOT/src" -maxdepth 1 -type d -name 'module_*' -exec basename {} \; 2>/dev/null | sort -u)"
orphan_modules=""
while IFS= read -r m; do
  [ -z "$m" ] && continue
  case " $ACK_ORPHAN_MODULES " in *" $m "*) continue ;; esac   # skip acknowledged
  grep -q "$m" "$DESIGN" 2>/dev/null || orphan_modules="$orphan_modules $m"
done <<< "$modules"

# Test drift — expand "test_module_4/5/6.jl" shorthand; exclude "backtest_*" (scripts, not tests).
cited_from_shorthand="$(grep -oE 'test_module_[0-9]+(/[0-9]+)*\.jl' "$DESIGN" 2>/dev/null \
  | grep -oE '[0-9]+' | while read -r n; do echo "test_module_${n}.jl"; done)"
cited_explicit="$(grep -oE '(^|[^A-Za-z])test_[A-Za-z0-9_]+\.jl' "$DESIGN" 2>/dev/null \
  | grep -oE 'test_[A-Za-z0-9_]+\.jl' | grep -vE '^test_module_[0-9]+$')"
referenced_tests="$(printf '%s\n%s\n' "$cited_from_shorthand" "$cited_explicit" | sort -u | grep . || true)"

missing_tests=""
while IFS= read -r t; do
  [ -z "$t" ] && continue
  [ -f "$ROOT/test/$t" ] || missing_tests="$missing_tests $t"
done <<< "$referenced_tests"
existing_tests="$(find "$ROOT/test" -name 'test_*.jl' -exec basename {} \; 2>/dev/null | sort -u || true)"
uncited_tests="$(comm -23 <(echo "$existing_tests") <(echo "$referenced_tests") | grep . || true)"

# Staleness
last_updated="$(grep -oE 'Last updated:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}' "$DESIGN" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || echo "$TODAY")"
age_days=$(( ( $(date -j -f "%Y-%m-%d" "$TODAY" +%s 2>/dev/null || date -d "$TODAY" +%s) - $(date -j -f "%Y-%m-%d" "$last_updated" +%s 2>/dev/null || date -d "$last_updated" +%s) ) / 86400 ))
stale_flag=""
[ "$age_days" -gt $(( STALE_WEEKS * 7 )) ] && stale_flag="design.md matrix last updated $last_updated (${age_days}d ago) — exceeds ${STALE_WEEKS}w; re-verify conformance cells."

{
  echo ""
  echo "### spec-audit — $TODAY"
  echo ""
  echo "- invariants defined: $(echo "$defined_inv" | grep -c .) · in matrix: $(echo "$matrix_reqs" | grep -c .) · modules: $(echo "$modules" | grep -c .) · tests: $(echo "$existing_tests" | grep -c .)"
  [ -n "$orphan_reqs" ]     && echo "- ⚠️ ORPHAN invariants (defined, not in matrix):$(echo "$orphan_reqs" | tr '\n' ' ')" || echo "- ✓ every invariant is in the matrix"
  [ -n "$orphan_modules" ]  && echo "- ⚠️ ORPHAN modules (no REQ, not acknowledged):$orphan_modules" || echo "- ✓ every module is claimed or acknowledged"
  [ -n "$missing_tests" ]   && echo "- ⚠️ matrix cites MISSING tests:$missing_tests" || echo "- ✓ all cited tests exist"
  [ -n "$uncited_tests" ]   && echo "- ℹ️ test files not yet cited by a REQ:$(echo "$uncited_tests" | tr '\n' ' ')" || echo "- ✓ every test file is cited"
  [ -n "$feat_not_in_matrix" ] && echo "- ℹ️ features not in matrix (informational):$(echo "$feat_not_in_matrix" | tr '\n' ' ')"
  [ -n "$stale_flag" ]      && echo "- ⚠️ STALE: $stale_flag" || echo "- ✓ matrix fresh (${age_days}d)"
} >> "$OUT"

echo "spec-audit appended to $OUT ($TODAY)"
