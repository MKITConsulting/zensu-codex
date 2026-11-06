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

SESSION_CORE="$PLUGIN/hooks/lib/session-control-core-v1.js"
PROBE="$ROOT/tests/fixtures/workflow-state-access-probe.js"
VERDICT="$ROOT/tests/fixtures/workflow-state-access-verdict.js"
RECORDS="$HOME_NATIVE/.zensu/session-control/codex/v3/records"

state_session() {
  local project="$TMP/state-$1" plugin="${2:-$PLUGIN}"
  mkdir -p "$project"
  printf '%s' '{"hook_event_name":"SessionStart","session_id":"state-'"$1"'","cwd":"'"$project"'"}' \
    | HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$plugin" \
      bash "$plugin/hooks/session-start-session-control.sh" >/dev/null
  printf '%s/.zensu/state/tdd-phase-%s.json' "$project" "$(node "$SESSION_CORE" session-key "state-$1")"
}

state_payload() {
  SID="state-$1" PROJECT_DIR="$TMP/state-$1" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PreToolUse",
      session_id: process.env.SID,
      cwd: process.env.PROJECT_DIR,
      tool_name: "Write",
      tool_input: { file_path: "x" }
    }));
  '
}

state_gate() {
  state_payload "$1" | HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$GATE" 2>/dev/null
}

probe_gate() {
  local name="$1" plugin="${2:-$PLUGIN}"
  rm -f "$TMP/probe-$name.jsonl"
  state_payload "$name" \
    | HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$plugin" ZENSU_PROBE_ROOTS="$TMP/state-$name" \
      ZENSU_PROBE_REPORT="$TMP/probe-$name.jsonl" NODE_OPTIONS="--require \"$PROBE\"" \
      bash "$plugin/hooks/pre-reviewer-capability-gate.sh" 2>/dev/null
}

probe_verdict() {
  local name="$1"
  shift
  node "$VERDICT" "$TMP/probe-$name.jsonl" "$@" >"$TMP/probe-$name.verdict" 2>&1
}

probe_failure() {
  cat "$TMP/probe-$1.verdict" 2>/dev/null
}

zensu_digest() {
  if [ -e "$1/.zensu" ]; then
    (cd "$1/.zensu" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort)
  else
    printf 'absent\n'
  fi
}

record_plugin_root() {
  node -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).plugin_root)' \
    "$RECORDS/$(node "$SESSION_CORE" session-key "state-$1").json" 2>/dev/null
}

assert_state_denied() {
  local label="$1" name="$2" cause="$3" absent="${4:-}" out
  out="$(state_gate "$name")"
  if printf '%s' "$out" | grep -qF '"permissionDecision":"deny"' \
    && printf '%s' "$out" | grep -qF "immutable context revalidation failed: session-control-v1: $cause." \
    && { [ -z "$absent" ] || [ ! -e "$absent" ]; }; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
}

STATE_INTACT="$(state_session intact)"
if [ -f "$STATE_INTACT" ] && [ -z "$(state_gate intact)" ]; then
  check "a fresh session's workflow state passes the capability gate" PASS
else
  check "a fresh session's workflow state passes the capability gate" FAIL
fi

state_session root >/dev/null
rm -rf "$TMP/state-root/.zensu"
assert_state_denied "the capability gate denies a removed workflow root and creates none" \
  root "workflow root is missing" "$TMP/state-root/.zensu"

state_session directory >/dev/null
rm -rf "$TMP/state-directory/.zensu/state"
assert_state_denied "the capability gate denies a removed workflow state directory and creates none" \
  directory "workflow state directory is missing" "$TMP/state-directory/.zensu/state"

STATE_FILE_LINK="$(state_session file-link)"
mv "$STATE_FILE_LINK" "$TMP/state-file-link-target.json" && ln -s "$TMP/state-file-link-target.json" "$STATE_FILE_LINK"
assert_state_denied "the capability gate denies a symlinked workflow state file" file-link "workflow state file is unsafe"

state_session directory-link >/dev/null
mv "$TMP/state-directory-link/.zensu/state" "$TMP/state-directory-link-target" \
  && ln -s "$TMP/state-directory-link-target" "$TMP/state-directory-link/.zensu/state"
