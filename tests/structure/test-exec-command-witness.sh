#!/bin/bash
set -u

# Regression net for the Codex exec/exec_command witness gap (PR #36 autopilot
# diagnosis): runs driven via the `exec_command` function tool or the `exec`
# custom tool recorded NO witness lines because the hooks.json shell matchers
# only covered `shell|Bash`. Session Control v1 now also pins exact-key witness
# isolation. Pins:
#   W1  hooks.json matcher strings (write gate + witness, anchored)
#   W2  exec_command payload shape end-to-end ({cmd}, "Exit code: N" string
#       response -> exit= extraction incl. negatives, "Output:" body -> tail=)
#   W3  exec raw-string tool_input + {input} variant
#   W4  exact-key isolation: even a sole active legacy/fallback-shaped session
#       never adopts a foreign event
#   W5  multiple active states remain isolated
#   W6  zero active states -> silent
#   W7  write gate denies tracked-source writes in exec raw-string, {cmd},
#       and {input} shapes
#   W8  extraction branches: argv-array command join, camelCase exitCode,
#       envelope trusted only for exec tools, no-Output-marker fallback

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
WITNESS="$PLUGIN/hooks/post-bash-witness.sh"
GATE="$PLUGIN/hooks/pre-bash-source-write-gate.sh"
CORE="$PLUGIN/hooks/lib/session-control-core-v1.js"
SESSION_HOOK="$PLUGIN/hooks/session-start-session-control.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$HOOKS_JSON" "$WITNESS" "$GATE"; do
  if [ ! -f "$f" ]; then
    check "required file present: $f" FAIL
    echo "----"; echo "test-exec-command-witness: $PASS PASS / $FAIL FAIL"; exit 1
  fi
done
command -v node >/dev/null 2>&1 || {
  echo "  SKIP  test-exec-command-witness — node unavailable"; exit 0; }
command -v git >/dev/null 2>&1 || {
  echo "  SKIP  test-exec-command-witness — git unavailable"; exit 0; }

TMP_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
EMPTY_CFG="$TMP_DIR/empty-config.json"
printf '{}' > "$EMPTY_CFG"

UUID_A="0199aaaa-1111-7000-8000-000000000001"
UUID_B="0199bbbb-2222-7000-8000-000000000002"
UUID_Y="0199cccc-3333-7000-8000-000000000003"
FBK_ID="fallback_4242_99"
session_key() { node "$CORE" session-key "$1"; }
KEY_A="$(session_key "$UUID_A")"
KEY_B="$(session_key "$UUID_B")"
KEY_Y="$(session_key "$UUID_Y")"
FBK_KEY="$(session_key "$FBK_ID")"

new_project() {  # $1=name -> echoes project dir with .zensu tree
  local p="$TMP_DIR/$1"
  mkdir -p "$p" "$p/.test-home"
  echo "$p"
}
arm_state() {  # $1=project  $2=session-id  $3=active(true|false)
  local home
  home="$1/.test-home"
  mkdir -p "$home"
  printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}' "$2" "$1" \
    | env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      HOME="$home" CLAUDE_PLUGIN_ROOT="$PLUGIN" PLUGIN_ROOT="$PLUGIN" \
      bash "$SESSION_HOOK" >/dev/null 2>&1 || return 1
  SID="$2" ACT="$3" CORE="$CORE" PROJECT="$1" node -e '
    const core = require(process.env.CORE);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT,
      sessionId: process.env.SID,
      workflowState: process.env.ACT === "true" ? "active" : "idle",
      event: "test-seed",
    }, (state) => ({ ...state, active: process.env.ACT === "true", vanilla: true }));
  ' >/dev/null
}
run_witness() {  # stdin=payload — codex hook context: clean env; the project
  # dir resolves SOLELY from the payload cwd (zensu_runtime_apply_project_dir)
  local payload project home
  payload="$(cat)"
  project="$(PAYLOAD="$payload" node -e '
    const value=JSON.parse(process.env.PAYLOAD); process.stdout.write(value.cwd || "");
  ' 2>/dev/null)" || return 0
  home="$project/.test-home"
  ( cd "$TMP_DIR" && printf '%s' "$payload" | \
    HOME="$home" CLAUDE_PROJECT_DIR='' CLAUDE_SESSION_ID='' CODEX_THREAD_ID='' ZENSU_SESSION_KEY='' \
    ZENSU_SESSION_CONTEXT='' ZENSU_PROJECT_ROOT='' ZENSU_RUNTIME_DIGEST='' ZENSU_TEST_WITNESS='' \
    ZENSU_PLUGIN_ROOT='' CODEX_PLUGIN_ROOT='' CLAUDE_PLUGIN_ROOT='' \
    ZENSU_CONFIG="$EMPTY_CFG" LC_ALL=C LANG=C bash "$WITNESS" )
}
run_gate() {  # $1=project-cwd  stdin=payload — gate hook context, temp carve-out defeated
  ( cd "$1" && CLAUDE_PROJECT_DIR='' ZENSU_BASH_WRITE_GATE='' ZENSU_MCP_GATE='' \
      ZENSU_PLUGIN_ROOT='' CODEX_PLUGIN_ROOT='' CLAUDE_PLUGIN_ROOT='' \
      ZENSU_BSWGATE_TEMP_DIRS="$TMP_DIR/no-temp-exemption" \
      ZENSU_CONFIG="$EMPTY_CFG" LC_ALL=C LANG=C bash "$GATE" ) 2>/dev/null
}
gate_denies() {  # stdin=gate stdout — true iff a parsed JSON deny verdict
  node -e '
    let s = ""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => {
      try { const j = JSON.parse(s);
        const d = j.hookSpecificOutput && j.hookSpecificOutput.permissionDecision;
        process.exit(d === "deny" ? 0 : 1);
      } catch (_) { process.exit(1); }
    });'
}

