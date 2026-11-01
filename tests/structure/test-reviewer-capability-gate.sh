#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -d "$ROOT/plugins/zensu" ]; then PLUGIN="$ROOT/plugins/zensu"; else PLUGIN="$ROOT"; fi
GATE="$PLUGIN/hooks/pre-reviewer-capability-gate.sh"
POLICY="$PLUGIN/hooks/lib/reviewer-capability-v1.js"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for artifact in "$GATE" "$POLICY"; do
  [ -f "$artifact" ] && check "artifact exists: ${artifact#$PLUGIN/}" PASS || check "artifact exists: ${artifact#$PLUGIN/}" FAIL
done
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-reviewer-capability-gate: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_NATIVE="$TMP/home"
PROJECT="$TMP/project"
mkdir -p "$HOME_NATIVE" "$PROJECT"
printf '%s' '{"hook_event_name":"SessionStart","session_id":"capability-test","cwd":"'"$PROJECT"'"}' \
  | HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    bash "$PLUGIN/hooks/session-start-session-control.sh" >/dev/null

payload() {
  local input="${3:-}"
  [ -n "$input" ] || input='{}'
  AGENT_TYPE="$1" TOOL="$2" INPUT="$input" PROJECT="$PROJECT" node -e '
    const o = {
      hook_event_name: "PreToolUse",
      session_id: "capability-test",
      cwd: process.env.PROJECT,
      tool_name: process.env.TOOL,
      tool_input: JSON.parse(process.env.INPUT)
    };
    if (process.env.AGENT_TYPE !== "-") {
      o.agent_id = "agent-1";
      o.agent_type = process.env.AGENT_TYPE;
    }
    process.stdout.write(JSON.stringify(o));
  '
}

decision() {
  local out
  out="$(HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null)"
  if [ -z "$out" ]; then printf allow; return; fi
  printf '%s' "$out" | node -e '
    let s = ""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        process.stdout.write(j.hookSpecificOutput?.permissionDecision === "deny" ? "deny" : "other");
      } catch (_) { process.stdout.write("invalid"); }
    });
  '
}

assert_case() {
  local label="$1" expected="$2" type="$3" tool="$4" input="${5:-}" actual
  [ -n "$input" ] || input='{}'
  actual="$(payload "$type" "$tool" "$input" | decision)"
  [ "$actual" = "$expected" ] && check "$label" PASS || check "$label (expected $expected, got $actual)" FAIL
}

