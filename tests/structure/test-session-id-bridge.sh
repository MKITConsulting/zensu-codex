#!/bin/bash
set -u

# Offline end-to-end regression net for the headless-codex session-id bridge —
# the exact failure the live reference eval caught (witnessRan=false): the
# SessionStart hook, the agent-side zensu-log.sh, and the PostToolUse witness
# hook must all resolve the SAME session id or the witness never records the
# test run. Simulates the codex runtime contract deterministically:
#   - hooks receive the payload on stdin (session_id + cwd) and run with a
#     clean C-locale env,
#   - agent shell commands get CODEX_THREAD_ID exported and carry the user
#     locale, but never CLAUDE_SESSION_ID (probe-verified MAIN-thread contract;
#     subagent-shell semantics are unpinned — skills confine state markers to
#     the main thread).
# B1 pins the single-session bridge; B2 pins the concurrent-session hazard
# where a second session's SessionStart clobbers the project-global
# session-id-current.txt pointer between agent commands.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
CAPTURE="$PLUGIN/hooks/session-start-capture-sid.sh"
WITNESS="$PLUGIN/hooks/post-bash-witness.sh"
ZLOG="$PLUGIN/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$CAPTURE" "$WITNESS" "$ZLOG"; do
  if [ ! -f "$f" ]; then
    check "required script present: $f" FAIL
    echo "----"; echo "test-session-id-bridge: $PASS PASS / $FAIL FAIL"; exit 1
  fi