assert_state_denied "the capability gate denies a symlinked workflow state directory" directory-link "workflow state directory is unsafe"

STATE_HARD_LINK="$(state_session hard-link)"
ln "$STATE_HARD_LINK" "$TMP/state-hard-link-alias.json"
assert_state_denied "the capability gate denies a multi-linked workflow state file" hard-link "workflow state file is unsafe"

mkdir -p "$TMP/state-alias/.ZENSU"
if [ -d "$TMP/state-alias/.zensu" ]; then
  printf '%s' '{"hook_event_name":"SessionStart","session_id":"state-alias","cwd":"'"$TMP/state-alias"'"}' \
    | HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
      bash "$PLUGIN/hooks/session-start-session-control.sh" >/dev/null 2>"$TMP/state-alias.err"
  ALIAS_RC=$?
  if [ "$ALIAS_RC" -ne 0 ] \
    && grep -qF 'session-control-v1: workflow root is not canonical' "$TMP/state-alias.err" \
    && [ -z "$(ls -A "$TMP/state-alias/.ZENSU")" ]; then
    check "SessionStart fails closed on a case-alias workflow root and writes no workflow state" PASS
  else
    check "SessionStart fails closed on a case-alias workflow root and writes no workflow state" FAIL
  fi
  assert_state_denied "the capability gate denies a session whose workflow root is a case alias" \
    alias "workflow root is not canonical"
else
  printf '  SKIP  case-alias workflow root (this volume is case-sensitive)\n'
fi

mkdir -p "$TMP/state-control"
rm -f "$TMP/probe-control.jsonl"
ZENSU_PROBE_ROOTS="$TMP/state-control" ZENSU_PROBE_REPORT="$TMP/probe-control.jsonl" NODE_OPTIONS="--require \"$PROBE\"" \
  node -e 'const fs = require("node:fs"); fs.existsSync(`${process.argv[1]}/.zensu`); fs.mkdirSync(`${process.argv[1]}/.zensu`);' \
  "$TMP/state-control"
if ! probe_verdict control \
  && grep -qF 'outside the core reader: existsSync(' "$TMP/probe-control.verdict" \
  && grep -qF 'creates or changes: mkdirSync(' "$TMP/probe-control.verdict"; then
  check "the probe flags a workflow-state access outside the core reader and a creating call" PASS
else
  check "the probe flags a workflow-state access outside the core reader and a creating call ($(probe_failure control))" FAIL
fi

INTACT_BEFORE="$(zensu_digest "$TMP/state-intact")"
INTACT_OUT="$(probe_gate intact)"
if [ -z "$INTACT_OUT" ] \
  && probe_verdict intact --opened "$STATE_INTACT" --within readWorkflowState \
  && [ "$(zensu_digest "$TMP/state-intact")" = "$INTACT_BEFORE" ]; then
  check "the gate reads an intact workflow state only inside the core reader and creates nothing" PASS
else
  check "the gate reads an intact workflow state only inside the core reader and creates nothing ($(probe_failure intact))" FAIL
fi

ROOT_OUT="$(probe_gate root)"
if printf '%s' "$ROOT_OUT" | grep -qF 'session-control-v1: workflow root is missing.' \
  && probe_verdict root --within readWorkflowState \
  && [ ! -e "$TMP/state-root/.zensu" ]; then
  check "the gate denies a removed workflow root from inside the core reader and creates none" PASS
else
  check "the gate denies a removed workflow root from inside the core reader and creates none ($(probe_failure root))" FAIL
fi