# ── W1: matcher pins (anchored) ──────────────────────────────────────────────
MATCHERS="$(node -e '
  const h = require(process.argv[1]).hooks;
  const gate = h.PreToolUse.find(e => (e.hooks||[]).some(x => String(x.command).includes("pre-bash-source-write-gate")));
  const wit  = h.PostToolUse.find(e => (e.hooks||[]).some(x => String(x.command).includes("post-bash-witness")));
  process.stdout.write((gate ? gate.matcher : "MISSING") + "\n" + (wit ? wit.matcher : "MISSING"));
' "$HOOKS_JSON" 2>/dev/null)"
GATE_MATCHER="$(printf '%s' "$MATCHERS" | sed -n 1p)"
WIT_MATCHER="$(printf '%s' "$MATCHERS" | sed -n 2p)"
WANT_MATCHER='^(shell|Bash|exec_command|exec)$'
if [ "$GATE_MATCHER" = "$WANT_MATCHER" ]; then
  check "W1a write-gate matcher anchored, covers exec_command + exec" PASS
else
  check "W1a write-gate matcher (got '$GATE_MATCHER')" FAIL
fi
if [ "$WIT_MATCHER" = "$WANT_MATCHER" ]; then
  check "W1b witness matcher anchored, covers exec_command + exec" PASS
else
  check "W1b witness matcher (got '$WIT_MATCHER')" FAIL
fi

# ── W2: exec_command shape end-to-end ────────────────────────────────────────
P2="$(new_project w2)"
arm_state "$P2" "$UUID_A" true
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"npm test -- --run","yield_time_ms":1000},"tool_response":"Exit code: 3\\nWall time: 1.2 seconds\\nOutput:\\nall green trailer"}' \
  "$UUID_A" "$P2" | run_witness >/dev/null 2>&1
W2LOG="$P2/.zensu/logs/witness-$KEY_A.log"
if [ -f "$W2LOG" ] && grep -qF 'cmd="npm test -- --run"' "$W2LOG"; then
  check "W2a exec_command {cmd} recorded verbatim" PASS
else
  check "W2a exec_command {cmd} recorded (log: $(cat "$W2LOG" 2>/dev/null))" FAIL
fi
if grep -qF 'exit=3' "$W2LOG" 2>/dev/null; then
  check "W2b exit extracted from 'Exit code: N' string response" PASS
else
  check "W2b exit extraction (log: $(cat "$W2LOG" 2>/dev/null))" FAIL
fi
if grep -qF 'all green trailer' "$W2LOG" 2>/dev/null && ! grep -qF 'Wall time' "$W2LOG" 2>/dev/null; then
  check "W2c tail taken from the Output: body, not the whole envelope" PASS
else
  check "W2c tail body (log: $(cat "$W2LOG" 2>/dev/null))" FAIL
fi
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"killed by signal"},"tool_response":"Exit code: -1\\nWall time: 0.1 seconds\\nOutput:\\nterminated"}' \
  "$UUID_A" "$P2" | run_witness >/dev/null 2>&1
if grep -qF 'exit=-1' "$W2LOG" 2>/dev/null; then
  check "W2d negative exit code extracted" PASS
