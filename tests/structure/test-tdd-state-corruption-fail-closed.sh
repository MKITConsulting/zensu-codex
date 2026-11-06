#!/bin/bash
# Regression: an existing but unreadable TDD state file is not equivalent to
# an absent/inactive session. Both the edit gate and the chain terminus must
# fail closed until the state is repaired through the transactional helpers.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/zensu" && pwd)"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
GATE="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE="$REPO_ROOT/tests/fixtures/workflow-state-access-probe.js"
VERDICT="$REPO_ROOT/tests/fixtures/workflow-state-access-verdict.js"

PASS=0; FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = "PASS" ]; then
    echo "  PASS  $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"; FAIL=$((FAIL + 1))
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_PLUGIN_ROOT="$PLUGIN_DIR"
export HOME="$WORK/home"
export ZENSU_CONFIG="$WORK/no-such-config.json"
mkdir -p "$WORK/project" "$HOME"
export CLAUDE_PROJECT_DIR="$(cd "$WORK/project" && pwd -P)"
STATE_DIR="$CLAUDE_PROJECT_DIR/.zensu/state"

# shellcheck disable=SC1090
source "$PHASE_LIB"

gate_decision() {
  local sid="$1" out
  out="$(printf '%s' '{"tool_name":"apply_patch","session_id":"'"$sid"'","tool_input":{"input":"*** Begin Patch\n*** Update File: src/app.js\n@@\n+x\n*** End Patch"}}' | bash "$GATE" 2>/dev/null)"
  case "$out" in *'"permissionDecision":"deny"'*) echo deny ;; *) echo allow ;; esac
}

stop_decision() {
  local sid="$1" out
  out="$(printf '{"session_id":"%s"}' "$sid" | bash "$STOP" 2>/dev/null)"
  case "$out" in *'"decision":"block"'*) echo block ;; *) echo allow ;; esac
}

restore_baseline() {
  cp "$BASELINE" "$STATE_FILE"
  rm -f "$INVALID_COUNT"
}

MISSING_SID="missing-state"
MISSING_KEY="$(node "$CORE" session-key "$MISSING_SID")"
printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}' "$MISSING_SID" "$CLAUDE_PROJECT_DIR" \
  | bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null
export ZENSU_SESSION_KEY="$MISSING_KEY"
MISSING="$(tdd_state_file "$MISSING_KEY")"
rm -f "$MISSING"
[ "$(tdd_state_status "$MISSING")" = "missing" ] \
  && check "missing state is reported as missing" PASS \
  || check "missing state is reported as missing" FAIL
[ "$(tdd_session_active "$MISSING")" = "false" ] && [ "$(tdd_phase "$MISSING")" = "UNINITIALIZED" ] \
  && check "missing state keeps inactive/UNINITIALIZED defaults" PASS \
  || check "missing state keeps inactive/UNINITIALIZED defaults" FAIL
[ "$(gate_decision "$MISSING_SID")" = "deny" ] && [ "$(stop_decision "$MISSING_SID")" = "block" ] \
  && check "deleted mandatory baseline state fails closed" PASS \
  || check "deleted mandatory baseline state fails closed" FAIL

SID="corrupt-after-chain-end"
printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}' "$SID" "$CLAUDE_PROJECT_DIR" \
  | bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null
export ZENSU_SESSION_KEY="$(node "$CORE" session-key "$SID")"
bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
bash "$LOG" --chain-done --session "$SID" >/dev/null 2>&1
STATE_FILE="$(tdd_state_file "$SID")"
INVALID_COUNT="$HOME/.zensu/stop-guard/codex/invalid-state-$ZENSU_SESSION_KEY.count"

[ "$(tdd_state_status "$STATE_FILE")" = "valid" ] && [ "$(stop_decision "$SID")" = "allow" ] \
  && check "valid completed state allows the chain terminus" PASS \
  || check "valid completed state allows the chain terminus" FAIL

BASELINE="$WORK/valid-completed-state.json"
cp "$STATE_FILE" "$BASELINE"

rm -f "$WORK/tdd-probe.jsonl"
PROBED_STATUS="$(
  export ZENSU_PROBE_ROOTS="$CLAUDE_PROJECT_DIR" ZENSU_PROBE_REPORT="$WORK/tdd-probe.jsonl" NODE_OPTIONS="--require \"$PROBE\""
  tdd_state_status "$STATE_FILE"
)"
if [ "$PROBED_STATUS" = "valid" ] \
  && node "$VERDICT" "$WORK/tdd-probe.jsonl" --opened "$STATE_FILE" --within inspectWorkflowState \
    >"$WORK/tdd-probe.verdict" 2>&1; then
  check "the state reader reads the workflow state only inside the core reader" PASS
else
  check "the state reader reads the workflow state only inside the core reader ($(cat "$WORK/tdd-probe.verdict" 2>/dev/null))" FAIL
fi