done
command -v node >/dev/null 2>&1 || {
  echo "  SKIP  test-session-id-bridge — node unavailable"; exit 0; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
P="$TMP_DIR/project"
EMPTY_PROJECTS="$TMP_DIR/empty-projects"
mkdir -p "$P" "$EMPTY_PROJECTS"

THREAD_A="thread-aaaa-1111"
THREAD_B="thread-bbbb-2222"

ss_payload() {
  printf '{"session_id":"%s","transcript_path":"/tmp/rollout-%s.jsonl","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1" "$1" "$2"
}
pt_payload() {
  printf '{"session_id":"%s","turn_id":"t1","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"shell","tool_input":{"command":"node --test"},"tool_response":{"exit_code":0,"stdout":"1 pass"}}' "$1" "$2"
}

run_hook() {  # $1=script  stdin=payload — codex hook context: clean C locale, no ids in env
  ( cd "$TMP_DIR" && \
    CLAUDE_PROJECT_DIR='' CLAUDE_SESSION_ID='' CODEX_THREAD_ID='' ZENSU_TEST_WITNESS='' \
    ZENSU_PROJECTS_DIR="$EMPTY_PROJECTS" LC_ALL=C LANG=C bash "$1" )
}
run_agent() {  # $1=thread-id  $2...=zensu-log args — codex agent shell: thread id env, user locale
  ( cd "$P" && CLAUDE_PROJECT_DIR='' CLAUDE_SESSION_ID='' CODEX_THREAD_ID="$1" \
      ZENSU_PROJECTS_DIR="$EMPTY_PROJECTS" bash "$ZLOG" "${@:2}" )
}

# ── B1: single-session bridge — SessionStart -> --tdd-begin -> witness ──────
ss_payload "$THREAD_A" "$P" | run_hook "$CAPTURE" >/dev/null 2>&1

PTR="$P/.zensu/state/session-id-current.txt"
if [ -f "$PTR" ] && [ "$(cat "$PTR")" = "$THREAD_A" ]; then
  check "B1-1 capture-sid wrote the pointer with the payload session_id" PASS
else
  check "B1-1 capture-sid pointer (got '$(cat "$PTR" 2>/dev/null)')" FAIL
fi

run_agent "$THREAD_A" --tdd-begin >/dev/null 2>&1
STATE_A="$P/.zensu/state/tdd-phase-${THREAD_A}.json"
if [ -f "$STATE_A" ] && [ "$(node -e 'process.stdout.write(String(require(process.argv[1]).active===true))' "$STATE_A" 2>/dev/null)" = "true" ]; then
  check "B1-2 agent --tdd-begin armed the state file under the THREAD id" PASS
else
  check "B1-2 agent state file (expected active tdd-phase-${THREAD_A}.json)" FAIL
fi

pt_payload "$THREAD_A" "$P" | run_hook "$WITNESS" >/dev/null 2>&1
WLOG_A="$P/.zensu/logs/witness-${THREAD_A}.log"
if [ -f "$WLOG_A" ] && grep -qF 'BASH cmd=' "$WLOG_A" && grep -qF 'node --test' "$WLOG_A"; then
  check "B1-3 witness hook recorded the command under the same id" PASS
else
  check "B1-3 witness log (expected witness-${THREAD_A}.log with BASH cmd=)" FAIL
fi

# ── B2: concurrent-session pointer clobber — session B starts, agent A must
#        still write ITS OWN state, not session B's ─────────────────────────
ss_payload "$THREAD_B" "$P" | run_hook "$CAPTURE" >/dev/null 2>&1
if [ -f "$PTR" ] && [ "$(cat "$PTR")" = "$THREAD_B" ]; then
  check "B2-1 second session clobbered the project-global pointer (precondition)" PASS
else
  check "B2-1 pointer clobber precondition (got '$(cat "$PTR" 2>/dev/null)')" FAIL
fi

run_agent "$THREAD_A" --code-review-done >/dev/null 2>&1
FLAG_A="$(node -e 'process.stdout.write(String(require(process.argv[1]).codeReviewDone===true))' "$STATE_A" 2>/dev/null)"
STATE_B="$P/.zensu/state/tdd-phase-${THREAD_B}.json"
FLAG_B="false"
[ -f "$STATE_B" ] && FLAG_B="$(node -e 'process.stdout.write(String(require(process.argv[1]).codeReviewDone===true))' "$STATE_B" 2>/dev/null)"
if [ "$FLAG_A" = "true" ] && [ "$FLAG_B" != "true" ]; then
  check "B2-2 agent A's flag landed in A's state despite clobbered pointer (env tier)" PASS
else
  check "B2-2 flag routing (A codeReviewDone='$FLAG_A' B codeReviewDone='$FLAG_B' — pointer hijacked the write)" FAIL
fi

pt_payload "$THREAD_A" "$P" | run_hook "$WITNESS" >/dev/null 2>&1
LINES_A="$(grep -cF 'BASH cmd=' "$WLOG_A" 2>/dev/null)"
LINES_A="${LINES_A:-0}"
if [ "$LINES_A" -eq 2 ]; then
  check "B2-3 witness for session A still appends after the clobber (exactly one line per command)" PASS
else
  check "B2-3 witness continuity (lines=$LINES_A expected exactly 2)" FAIL
fi

pt_payload "$THREAD_B" "$P" | run_hook "$WITNESS" >/dev/null 2>&1
WLOG_B="$P/.zensu/logs/witness-${THREAD_B}.log"
if [ ! -f "$WLOG_B" ]; then
  check "B2-4 witness stays silent for the un-armed session (no --tdd-begin, no log)" PASS
else
  check "B2-4 witness selectivity (witness-${THREAD_B}.log written without an armed session)" FAIL
fi

# ── B3: nested dual-CLI hijack — the agent shell carries BOTH a foreign
#        CLAUDE_SESSION_ID (outer Claude Code session) and the native
#        CODEX_THREAD_ID; the flag must land under the thread id. Mutation
#        guard: reverting either the zensu-log.sh '' call sites (arg tier would
#        adopt the foreign id) or the resolver's CODEX-first env order turns
#        this red. ───────────────────────────────────────────────────────────
FOREIGN="outer-claude-9999"
( cd "$P" && CLAUDE_PROJECT_DIR='' CLAUDE_SESSION_ID="$FOREIGN" CODEX_THREAD_ID="$THREAD_A" \
    ZENSU_PROJECTS_DIR="$EMPTY_PROJECTS" bash "$ZLOG" --self-review-fixed ) >/dev/null 2>&1
B3_A="$(node -e 'process.stdout.write(String(require(process.argv[1]).selfReviewFixed===true))' "$STATE_A" 2>/dev/null)"
STATE_F="$P/.zensu/state/tdd-phase-${FOREIGN}.json"
if [ "$B3_A" = "true" ] && [ ! -f "$STATE_F" ]; then
  check "B3 foreign CLAUDE_SESSION_ID cannot hijack the write (thread id wins end-to-end)" PASS
else
  check "B3 dual-CLI hijack (A selfReviewFixed='$B3_A' foreign-file-exists=$([ -f "$STATE_F" ] && echo yes || echo no))" FAIL
fi

# ── B4: zensu-log.sh --mode resolves through the same env tier (execution
#        coverage for the --mode dispatch arm) and agrees with the armed
#        session's vanilla flag. ──────────────────────────────────────────────
MODE_OUT="$( cd "$P" && CLAUDE_PROJECT_DIR='' CLAUDE_SESSION_ID='' CODEX_THREAD_ID="$THREAD_A" \
    ZENSU_PROJECTS_DIR="$EMPTY_PROJECTS" bash "$ZLOG" --mode 2>/dev/null )"
VAN_A="$(node -e 'process.stdout.write(String(require(process.argv[1]).vanilla===true))' "$STATE_A" 2>/dev/null)"
EXPECT_MODE="strict"; [ "$VAN_A" = "true" ] && EXPECT_MODE="vanilla"
if [ "$MODE_OUT" = "$EXPECT_MODE" ]; then
  check "B4 --mode resolves via env tier and matches the armed session's flag ($MODE_OUT)" PASS
else
  check "B4 --mode routing (got '$MODE_OUT' expected '$EXPECT_MODE')" FAIL
fi

echo "----"
echo "test-session-id-bridge: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