assert_case "main-thread writes are outside reviewer policy" allow - Write '{"file_path":"x"}'
assert_case "nested tool_input cannot impersonate a reviewer" allow - Write '{"agent_type":"zensu:code-reviewer","file_path":"x"}'
assert_case "PLM name receives only neutral direct-project edit capability" allow zensu-plm Write '{"file_path":"x"}'
assert_case "packet-only reviewer cannot invoke Read" deny zensu-code-reviewer Read '{"file_path":"x"}'
assert_case "packet-only aspect reviewer cannot invoke Glob" deny zensu-review-aspect Glob '{"pattern":"**/*"}'
assert_case "packet-only judge cannot invoke view_image" deny zensu-review-judge view_image '{"path":"x.png"}'
assert_case "colon reviewer near-miss stays neutral" allow zensu:code-reviewer Write '{"file_path":"x"}'
assert_case "custom review-like name stays neutral" allow zensu-review-domain Read '{"file_path":"x"}'
assert_case "custom review persona keeps neutral project edit capability" allow zensu-review-domain Write '{"file_path":"x"}'
assert_case "path-shaped reviewer near-miss stays neutral" allow /root/zensu_code_reviewer Write '{"file_path":"x"}'
assert_case "underscore reviewer near-miss stays neutral" allow zensu_review_aspect Write '{"file_path":"x"}'
assert_case "non-reviewer runtime path remains outside reviewer policy" allow /root/zensu_plm Write '{"file_path":"x"}'
assert_case "reviewer Write is denied" deny zensu-code-reviewer Write '{"file_path":"x"}'
assert_case "reviewer apply_patch is denied" deny zensu-review-aspect apply_patch '{"patch":"x"}'
assert_case "reviewer mutating shell is denied" deny zensu-code-reviewer exec_command '{"cmd":"printf x > source.js"}'
assert_case "reviewer shell is denied even for git diff" deny zensu-code-reviewer exec_command '{"cmd":"git diff HEAD -- src/app.js"}'
assert_case "reviewer shell is denied even for git status" deny zensu-review-aspect Bash '{"command":"git status --short"}'
assert_case "shell operators are denied" deny zensu-code-reviewer exec_command '{"cmd":"git diff HEAD -- src/app.js && rm -rf ."}'
assert_case "workflow-control shell invocation is denied" deny zensu-code-reviewer Bash '{"command":"bash hooks/lib/zensu-log.sh --chain-done"}'
assert_case "mutating MCP/control tool is denied" deny zensu-code-reviewer mcp__zensu__transition '{"state":"complete"}'
assert_case "nested Agent tool is denied" deny zensu-review-aspect Agent '{"subagent_type":"general-purpose"}'
assert_case "nested collaboration spawn is denied" deny zensu-review-judge spawn_agent '{"task_name":"attack"}'
assert_case "unknown reviewer tools fail closed" deny zensu-code-reviewer mystery_tool '{}'
assert_case "tool_input cannot impersonate main" deny zensu-code-reviewer Write '{"agent_type":"main","file_path":"x"}'
assert_case "array-shaped shell commands fail closed" deny zensu-code-reviewer shell '{"command":["git","diff","HEAD"]}'
assert_case "sandbox escalation requests fail closed" deny zensu:code-reviewer exec_command '{"cmd":"git diff HEAD -- src/app.js","sandbox_permissions":"require_escalated"}'
assert_case "neutral PLM cannot invoke shell" deny zensu-plm exec_command '{"cmd":"node $HOME/.zensu/session-control/codex/v3/resolve-v3.js --context"}'
assert_case "unknown profile cannot use an obfuscated workflow-state shell write" deny future-profile exec_command '{"cmd":"node -e '\''const f=\".zen\"+\"su/state/ATTACK\";require(\"fs\").writeFileSync(f,\"x\")'\''"}'
assert_case "unknown profile cannot read Session Control" deny future-profile Read '{"file_path":"'$HOME_NATIVE'/.zensu/session-control/codex/v3/resolve-v3.js"}'
assert_case "unknown profile cannot mutate workflow state" deny future-profile Write '{"file_path":".zensu/state/ATTACK","content":"x"}'
assert_case "neutral apply_patch cannot move a project file outside the project" deny future-profile apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/app.js\n*** Move to: ../escaped.js\n@@\n-old\n+new\n*** End Patch"}'
assert_case "neutral apply_patch cannot move a project file into workflow state" deny future-profile apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/app.js\n*** Move to: .zensu/state/escaped.js\n@@\n-old\n+new\n*** End Patch"}'
assert_case "neutral apply_patch may move a file within the project" allow future-profile apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/app.js\n*** Move to: src/renamed.js\n@@\n-old\n+new\n*** End Patch"}'
ln -s ../outside/new-file "$PROJECT/dangling-outside" 2>/dev/null
ln -s .zensu/state/dangling-control "$PROJECT/dangling-control" 2>/dev/null
assert_case "neutral Write rejects a dangling symlink leaf to outside" deny future-profile Write '{"file_path":"dangling-outside","content":"x"}'
assert_case "neutral apply_patch rejects a dangling symlink leaf to workflow state" deny future-profile apply_patch '{"patch":"*** Begin Patch\n*** Add File: dangling-control\n+x\n*** End Patch"}'
assert_case "unknown profile cannot invoke MCP control" deny future-profile mcp__zensu__transition '{"state":"complete"}'
assert_case "unknown profile cannot spawn a main-capable agent" deny future-profile spawn_agent '{"task_name":"main","agent_type":"worker"}'