else
  check "W2d negative exit (log: $(tail -1 "$W2LOG" 2>/dev/null))" FAIL
fi

# ── W3: exec raw-string tool_input + {input} variant ─────────────────────────
P3="$(new_project w3)"
arm_state "$P3" "$UUID_A" true
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec","tool_input":"echo raw-shape","tool_response":{"exit_code":2,"stdout":"boom"}}' \
  "$UUID_A" "$P3" | run_witness >/dev/null 2>&1
W3LOG="$P3/.zensu/logs/witness-$KEY_A.log"
if [ -f "$W3LOG" ] && grep -qF 'cmd="echo raw-shape"' "$W3LOG" && grep -qF 'exit=2' "$W3LOG"; then
  check "W3a raw-string tool_input recorded (object exit_code kept)" PASS
else
  check "W3a raw-string tool_input (log: $(cat "$W3LOG" 2>/dev/null))" FAIL
fi
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec","tool_input":{"input":"echo via-input"},"tool_response":{"exit_code":0,"stdout":"ok"}}' \
  "$UUID_A" "$P3" | run_witness >/dev/null 2>&1
if grep -qF 'cmd="echo via-input"' "$W3LOG" 2>/dev/null; then
  check "W3b tool_input.input recorded" PASS
else
  check "W3b tool_input.input (log: $(cat "$W3LOG" 2>/dev/null))" FAIL
fi

# ── W4: exact Session Control key — no legacy/fallback adoption ──────────────
P4="$(new_project w4)"
arm_state "$P4" "$FBK_ID" true
arm_state "$P4" "$UUID_B" false
# Legacy and malformed state names beside the exact state must remain inert.
printf 'not json{' > "$P4/.zensu/state/tdd-phase-corrupt.json"
STR_ACTIVE="$P4/.zensu/state/tdd-phase-strbool.json"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({session_id:"strbool",active:"true",vanilla:true}))' "$STR_ACTIVE"
# None of these files may be scanned or adopted.
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1], JSON.stringify({session_id:"huge",active:true,pad:"x".repeat(70000)}))' "$P4/.zensu/state/tdd-phase-huge.json"
REAL_ACTIVE="$TMP_DIR/w4-linked-active.json"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({session_id:"linked",active:true,vanilla:true}))' "$REAL_ACTIVE"
ln -s "$REAL_ACTIVE" "$P4/.zensu/state/tdd-phase-linked.json" 2>/dev/null
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"echo exact-match"},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$FBK_ID" "$P4" | run_witness >/dev/null 2>&1
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"cargo test"},"tool_response":"Exit code: 0\\nWall time: 0.4 seconds\\nOutput:\\n7 passed"}' \
  "$UUID_Y" "$P4" | run_witness >/dev/null 2>&1
W4LOG="$P4/.zensu/logs/witness-$FBK_KEY.log"
if [ -f "$W4LOG" ] && grep -qF 'cmd="echo exact-match"' "$W4LOG" && ! grep -qF 'cmd="cargo test"' "$W4LOG"; then
  check "W4a exact fallback-shaped payload records without adopting foreign events" PASS
else
  check "W4a exact-only witness (log: $(cat "$W4LOG" 2>/dev/null))" FAIL
fi
if [ "$(grep -cF 'BASH cmd=' "$W4LOG" 2>/dev/null)" = "1" ]; then
  check "W4b foreign event produces no second line" PASS
else
  check "W4b line count (got $(grep -cF 'BASH cmd=' "$W4LOG" 2>/dev/null))" FAIL
fi
if ! grep -qF 'origin=' "$W4LOG" 2>/dev/null; then
  check "W4c legacy origin/adoption channel is absent" PASS
else
  check "W4c obsolete origin tag leaked (log: $(cat "$W4LOG" 2>/dev/null))" FAIL
fi
if [ ! -f "$P4/.zensu/logs/witness-$KEY_Y.log" ]; then
  check "W4d no log under the divergent payload id" PASS
else
  check "W4d unexpected witness-$KEY_Y.log" FAIL
fi
P4N="$(new_project w4n)"
arm_state "$P4N" "$UUID_A" true
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"pytest -q"},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$UUID_Y" "$P4N" | run_witness >/dev/null 2>&1
if [ -z "$(ls "$P4N/.zensu/logs" 2>/dev/null)" ]; then
  check "W4e sole active NON-fallback session never adopts foreign events" PASS
else
  check "W4e non-fallback adoption leak (logs: $(ls "$P4N/.zensu/logs"))" FAIL
