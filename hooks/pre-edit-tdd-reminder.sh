#!/bin/bash
# PreToolUse hook — the TDD phase-gate. Deterministically allows/denies file
# edits based on the per-session TDD FSM phase (RED_WRITE → RED_FAIL → IMPL →
# GREEN_PASS → REFACTOR) so production code cannot be written before a failing
# test exists. Emits the host's deny schema (hookSpecificOutput.permissionDecision
# = "deny") — identical on Codex and Claude Code.
#
# Engine portability: matches BOTH the Codex edit tool (`apply_patch`, a freeform
# tool whose patch envelope names target files on `*** Update/Add/Delete File:`
# lines — a single patch may touch several files, and the gate denies the whole
# patch if ANY touched file violates the current phase) AND the Claude Code edit
# tools (`Edit`/`Write`/`MultiEdit`, whose target is `tool_input.file_path`).
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"

PAYLOAD="$(cat)"

if ! command -v node >/dev/null 2>&1; then
  exit 0
fi

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$PAYLOAD" 2>/dev/null || true

# Extract tool name, session id, and the list of edited file paths in one pass.
# - Edit/Write/MultiEdit: tool_input.file_path
# - apply_patch (freeform): scan every string in tool_input for the patch
#   envelope and pull each `*** Update/Add/Delete File:` (+ `*** Move to:`) path.
EXTRACT="$(PAYLOAD_BODY="$PAYLOAD" node -e '
  try {
    const j = JSON.parse(process.env.PAYLOAD_BODY || "{}");
    const toolName = typeof j.tool_name === "string" ? j.tool_name : "";
    const sid = typeof j.session_id === "string" ? j.session_id : "";
    const ti = j.tool_input;
    const files = [];
    if (ti && typeof ti === "object" && typeof ti.file_path === "string" && ti.file_path) {
      files.push(ti.file_path);
    }
    const strs = [];
    (function walk(v){
      if (typeof v === "string") strs.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    })(ti);
    const patch = strs.find(s => s.indexOf("*** Begin Patch") !== -1) || strs.join("\n");
    let m;
    const reFile = /^\*\*\*\s+(?:Update|Add|Delete) File:\s+(.+?)\s*$/gm;
    while ((m = reFile.exec(patch)) !== null) files.push(m[1]);
    const reMove = /^\*\*\*\s+Move to:\s+(.+?)\s*$/gm;
    while ((m = reMove.exec(patch)) !== null) files.push(m[1]);
    const uniq = [...new Set(files.filter(Boolean))];
    process.stdout.write(toolName + "\n" + sid + "\n" + uniq.join("\n"));
  } catch (_) { process.stdout.write("\n\n"); }
' 2>/dev/null)"

TOOL_NAME="$(printf '%s' "$EXTRACT" | sed -n '1p')"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|apply_patch) ;;
  *) exit 0 ;;
esac

if [ "${ZENSU_TDD_GATE:-}" = "off" ]; then
  exit 0
fi

SESSION_ID="$(printf '%s' "$EXTRACT" | sed -n '2p')"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"

# The edited paths are everything after line 2.
FILES="$(printf '%s' "$EXTRACT" | sed -n '3,$p')"

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"

STATE_FILE=$(tdd_state_file "$SESSION_ID")

# Activation: the gate enforces only while a main-thread TDD session is active
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`). When no
# active chain-state exists the hook is a silent pass-through — normal editing,
# other subagents, and plain CLI are never gated.
if [ "$(tdd_session_active "$STATE_FILE")" != "true" ]; then
  exit 0
fi

PHASE=$(tdd_phase "$STATE_FILE")
STEP=$(tdd_step "$STATE_FILE")
RED_FAIL_FOR_STEP=$(tdd_has_red_fail "$STATE_FILE" "$STEP")

decide_allow_file() {
  local is_test="$1"
  case "$PHASE" in
    RED_WRITE) return 0 ;;
    RED_FAIL)
      [ "$is_test" = "true" ] && return 0
      return 1
      ;;
    IMPL)
      [ "$RED_FAIL_FOR_STEP" = "true" ] && return 0
      return 1
      ;;
    GREEN_PASS)
      [ "$is_test" = "true" ] && return 0
      return 1
      ;;
    REFACTOR) return 0 ;;
    UNINITIALIZED) return 1 ;;
    *) return 1 ;;
  esac
}

# Evaluate every touched file. .zensu/ and parent-relative paths are exempt.
# Deny the whole patch if ANY file fails its phase rule (name the first such file).
DENIED_FILE=""
if [ -z "$FILES" ]; then
  # No file could be determined (e.g. an apply_patch envelope we could not parse).
  # Cannot reason about the phase rule safely, so do not block.
  exit 0
fi
while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue
  case "$FILE_PATH" in
    *..*) ;;
    */.zensu/*|.zensu/*) continue ;;
  esac
  IS_TEST_PATH=$(tdd_is_test_path "$FILE_PATH")
  if ! decide_allow_file "$IS_TEST_PATH"; then
    DENIED_FILE="$FILE_PATH"
    break
  fi
done <<EOF
$FILES
EOF

if [ -z "$DENIED_FILE" ]; then
  exit 0
fi

PAYLOAD_PHASE="$PHASE" PAYLOAD_STEP="$STEP" PAYLOAD_FILE="$DENIED_FILE" PAYLOAD_TOOL="$TOOL_NAME" PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" node -e '
  const phase = process.env.PAYLOAD_PHASE || "UNINITIALIZED";
  const step  = process.env.PAYLOAD_STEP || "(none)";
  const file  = process.env.PAYLOAD_FILE || "(unknown)";
  const tool  = process.env.PAYLOAD_TOOL || "apply_patch";
  const root  = process.env.PLUGIN_ROOT || "";
  const header =
    "TDD-Phase-Gate: " + tool + " on " + file + " blocked.\n" +
    "Current phase: " + phase + ", step: " + step + ".\n" +
    "Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step " + step + ") | (GREEN_PASS only on test paths).\n";
  const reason = header +
    "Action:\n" +
    "  1. New test file: bash " + root + "/hooks/lib/zensu-log.sh --phase RED_WRITE --step <id>\n" +
    "  2. IMPL: first run the test, set RED_FAIL:\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase RED_RUN --step <id>\n" +
    "     (run the test command)\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase RED_FAIL --step <id> --reason \"...\"\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase IMPL --step <id>\n" +
    "  3. Refactor: bash " + root + "/hooks/lib/zensu-log.sh --phase REFACTOR --step <id>\n" +
    "  4. Legitimate non-TDD edit: set ZENSU_TDD_GATE=off";
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason
    }
  }));
'
echo

if [ -n "${ZENSU_HOOK_LOG:-}" ]; then
  {
    echo "[hook: PreToolUse] TDD-Phase-Gate: $TOOL_NAME on $DENIED_FILE blocked."
    echo "[hook: PreToolUse] Current phase: $PHASE, step: $STEP."
    echo "[hook: PreToolUse] Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step $STEP) | (GREEN_PASS only on test paths)."
    echo "[hook: PreToolUse] permissionDecision=deny"
  } >> "$ZENSU_HOOK_LOG" 2>/dev/null || true
fi

exit 0
