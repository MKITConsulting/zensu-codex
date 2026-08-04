#!/bin/bash
# Master test runner for the zensu-codex plugin.
#
#   (no arg)      DETERMINISTIC suites only — no network, no Codex, no API spend:
#                   - tests/smoke.sh (packaging, hook syntax, TDD gate behavior)
#                   - every tests/structure/test-*.sh
#                   - evals/config-gate/run-eval.sh --self-check (offline gate evals)
#   --ci          deterministic non-Promptfoo suites used by GitHub Actions.
#                 Promptfoo suites are local-only and are intentionally skipped.
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
LOCAL_ONLY_MANIFEST="$TESTS_DIR/profiles/promptfoo-local-only.v1.json"

case "$MODE" in
  ""|--ci|--self-check|--live) ;;
  *)
    printf "unknown mode '%s' — accepted: (no arg), --ci, --self-check, --live\n" "$MODE" >&2
    exit 2
    ;;
esac

load_local_only_inventory() {
  local field="$1"
  node - "$LOCAL_ONLY_MANIFEST" "$field" <<'NODE'
const fs = require('node:fs');
const [file, field] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
if (value.schemaVersion !== 1 || !Array.isArray(value[field])
    || value[field].some((entry) => typeof entry !== 'string' || entry.length === 0)) {
  throw new Error(`invalid Promptfoo local-only inventory field: ${field}`);
}
process.stdout.write(value[field].join('\n'));
NODE
}

CI_STRUCTURE="$(load_local_only_inventory ciStructureTests)" || exit 2
LOCAL_ONLY_STRUCTURE="$(load_local_only_inventory localStructureTests)" || exit 2

is_local_only() {
  local inventory="$1" entry="$2"
  printf '%s\n' "$inventory" | grep -Fxq -- "$entry"
}

node - "$ROOT" "$LOCAL_ONLY_MANIFEST" <<'NODE' || exit 2
const fs = require('node:fs');
const path = require('node:path');
const [root, file] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const uniqueSorted = (entries) => [...new Set(entries)].sort();
const actualStructure = fs.readdirSync(path.join(root, 'tests', 'structure'))
  .filter((name) => /^test-.*\.sh$/.test(name))
  .sort();
const classified = [...value.ciStructureTests, ...value.localStructureTests];
if (JSON.stringify(uniqueSorted(classified)) !== JSON.stringify(actualStructure)
    || classified.length !== new Set(classified).size
    || !Array.isArray(value.ciOfflineSuites)
    || value.ciOfflineSuites.some((suite) => !suite || typeof suite.label !== 'string'
      || typeof suite.path !== 'string' || !Array.isArray(suite.args)
      || !Array.isArray(suite.ciArgs)
      || suite.label.length === 0 || /[\t\r\n]/.test(suite.label)
      || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(suite.path)
      || [...suite.args, ...suite.ciArgs].some(
        (argument) => typeof argument !== 'string' || argument.length === 0
          || /[\t\r\n ]/.test(argument),
      )
      || !fs.existsSync(path.join(root, suite.path)))) {
  throw new Error('suite classification inventory is incomplete; refusing execution');
}
NODE

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

run_required_suite() {
  local label="$1" runner="$2"; shift 2
  if [ -f "$runner" ]; then
    run_suite "$label" "$@"
  else
    FAIL=$((FAIL+1)); log "  FAIL  $label — runner missing at $runner"
  fi
}

offline_inventory() {
  node - "$LOCAL_ONLY_MANIFEST" "$MODE" <<'NODE'
const fs = require('node:fs');
const [file, mode] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
for (const suite of value.ciOfflineSuites) {
  const args = mode === '--ci' ? suite.ciArgs : suite.args;
  if (suite.label.length === 0 || /[\t\r\n]/.test(suite.label)
      || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(suite.path)
      || args.some((argument) => typeof argument !== 'string' || argument.length === 0
        || /[\t\r\n ]/.test(argument))) {
    throw new Error('offline suite inventory contains an unsafe field');
  }
  process.stdout.write(`${suite.label}\t${suite.path}\t${args.join(' ')}\n`);
}
NODE
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
  if [ "$MODE" = "--ci" ]; then
    if is_local_only "$LOCAL_ONLY_STRUCTURE" "$(basename "$t")"; then
      log "  LOCAL structure/$(basename "$t") (Promptfoo local-only)"
      continue
    fi
    if ! is_local_only "$CI_STRUCTURE" "$(basename "$t")"; then
      FAIL=$((FAIL+1)); log "  FAIL  unclassified structure suite: $(basename "$t")"
      continue
    fi
  fi
  run_suite "structure/$(basename "$t")" bash "$t"
done

# ── Deterministic: config-gate offline evals ─────────────────────────
log ""
log "▸ Offline evals"
OFFLINE_LINES="$(offline_inventory)" || exit 2
OFFLINE_EXPECTED="$(
  node -e 'process.stdout.write(String(require(process.argv[1]).ciOfflineSuites.length))' \
    "$LOCAL_ONLY_MANIFEST"
)" || exit 2
OFFLINE_EXECUTED=0
while IFS=$'\t' read -r label relative argument_line; do
  [ -n "$label" ] || continue
  runner="$ROOT/$relative"
  suite_args=()
  if [ -n "$argument_line" ]; then
    read -r -a suite_args <<< "$argument_line"
  fi
  if [ -n "$argument_line" ]; then
    run_required_suite "$label" "$runner" bash "$runner" "${suite_args[@]}"
  else
    run_required_suite "$label" "$runner" bash "$runner"
  fi
  OFFLINE_EXECUTED=$((OFFLINE_EXECUTED + 1))
done <<< "$OFFLINE_LINES"
if [ "$OFFLINE_EXECUTED" -ne "$OFFLINE_EXPECTED" ]; then
  FAIL=$((FAIL+1))
  log "  FAIL  offline inventory executed $OFFLINE_EXECUTED/$OFFLINE_EXPECTED suites"
fi

# ── Live / self-check suites ─────────────────────────────────────────
if [ "$MODE" = "--live" ] || [ "$MODE" = "--self-check" ]; then
  FLAG=""; [ "$MODE" = "--self-check" ] && FLAG="--self-check"
  label_sfx="(live)"; [ "$MODE" = "--self-check" ] && label_sfx="(--self-check)"

  log ""
  log "▸ E2E suites $label_sfx"
  for s in e2e-intent-router e2e-context-nudge; do
    run="$TESTS_DIR/$s/run.sh"
    if [ -f "$run" ]; then
      run_suite "$s/run.sh $label_sfx" bash "$run" $FLAG
    else
      FAIL=$((FAIL+1)); log "  FAIL  $s — run.sh missing (a renamed suite must not vanish silently)"
    fi
  done

  log ""
  log "▸ Reference eval $label_sfx"
  EV="$ROOT/evals/tdd/run.sh"
  if [ -f "$EV" ]; then
    run_suite "evals/tdd $label_sfx" bash "$EV" $FLAG
  else
    FAIL=$((FAIL+1)); log "  FAIL  evals/tdd — run.sh missing (a renamed suite must not vanish silently)"
  fi
fi

log ""
log "════════════════════════════════════════════════════════════"
log "  SUITES: $PASS passed / $FAIL failed"
log "  Report: $REPORT"
log "════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