fi

# ── W5: two active states -> NO adoption ─────────────────────────────────────
P5="$(new_project w5)"
arm_state "$P5" "$FBK_ID" true
arm_state "$P5" "fallback_777_11" true
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"pytest -q"},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$UUID_Y" "$P5" | run_witness >/dev/null 2>&1
if [ -z "$(ls "$P5/.zensu/logs" 2>/dev/null)" ]; then
  check "W5 two active states stay exact-match-only (silent)" PASS
else
  check "W5 ambiguous-active leak (logs: $(ls "$P5/.zensu/logs"))" FAIL
fi

# ── W6: zero active states -> silent ─────────────────────────────────────────
P6="$(new_project w6)"
arm_state "$P6" "$FBK_ID" false
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"go test ./..."},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$UUID_Y" "$P6" | run_witness >/dev/null 2>&1
if [ -z "$(ls "$P6/.zensu/logs" 2>/dev/null)" ]; then
  check "W6 zero active states stay silent" PASS
else
  check "W6 inactive leak (logs: $(ls "$P6/.zensu/logs"))" FAIL
fi

# ── W7: write gate denies exec-shaped tracked-source writes ──────────────────
P7="$TMP_DIR/w7"
mkdir -p "$P7/src"
( cd "$P7" && git init -q . && git config user.email t@t && git config user.name t \
  && printf 'fn main() {}\n' > src/app.rs && git add src/app.rs && git commit -qm init ) >/dev/null 2>&1
if printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"exec","tool_input":"printf x >> src/app.rs"}' "$UUID_A" "$P7" | run_gate "$P7" | gate_denies; then
  check "W7a gate denies tracked-source write in exec raw-string shape" PASS
else
  check "W7a gate denial raw-string" FAIL
fi
if printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"exec_command","tool_input":{"cmd":"printf x >> src/app.rs"}}' "$UUID_A" "$P7" | run_gate "$P7" | gate_denies; then
  check "W7b gate denies tracked-source write in {cmd} shape" PASS
else
  check "W7b gate denial {cmd}" FAIL
fi
if printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"input":"printf x >> src/app.rs"}}' "$UUID_A" "$P7" | run_gate "$P7" | gate_denies; then
  check "W7c gate denies tracked-source write in {input} shape" PASS
else
  check "W7c gate denial {input}" FAIL
fi
if printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":["bash","-lc","printf x >> src/app.rs"]}}' "$UUID_A" "$P7" | run_gate "$P7" | gate_denies; then
  check "W7d gate denies tracked-source write in argv-array shape" PASS
else
  check "W7d gate denial argv-array" FAIL
fi

# ── W8: extraction branches ──────────────────────────────────────────────────
P8="$(new_project w8)"
arm_state "$P8" "$UUID_A" true
W8LOG="$P8/.zensu/logs/witness-$KEY_A.log"
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"shell","tool_input":{"command":["bash","-lc","npm run build"]},"tool_response":{"exit_code":0,"stdout":"built"}}' \
  "$UUID_A" "$P8" | run_witness >/dev/null 2>&1
if grep -qF 'cmd="bash -lc npm run build"' "$W8LOG" 2>/dev/null; then
  check "W8a argv-array command joined" PASS
else
  check "W8a argv-array (log: $(tail -1 "$W8LOG" 2>/dev/null))" FAIL
fi
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo camel"},"tool_response":{"exitCode":5,"stdout":"x"}}' \
  "$UUID_A" "$P8" | run_witness >/dev/null 2>&1
if grep -F 'cmd="echo camel"' "$W8LOG" 2>/dev/null | grep -qF 'exit=5'; then
  check "W8b camelCase exitCode honored" PASS
else
  check "W8b exitCode (log: $(tail -1 "$W8LOG" 2>/dev/null))" FAIL
fi
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"shell","tool_input":{"command":"cat report"},"tool_response":"Exit code: 0 is what the report claims"}' \
  "$UUID_A" "$P8" | run_witness >/dev/null 2>&1
if grep -F 'cmd="cat report"' "$W8LOG" 2>/dev/null | grep -qF 'exit=?'; then
  check "W8c envelope exit trusted only for exec tools (shell string stays ?)" PASS
else
  check "W8c envelope spoof guard (log: $(tail -1 "$W8LOG" 2>/dev/null))" FAIL
fi
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec","tool_input":"true","tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nno marker here"}' \
  "$UUID_A" "$P8" | run_witness >/dev/null 2>&1
