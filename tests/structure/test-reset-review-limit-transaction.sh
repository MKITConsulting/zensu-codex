#!/bin/bash
# The reset skill must never rewrite workflow JSON directly. Re-arming goes
# through the same CAS transaction as every other workflow-state mutation.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/plugins/zensu/skills/reset-review-limit/SKILL.md"
PLUGIN_DIR="$ROOT/plugins/zensu"
PASS=0; FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = "PASS" ]; then
    echo "  PASS  $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"; FAIL=$((FAIL + 1))
  fi
}

if grep -qF 'fs.writeFileSync(process.argv[1]' "$SKILL"; then
  check "reset recipe has no direct workflow-state JSON write" FAIL
else
  check "reset recipe has no direct workflow-state JSON write" PASS
fi

if grep -qF 'tdd_reset_review_budget "$ZENSU_SESSION_KEY" "$REV_BEFORE"' "$SKILL" \
  && ! grep -qF 'tdd_set_flag "$ZENSU_SESSION_KEY" chainDone false' "$SKILL" \
  && grep -qF 'PROJECT_ROOT="$(node "$HOME/.zensu/session-control/codex/v3/resolve-v3.js" --field project_root)"' "$SKILL" \
  && ! grep -q 'STATE_DIR' "$SKILL"; then
  check "reset recipe resets counters and all chain flags through one CAS" PASS
else
  check "reset recipe uses exactly one review-budget CAS" FAIL
fi

if grep -qF '$HOME/.zensu/session-control/codex/v3/resolve-v3.js' "$SKILL" \
  && grep -qi 'revision' "$SKILL"; then
  check "Codex recipe resolves the bound plugin and documents revision advance" PASS
else
  check "Codex recipe resolves the bound plugin and documents revision advance" FAIL
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$WORK/project"
mkdir -p "$CLAUDE_PROJECT_DIR"
# shellcheck disable=SC1090
source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
SID="reset-transaction-revision"
KEY="$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key "$SID")"
HOME="$WORK/home"
mkdir -p "$HOME"
printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}' "$SID" "$CLAUDE_PROJECT_DIR" \
  | HOME="$HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null
export HOME ZENSU_SESSION_KEY="$KEY"
tdd_set_flag "$KEY" active true >/dev/null 2>&1
tdd_increment_counter "$KEY" reviewRound >/dev/null 2>&1
tdd_increment_counter "$KEY" stopBlocks >/dev/null 2>&1
tdd_set_flag "$KEY" chainDone true >/dev/null 2>&1
tdd_set_flag "$KEY" codeReviewDone true >/dev/null 2>&1
tdd_set_flag "$KEY" selfReviewFixed true >/dev/null 2>&1
STATE_FILE="$(tdd_state_file "$KEY")"
BYTES_BEFORE_REJECT="$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')"
INCOMPLETE_REV="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).revision))' "$STATE_FILE")"
if tdd_reset_review_budget "$KEY" "$INCOMPLETE_REV" >/dev/null 2>&1; then
  check "budget reset rejects an incomplete workflow" FAIL
elif [ "$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')" = "$BYTES_BEFORE_REJECT" ]; then
  check "rejected budget reset leaves state bytes and revision unchanged" PASS
else
  check "rejected budget reset is all-or-nothing" FAIL
fi
tdd_set_flag "$KEY" implComplete true >/dev/null 2>&1
REV_BEFORE="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).revision))' "$STATE_FILE")"
tdd_reset_review_budget "$KEY" "$REV_BEFORE" >/dev/null 2>&1
REV_AFTER="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).revision))' "$STATE_FILE")"
if [ "$(tdd_chain_done "$STATE_FILE")" = "false" ] \
  && [ "$(tdd_code_review_done "$STATE_FILE")" = "false" ] \
  && [ "$(tdd_self_review_fixed "$STATE_FILE")" = "false" ] \
  && [ "$(tdd_get_counter "$STATE_FILE" reviewRound)" = "0" ] \
  && [ "$(tdd_get_counter "$STATE_FILE" stopBlocks)" = "0" ] \
  && [ "$REV_AFTER" -eq $((REV_BEFORE + 1)) ]; then
  check "one budget CAS clears counters/all chain flags and advances one revision" PASS
else
  check "atomic budget reset state/revision contract" FAIL
fi

echo "----"
echo "test-reset-review-limit-transaction: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
