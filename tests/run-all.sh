#!/bin/bash
# Master test runner for the zensu-codex plugin.
#
#   (no arg)      DETERMINISTIC suites only — no network, no Codex, no API spend:
#                   - tests/smoke.sh (packaging, hook syntax, TDD gate behavior)
#                   - every tests/structure/test-*.sh
#                   - evals/config-gate/run-eval.sh --self-check (offline gate evals)
#   --self-check  deterministic suites + each live suite's --self-check skeleton (no API)
#   --live        deterministic suites + LIVE `codex exec` suites (COSTS API CREDITS,
#                 needs an authenticated codex CLI):
#                   - tests/e2e-intent-router / tests/e2e-context-nudge (hook contract + live)
#                   - evals/tdd (promptfoo, reference: Codex follows $zensu-tdd end-to-end)
#
# Exit 0 iff every selected suite passed. A "suite" = one script; it passes iff it
# exits 0. Per-script internal tallies are streamed; this runner tallies suites.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
MODE="${1:-}"

case "$MODE" in
  ""|--self-check|--live) ;;
  *)
    printf "unknown mode '%s' — accepted: (no arg), --self-check, --live\n" "$MODE" >&2
    exit 2
    ;;
esac

RESULTS_DIR="$TESTS_DIR/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/run-all-$TIMESTAMP.txt"

PASS=0; FAIL=0
log() { printf "%s\n" "$1" | tee -a "$REPORT"; }

run_suite() {
  local label="$1"; shift
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tee -a "$REPORT" >/dev/null
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1)); log "  PASS  $label"
  else
    FAIL=$((FAIL+1)); log "  FAIL  $label (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

log "════════════════════════════════════════════════════════════"
log "  zensu-codex — run-all  ($TIMESTAMP)  mode=${MODE:-default}"
log "  plugin v$(node -e 'process.stdout.write(require("'"$ROOT"'/plugins/zensu/.codex-plugin/plugin.json").version)' 2>/dev/null || echo '?')"
log "════════════════════════════════════════════════════════════"

# ── Deterministic: smoke ─────────────────────────────────────────────
log ""
log "▸ Smoke tests (deterministic)"
run_suite "smoke.sh" bash "$TESTS_DIR/smoke.sh"

# ── Deterministic: structure ─────────────────────────────────────────
log ""
log "▸ Structure tests (deterministic)"
for t in "$TESTS_DIR"/structure/test-*.sh; do
  [ -f "$t" ] || continue
  run_suite "structure/$(basename "$t")" bash "$t"
done

# ── Deterministic: config-gate offline evals ─────────────────────────
log ""
log "▸ Offline evals"
CG="$ROOT/evals/config-gate/run-eval.sh"
[ -f "$CG" ] && run_suite "evals/config-gate (--self-check)" bash "$CG" --self-check

# ── Live / self-check suites ─────────────────────────────────────────
if [ "$MODE" = "--live" ] || [ "$MODE" = "--self-check" ]; then
  FLAG=""; [ "$MODE" = "--self-check" ] && FLAG="--self-check"
  label_sfx="(live)"; [ "$MODE" = "--self-check" ] && label_sfx="(--self-check)"

  log ""
  log "▸ E2E suites $label_sfx"
  for s in e2e-intent-router e2e-context-nudge; do
    run="$TESTS_DIR/$s/run.sh"
    [ -f "$run" ] || continue
    if [ "$MODE" = "--live" ]; then
      setup="$TESTS_DIR/$s/setup-fixtures.sh"
      [ -f "$setup" ] && bash "$setup" >/dev/null 2>&1
    fi
    run_suite "$s/run.sh $label_sfx" bash "$run" $FLAG
  done

  log ""
  log "▸ Reference eval $label_sfx"
  EV="$ROOT/evals/tdd/run.sh"
  [ -f "$EV" ] && run_suite "evals/tdd $label_sfx" bash "$EV" $FLAG
fi

log ""
log "════════════════════════════════════════════════════════════"
log "  SUITES: $PASS passed / $FAIL failed"
log "  Report: $REPORT"
log "════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