bash "$LOG" --tdd-reset --session "$SID" >/dev/null 2>&1
if [ "$(tdd_state_status "$STATE_FILE")" = "valid" ] \
  && [ "$(tdd_session_active "$STATE_FILE")" = "false" ] \
  && [ "$(gate_decision "$SID")" = "allow" ] \
  && [ "$(stop_decision "$SID")" = "allow" ]; then
  check "valid inactive state remains an edit/Stop pass-through" PASS
else
  check "valid inactive state remains an edit/Stop pass-through" FAIL
fi
cp "$BASELINE" "$STATE_FILE"

write_semantic_corruption() {
  local corruption="$1"
  CORRUPTION="$corruption" BASELINE="$BASELINE" STATE_FILE="$STATE_FILE" RAW_SID="$SID" node -e '
    const fs = require("node:fs");
    const state = JSON.parse(fs.readFileSync(process.env.BASELINE, "utf8"));
    switch (process.env.CORRUPTION) {
      case "empty-object": Object.keys(state).forEach(key => delete state[key]); break;
      case "wrong-schema": state.schema = "attacker.workflow-state"; break;
      case "wrong-version": state.schema_version = 2; break;
      case "wrong-hash": state.session_id_hash = "sha256:" + "0".repeat(64); break;
      case "wrong-actor": state.actor = "reviewer-readonly-v1"; break;
      case "raw-session-id": state.session_id = process.env.RAW_SID; break;
      case "revision-zero": state.revision = 0; break;
      case "revision-overflow": state.revision = Number.MAX_SAFE_INTEGER + 1; break;
      case "revision-noninteger": state.revision = 1.5; break;
      case "bad-timestamp": state.updated_at = "not-a-date"; break;
      case "bad-event": state.last_event = "INVALID EVENT"; break;
      case "bad-workflow-state": state.workflow_state = "INVALID STATE"; break;
      case "active-string": state.active = "false"; break;
      case "vanilla-string": state.vanilla = "false"; break;
      case "impl-string": state.implComplete = "false"; break;
      case "chain-string": state.chainDone = "true"; break;
      case "code-review-string": state.codeReviewDone = "true"; break;
      case "self-review-string": state.selfReviewFixed = "true"; break;
      case "workflow-active-string": state.workflowActive = "true"; break;
      case "review-round-string": state.reviewRound = "5"; break;
      case "review-round-negative": state.reviewRound = -1; break;
      case "stop-blocks-string": state.stopBlocks = "8"; break;
      case "stop-blocks-too-large": state.stopBlocks = 1000001; break;
      case "bad-phase": state.phase = { name: "IMPL" }; break;
      case "bad-step": state.step_id = ["S1"]; break;
      case "history-not-array": state.history = {}; break;
      case "history-primitive": state.history = ["RED_FAIL"]; break;
      case "history-bad-step": state.history = [{ step: 1, phase: "RED_FAIL" }]; break;
      case "history-bad-phase": state.history = [{ step: "S1", phase: false }]; break;
      case "history-bad-timestamp": state.history = [{ step: "S1", phase: "RED_FAIL", ts: "not-a-date" }]; break;
      case "workflow-tools-not-array": state.workflowTools = {}; break;
      case "workflow-tools-bad-entry": state.workflowTools = ["link_test", 7]; break;
      case "bypasses-not-array": state.bypasses = "ZENSU_TDD_GATE"; break;
      case "bypasses-bad-entry": state.bypasses = ["ZENSU_TDD_GATE", 7]; break;
      default: throw new Error("unknown corruption: " + process.env.CORRUPTION);
    }
    fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(state) + "\n");
  '
}

assert_semantic_corruption_blocks() {
  local corruption="$1"
  write_semantic_corruption "$corruption"
  if [ "$(tdd_state_status "$STATE_FILE")" = "invalid" ] \
    && [ "$(tdd_session_active "$STATE_FILE")" = "invalid" ] \
    && [ "$(tdd_phase "$STATE_FILE")" = "INVALID_STATE" ] \
    && [ "$(tdd_step "$STATE_FILE")" = "INVALID_STATE" ] \
    && [ "$(tdd_has_red_fail "$STATE_FILE" S1)" = "invalid" ] \
    && [ "$(gate_decision "$SID")" = "deny" ] \
    && [ "$(stop_decision "$SID")" = "block" ]; then
    check "$corruption is invalid and blocks PreEdit/Stop" PASS
  else
    check "$corruption is invalid and blocks PreEdit/Stop" FAIL
  fi
  restore_baseline
}

for corruption in \
  empty-object wrong-schema wrong-version wrong-hash wrong-actor raw-session-id \
  revision-zero revision-overflow revision-noninteger bad-timestamp bad-event bad-workflow-state \
  active-string vanilla-string impl-string chain-string code-review-string self-review-string workflow-active-string \
  review-round-string review-round-negative stop-blocks-string stop-blocks-too-large \
  bad-phase bad-step history-not-array history-primitive history-bad-step history-bad-phase history-bad-timestamp \
  workflow-tools-not-array workflow-tools-bad-entry bypasses-not-array bypasses-bad-entry; do
  assert_semantic_corruption_blocks "$corruption"