codex_payload() {
  AGENT_TYPE="$1" TOOL="$2" INPUT="$3" PROJECT="$PROJECT" node -e '
    const o = {
      cwd: process.env.PROJECT,
      hook_event_name: "PreToolUse",
      model: "gpt-6-sol",
      permission_mode: "bypassPermissions",
      session_id: "capability-test",
      tool_input: JSON.parse(process.env.INPUT),
      tool_name: process.env.TOOL,
      tool_use_id: "call_measured",
      transcript_path: process.env.PROJECT + "/rollout.jsonl",
      turn_id: "turn-measured"
    };
    if (process.env.AGENT_TYPE !== "-") {
      o.agent_id = "thread-subagent";
      o.agent_type = process.env.AGENT_TYPE;
    }
    process.stdout.write(JSON.stringify(o));
  '
}

assert_codex_case() {
  local label="$1" expected="$2" type="$3" tool="$4" input="$5" actual
  actual="$(codex_payload "$type" "$tool" "$input" | decision)"
  [ "$actual" = "$expected" ] && check "$label" PASS || check "$label (expected $expected, got $actual)" FAIL
}

PATCH_ADD='{"command":"*** Begin Patch\n*** Add File: notes.txt\n+x\n*** End Patch\n"}'
PATCH_ESCAPE='{"command":"*** Begin Patch\n*** Update File: src/app.js\n*** Move to: ../escaped.js\n@@\n-old\n+new\n*** End Patch\n"}'
SPAWN_INPUT='{"task_name":"probe_task","message":"Implement the plan.","fork_turns":"none"}'
assert_codex_case "Codex 0.157.1 and 0.163.0main-thread apply_patch payload stays outside reviewer policy" allow - apply_patch "$PATCH_ADD"
assert_codex_case "Codex 0.157.1 and 0.163.0main-thread Bash payload stays outside reviewer policy" allow - Bash '{"command":"touch notes.txt"}'
assert_codex_case "Codex 0.157.1 and 0.163.0reviewer apply_patch payload is denied" deny zensu-code-reviewer apply_patch "$PATCH_ADD"
assert_codex_case "Codex 0.157.1 and 0.163.0aspect reviewer apply_patch payload is denied" deny zensu-review-aspect apply_patch "$PATCH_ADD"
assert_codex_case "Codex 0.157.1 and 0.163.0reviewer shell write is denied" deny zensu-review-aspect Bash '{"command":"touch notes.txt"}'
assert_codex_case "Codex 0.157.1 and 0.163.0reviewer code-mode spawn is denied" deny zensu-review-judge collaborationspawn_agent "$SPAWN_INPUT"
assert_codex_case "Codex 0.157.1 and 0.163.0reviewer classic wait is denied" deny zensu-code-reviewer multi_agent_v1wait_agent '{"targets":["thread-subagent"]}'
assert_codex_case "Codex 0.157.1 and 0.163.0default subagent apply_patch cannot move a file outside the project" deny default apply_patch "$PATCH_ESCAPE"
assert_codex_case "Codex 0.157.1 and 0.163.0default subagent code-mode spawn fails closed" deny default collaborationspawn_agent "$SPAWN_INPUT"

FORCED="$(payload zensu-code-reviewer Write '{"file_path":"x"}' | ZENSU_FORCE_MAIN=1 decision)"
[ "$FORCED" = deny ] && check "ZENSU_FORCE_MAIN cannot bypass reviewer boundary" PASS || check "ZENSU_FORCE_MAIN cannot bypass reviewer boundary" FAIL

MARKED_DEFAULT="$(payload default Write '{"file_path":"x"}' | ZENSU_AGENT_PROFILE=reviewer-readonly-v1 decision)"
[ "$MARKED_DEFAULT" = allow ] && check "ambient reviewer marker cannot activate policy for agent_type=default" PASS || check "ambient reviewer marker cannot activate policy for agent_type=default" FAIL

UNMARKED_DEFAULT="$(payload default Write '{"file_path":"x"}' | ZENSU_AGENT_PROFILE='' decision)"
[ "$UNMARKED_DEFAULT" = allow ] && check "unmarked agent_type=default remains outside reviewer policy" PASS || check "unmarked agent_type=default remains outside reviewer policy" FAIL

INVALID="$(printf 'not-json' | decision)"
[ "$INVALID" = deny ] && check "malformed trusted payload fails closed" PASS || check "malformed trusted payload fails closed" FAIL

printf '%s\n' "----" "test-reviewer-capability-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