REBIND_CACHE="$TMP/rebind-cache/zensu"
for version in 0.6.0 0.6.1; do
  mkdir -p "$REBIND_CACHE/$version"
  cp -R "$PLUGIN/.codex-plugin" "$PLUGIN/hooks" "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/docs" "$REBIND_CACHE/$version/"
  MANIFEST="$REBIND_CACHE/$version/.codex-plugin/plugin.json" VERSION="$version" node -e '
    const fs = require("node:fs");
    const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf8"));
    manifest.version = process.env.VERSION;
    fs.writeFileSync(process.env.MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
  '
done
REBIND_OLD="$(cd "$REBIND_CACHE/0.6.0" && pwd -P)"
REBIND_NEW="$(cd "$REBIND_CACHE/0.6.1" && pwd -P)"
REBIND_STATE="$(state_session rebind "$REBIND_OLD")"
REBIND_BEFORE="$(zensu_digest "$TMP/state-rebind")"
REBIND_OUT="$(probe_gate rebind "$REBIND_NEW")"
if [ -z "$REBIND_OUT" ] \
  && [ "$(record_plugin_root rebind)" = "$REBIND_NEW" ] \
  && probe_verdict rebind --opened "$REBIND_STATE" --within inspectWorkflowState \
  && [ "$(zensu_digest "$TMP/state-rebind")" = "$REBIND_BEFORE" ]; then
  check "a gate call that re-binds the session to a newer installation reads the workflow state only inside the core reader" PASS
else
  check "a gate call that re-binds the session to a newer installation reads the workflow state only inside the core reader ($(probe_failure rebind))" FAIL
fi

REANCHOR_HOOKS="$TMP/no-git-hooks"
REANCHOR_TARGET="$TMP/reanchor-target"
mkdir -p "$REANCHOR_HOOKS" "$TMP/state-reanchor"
reanchor_git() {
  git -c user.name=zensu-test -c user.email=zensu-test@example.invalid -c commit.gpgsign=false \
    -c init.defaultBranch=main -c core.hooksPath="$REANCHOR_HOOKS" "$@" >/dev/null 2>&1
}
reanchor_git -C "$TMP/state-reanchor" init -q
reanchor_git -C "$TMP/state-reanchor" commit -q --allow-empty --no-verify -m init
reanchor_git -C "$TMP/state-reanchor" worktree add -q -b reanchor-target "$REANCHOR_TARGET"
state_session reanchor >/dev/null
mkdir -p "$REANCHOR_TARGET/.zensu"
printf 'not a directory\n' > "$REANCHOR_TARGET/.zensu/state"
REANCHOR_RECORD="$RECORDS/$(node "$SESSION_CORE" session-key state-reanchor).json"
cp "$REANCHOR_RECORD" "$TMP/reanchor-record-before.json"
REANCHOR_BEFORE="$(zensu_digest "$TMP/state-reanchor")$(zensu_digest "$REANCHOR_TARGET")"
rm -f "$TMP/probe-reanchor.jsonl"
REANCHOR_OUT="$(PAYLOAD_CWD="$(cd "$REANCHOR_TARGET" && pwd -P)" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "UserPromptSubmit",
    session_id: "state-reanchor",
    cwd: process.env.PAYLOAD_CWD,
    prompt: "zensu reanchor"
  }));
' | HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN" ZENSU_PROBE_ROOTS="$TMP/state-reanchor:$REANCHOR_TARGET" \
  ZENSU_PROBE_REPORT="$TMP/probe-reanchor.jsonl" NODE_OPTIONS="--require \"$PROBE\"" \
  bash "$PLUGIN/hooks/user-prompt-session-control.sh" 2>/dev/null)"
if printf '%s' "$REANCHOR_OUT" \
    | grep -qF 'did not re-anchor this chat: a workflow state of this chat under the new worktree is unsafe or unreadable' \
  && probe_verdict reanchor --only /state-reanchor/.zensu --within inspectWorkflowState \
  && probe_verdict reanchor --only /reanchor-target/.zensu --within inspectWorkflowState \
  && cmp -s "$REANCHOR_RECORD" "$TMP/reanchor-record-before.json" \
  && [ "$(zensu_digest "$TMP/state-reanchor")$(zensu_digest "$REANCHOR_TARGET")" = "$REANCHOR_BEFORE" ]; then
  check "a re-anchor refused for an unusable target state reads both workflow states only inside the core reader and creates nothing" PASS
else
  check "a re-anchor refused for an unusable target state reads both workflow states only inside the core reader and creates nothing ($(probe_failure reanchor))" FAIL
fi

printf '%s\n' "----" "test-reviewer-capability-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