done

WRONG_NAME="$STATE_DIR/workflow-state.json"
cp "$BASELINE" "$WRONG_NAME"
[ "$(tdd_state_status "$WRONG_NAME")" = "invalid" ] \
  && check "non-contract state filename is invalid" PASS \
  || check "non-contract state filename is invalid" FAIL

mv "$STATE_FILE" "$WORK/symlink-target.json"
ln -s "$WORK/symlink-target.json" "$STATE_FILE"
if [ "$(tdd_state_status "$STATE_FILE")" = "invalid" ] \
  && [ "$(gate_decision "$SID")" = "deny" ] \
  && [ "$(stop_decision "$SID")" = "block" ]; then
  check "symlink state is invalid and blocks PreEdit/Stop" PASS
else
  check "symlink state is invalid and blocks PreEdit/Stop" FAIL
fi
rm "$STATE_FILE"
restore_baseline

rm "$STATE_FILE"
mkdir "$STATE_FILE"
if [ "$(tdd_state_status "$STATE_FILE")" = "invalid" ] \
  && [ "$(gate_decision "$SID")" = "deny" ] \
  && [ "$(stop_decision "$SID")" = "block" ]; then
  check "nonregular state is invalid and blocks PreEdit/Stop" PASS
else
  check "nonregular state is invalid and blocks PreEdit/Stop" FAIL
fi
rmdir "$STATE_FILE"
cp "$BASELINE" "$STATE_FILE"
if [ -f "$INVALID_COUNT" ] && [ "$(stop_decision "$SID")" = "allow" ] && [ ! -e "$INVALID_COUNT" ]; then
  check "a restored valid state releases Stop and resets the invalid-state count" PASS
else
  check "a restored valid state releases Stop and resets the invalid-state count" FAIL
fi

printf '%s' '{"active":true,"chainDone":' > "$STATE_FILE"

[ "$(tdd_state_status "$STATE_FILE")" = "invalid" ] \
  && check "corrupt existing state is reported as invalid" PASS \
  || check "corrupt existing state is reported as invalid" FAIL
[ "$(tdd_session_active "$STATE_FILE")" = "invalid" ] && [ "$(tdd_phase "$STATE_FILE")" = "INVALID_STATE" ] \
  && check "flag and phase readers preserve the invalid-state distinction" PASS \
  || check "flag and phase readers preserve the invalid-state distinction" FAIL
[ "$(gate_decision "$SID")" = "deny" ] \
  && check "corrupt previously active state blocks production edits" PASS \
  || check "corrupt previously active state blocks production edits" FAIL
[ "$(stop_decision "$SID")" = "block" ] \
  && check "corrupt completed state blocks Stop/chain termination" PASS \
  || check "corrupt completed state blocks Stop/chain termination" FAIL

CAP_BLOCKS=0
for attempt in 2 3 4; do
  printf '{"session_id":"%s"}' "$SID" | bash "$STOP" >"$WORK/stop-cap.out" 2>"$WORK/stop-cap.err"
  grep -qF '"decision":"block"' "$WORK/stop-cap.out" && CAP_BLOCKS=$((CAP_BLOCKS + 1))
done
if [ "$CAP_BLOCKS" -eq 2 ] \
  && grep -qF 'exceed the cap' "$WORK/stop-cap.err" \
  && [ "$(gate_decision "$SID")" = "deny" ] \
  && ! bash "$LOG" --chain-done --session "$SID" >"$WORK/chain-done.out" 2>&1; then
  check "invalid-state Stop releases after three blocks while edits and the chain terminus stay closed" PASS
else
  check "invalid-state Stop releases after three blocks while edits and the chain terminus stay closed" FAIL
fi

mv "$STATE_DIR" "$WORK/state-directory-moved"
[ "$(tdd_state_status "$STATE_FILE")" = "missing" ] \
  && check "a removed workflow state directory is reported as missing" PASS \
  || check "a removed workflow state directory is reported as missing" FAIL
mv "$WORK/state-directory-moved" "$STATE_DIR"

mv "$CLAUDE_PROJECT_DIR/.zensu" "$WORK/workflow-root-moved"
ln -s "$WORK/no-such-workflow-root" "$CLAUDE_PROJECT_DIR/.zensu"
[ "$(tdd_state_status "$STATE_FILE")" = "invalid" ] \
  && check "a dangling symlinked workflow root is invalid, not missing" PASS \
  || check "a dangling symlinked workflow root is invalid, not missing" FAIL
rm "$CLAUDE_PROJECT_DIR/.zensu"
mv "$WORK/workflow-root-moved" "$CLAUDE_PROJECT_DIR/.zensu"

echo "----"
echo "test-tdd-state-corruption-fail-closed: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
