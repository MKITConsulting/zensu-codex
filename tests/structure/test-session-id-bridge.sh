#!/bin/bash
set -u

# Offline regression net for the Codex session-id contract after removal of
# project-local locator files. Hooks use payload.session_id; main-thread model
# commands use CODEX_THREAD_ID. Those two explicit sources must converge while
# foreign Claude ids and planted session-id pointer/cache files stay inert.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
WITNESS="$PLUGIN/hooks/post-bash-witness.sh"
ZLOG="$PLUGIN/hooks/lib/zensu-log.sh"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$WITNESS" "$ZLOG" "$HOOKS_JSON"; do
  [ -f "$f" ] || { check "required artifact present: $f" FAIL; exit 1; }
done
command -v node >/dev/null 2>&1 || { echo "  SKIP  node unavailable"; exit 0; }

if [ ! -e "$PLUGIN/hooks/session-start-capture-sid.sh" ] && ! grep -qF 'session-start-capture-sid.sh' "$HOOKS_JSON"; then
  check "B0 project-local session-id capture hook is removed and unwired" PASS
else
  check "B0 obsolete session-id capture hook still exists or is wired" FAIL
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
P="$TMP/project"
mkdir -p "$P/.zensu/state"
printf '%s\n' 'planted-pointer' > "$P/.zensu/state/session-id-current.txt"

THREAD_A="thread-aaaa-1111"
THREAD_B="thread-bbbb-2222"

pt_payload() {
  printf '{"session_id":"%s","turn_id":"t1","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"shell","tool_input":{"command":"node --test"},"tool_response":{"exit_code":0,"stdout":"1 pass"}}' "$1" "$P"
}

run_hook() {
  ( cd "$TMP" && CLAUDE_PROJECT_DIR='' CLAUDE_SESSION_ID='' CODEX_THREAD_ID='' \
    ZENSU_TEST_WITNESS='' bash "$WITNESS" )
}

run_agent() {
  ( cd "$P" && CLAUDE_PROJECT_DIR='' CLAUDE_SESSION_ID="${3:-}" CODEX_THREAD_ID="$1" \
    bash "$ZLOG" "$2" )
}

run_agent "$THREAD_A" --tdd-begin >/dev/null 2>&1
STATE_A="$P/.zensu/state/tdd-phase-${THREAD_A}.json"
if [ -f "$STATE_A" ]; then
  check "B1 main-thread CODEX_THREAD_ID arms the exact state file" PASS
else
  check "B1 exact state file missing" FAIL
fi

pt_payload "$THREAD_A" | run_hook >/dev/null 2>&1
WLOG_A="$P/.zensu/logs/witness-${THREAD_A}.log"
if [ -f "$WLOG_A" ] && grep -qF 'node --test' "$WLOG_A"; then
  check "B2 hook payload session_id reaches the same witness namespace" PASS
else
  check "B2 witness did not converge on the explicit payload id" FAIL
fi

run_agent "$THREAD_B" --tdd-begin >/dev/null 2>&1
STATE_B="$P/.zensu/state/tdd-phase-${THREAD_B}.json"
run_agent "$THREAD_A" --code-review-done >/dev/null 2>&1
FLAG_A="$(node -e 'process.stdout.write(String(require(process.argv[1]).codeReviewDone===true))' "$STATE_A" 2>/dev/null)"
FLAG_B="$(node -e 'process.stdout.write(String(require(process.argv[1]).codeReviewDone===true))' "$STATE_B" 2>/dev/null)"
if [ "$FLAG_A" = true ] && [ "$FLAG_B" = false ]; then
  check "B3 concurrent main threads mutate only their exact state" PASS
else
  check "B3 concurrent routing mismatch (A=$FLAG_A B=$FLAG_B)" FAIL
fi

FOREIGN="outer-claude-9999"
run_agent "$THREAD_A" --self-review-fixed "$FOREIGN" >/dev/null 2>&1
STATE_FOREIGN="$P/.zensu/state/tdd-phase-${FOREIGN}.json"
FLAG_A="$(node -e 'process.stdout.write(String(require(process.argv[1]).selfReviewFixed===true))' "$STATE_A" 2>/dev/null)"
if [ "$FLAG_A" = true ] && [ ! -e "$STATE_FOREIGN" ]; then
  check "B4 foreign CLAUDE_SESSION_ID cannot hijack CODEX_THREAD_ID" PASS
else
  check "B4 foreign host id affected routing" FAIL
fi

if [ "$(cat "$P/.zensu/state/session-id-current.txt")" = planted-pointer ] && \
   [ ! -e "$P/.zensu/state/session-id-${THREAD_A}.txt" ]; then
  check "B5 planted locator stays untouched and unused" PASS
else
  check "B5 project-local locator was rewritten or recreated" FAIL
fi

MODE_OUT="$(cd "$P" && CODEX_THREAD_ID="$THREAD_A" CLAUDE_SESSION_ID='' bash "$ZLOG" --mode 2>/dev/null)"
case "$MODE_OUT" in strict|vanilla) check "B6 --mode follows the same explicit env tier ($MODE_OUT)" PASS ;;
  *) check "B6 --mode returned '$MODE_OUT'" FAIL ;;
esac

echo "----"
echo "test-session-id-bridge: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