if grep -F 'cmd="true"' "$W8LOG" 2>/dev/null | grep -qF 'no marker here'; then
  check "W8d no-Output-marker envelope falls back to whole string tail" PASS
else
  check "W8d no-marker fallback (log: $(tail -1 "$W8LOG" 2>/dev/null))" FAIL
fi

# ── W9: a git-TRACKED sole-active fallback state is never adopted (planted) ──
P9="$TMP_DIR/w9"
mkdir -p "$P9/.zensu/state" "$P9/.zensu/logs"
( cd "$P9" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
arm_state "$P9" "$FBK_ID" true
( cd "$P9" && git add -f .zensu/state/tdd-phase-$FBK_KEY.json && git commit -qm plant ) >/dev/null 2>&1
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"echo pwned"},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$UUID_Y" "$P9" | run_witness >/dev/null 2>&1
if [ -z "$(ls "$P9/.zensu/logs" 2>/dev/null)" ]; then
  check "W9 git-tracked (planted) sole-active state is refused, no adoption" PASS
else
  check "W9 planted-state adoption leak (logs: $(ls "$P9/.zensu/logs"))" FAIL
fi

# ── W10: a symlinked witness log target is refused (no write-through) ─────────
P10="$(new_project w10)"
arm_state "$P10" "$UUID_A" true
OUTSIDE="$TMP_DIR/w10-outside-target"
printf 'PRISTINE' > "$OUTSIDE"
ln -s "$OUTSIDE" "$P10/.zensu/logs/witness-$KEY_A.log" 2>/dev/null
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"echo redirect"},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$UUID_A" "$P10" | run_witness >/dev/null 2>&1
if [ "$(cat "$OUTSIDE" 2>/dev/null)" = "PRISTINE" ]; then
  check "W10 symlinked witness log target is not written through" PASS
else
  check "W10 symlink write-through (target: $(cat "$OUTSIDE" 2>/dev/null))" FAIL
fi

# ── W11: a non-canonical sole-active fallback filename is NOT adopted ─────────
# (its sanitized id would differ from the on-disk name, defeating the tracked
# check — the scanner must reject it rather than emit a mismatched id).
P11="$(new_project w11)"
mkdir -p "$P11/.zensu/state" "$P11/.zensu/logs"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({session_id:"x",active:true,vanilla:true}))' "$P11/.zensu/state/tdd-phase-fallback_a.b.json"
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"echo noncanon"},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$UUID_Y" "$P11" | run_witness >/dev/null 2>&1
if [ -z "$(ls "$P11/.zensu/logs" 2>/dev/null)" ]; then
  check "W11 non-canonical sole-active fallback name is not adopted" PASS
else
  check "W11 non-canonical adoption leak (logs: $(ls "$P11/.zensu/logs"))" FAIL
fi

# ── W12: a symlinked .zensu/logs DIR target is refused (no write-through) ─────
P12="$(new_project w12)"
arm_state "$P12" "$UUID_A" true
OUT12="$TMP_DIR/w12-outside-logdir"; mkdir -p "$OUT12"
rm -rf "$P12/.zensu/logs"; ln -s "$OUT12" "$P12/.zensu/logs" 2>/dev/null
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"echo dir-link"},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$UUID_A" "$P12" | run_witness >/dev/null 2>&1
if [ -z "$(ls "$OUT12" 2>/dev/null)" ]; then
  check "W12 symlinked .zensu/logs dir is not written through" PASS
else
  check "W12 logs-dir symlink write-through (target: $(ls "$OUT12"))" FAIL
fi

# ── W13: a symlinked .zensu ANCESTOR is refused (no write-through) ────────────
P13="$TMP_DIR/w13"; mkdir -p "$P13"
arm_state "$P13" "$UUID_A" true
REAL13="$TMP_DIR/w13-real-zensu"
mv "$P13/.zensu" "$REAL13"
ln -s "$REAL13" "$P13/.zensu" 2>/dev/null
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"exec_command","tool_input":{"cmd":"echo ancestor-link"},"tool_response":"Exit code: 0\\nWall time: 0.1 seconds\\nOutput:\\nok"}' \
  "$UUID_A" "$P13" | run_witness >/dev/null 2>&1
if [ -z "$(ls "$REAL13/logs" 2>/dev/null)" ]; then
  check "W13 symlinked .zensu ancestor is not written through" PASS
else
  check "W13 ancestor symlink write-through (target: $(ls "$REAL13/logs"))" FAIL
fi

echo "----"
echo "test-exec-command-witness: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
