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
#
# While a session is active, edits to the session-state files (.zensu/state/)
# are denied in BOTH modes (normalized-path classification, no spelling evasion).
# In vanilla mode (hooks.tddImplementation=false frozen at --tdd-begin into the
# state file's `vanilla` flag) the phase matrix is bypassed entirely — the gate
# reads only the state flag, never live config.
set -u

CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

PAYLOAD="$(cat)"

if ! command -v node >/dev/null 2>&1; then
  exit 0
fi

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$PAYLOAD" 2>/dev/null || true

# Extract tool name, session id, and the list of edited file paths in one pass.
# - Edit/Write/MultiEdit: tool_input.file_path
# - apply_patch (freeform) — or, as a fallback, any payload that yielded no
#   file_path: scan every string in tool_input for the patch envelope and pull
#   each `*** Update/Add/Delete File:` (+ `*** Move to:`) path. Payloads WITH a
#   file_path skip the scan so file CONTENT embedding envelope examples cannot
#   inject phantom paths.
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
    if (toolName === "apply_patch" || files.length === 0) {
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
    }
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
RAW_SESSION_ID="$SESSION_ID"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
unset ZENSU_SESSION_KEY
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"
export ZENSU_SESSION_KEY="$SESSION_ID"

# The edited paths are everything after line 2.
FILES="$(printf '%s' "$EXTRACT" | sed -n '3,$p')"

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"

STATE_FILE=$(tdd_state_file "$SESSION_ID") || STATE_FILE="(unresolved Session Control project state)"

# An existing state file that cannot be parsed as an object is not an inactive
# session. Treating corruption as `active=false` would silently disable both
# the TDD gate and its chain guarantees. Missing state remains the only
# pass-through case; invalid/unreadable state blocks until a fresh session is
# started (or the explicit ZENSU_TDD_GATE=off escape is deliberately used).
deny_invalid_state() {
  PAYLOAD_STATE_FILE="$STATE_FILE" PAYLOAD_CAUSE="${1:-the session-state file is not a valid workflow document}" PAYLOAD_HINT="${2:-}" node -e '
    const file = process.env.PAYLOAD_STATE_FILE || "(unknown)";
    const cause = process.env.PAYLOAD_CAUSE || "(unknown)";
    const remedy = process.env.PAYLOAD_HINT
      ? " " + process.env.PAYLOAD_HINT + " Use ZENSU_TDD_GATE=off only as an explicit, reviewed recovery escape."
      : " Start a fresh Codex session so Session Control v1 creates new state; use ZENSU_TDD_GATE=off only as an explicit, reviewed recovery escape.";
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          "TDD-Phase-Gate: edit blocked because the workflow state of this session cannot be trusted (" + file + "; cause: " + cause + "). It cannot be trusted as inactive or UNINITIALIZED." + remedy
      }
    }));
  '
  echo
  exit 0
}

REMEDY_HINT=''
if [ "$STATE_FILE" = "(unresolved Session Control project state)" ]; then
  REMEDY_HINT="$(printf '%s' "$PAYLOAD" | node "$CLAUDE_PLUGIN_ROOT/hooks/lib/codex-session-adopt-v1.js" --quiet 2>/dev/null)"
  STATE_FILE=$(tdd_state_file "$SESSION_ID") || STATE_FILE="(unresolved Session Control project state)"
fi

if [ "$STATE_FILE" = "(unresolved Session Control project state)" ]; then
  [ -n "$REMEDY_HINT" ] || REMEDY_HINT="$(node "$CLAUDE_PLUGIN_ROOT/hooks/lib/codex-retrust-hint-v1.js" 2>/dev/null)"
  deny_invalid_state "$(zensu_resolve_cause "$RAW_SESSION_ID")" "$REMEDY_HINT"
fi

# Activation: SessionStart must have created the mandatory baseline for THIS
# session. The phase matrix enforces only while `active=true`; a valid inactive
# baseline passes through, while a missing/deleted baseline fails closed.
STATE_STATUS="$(tdd_state_status "$STATE_FILE")"
if [ "$STATE_STATUS" = "missing" ]; then
  deny_invalid_state "the session-state file is missing"
fi
[ "$STATE_STATUS" = "invalid" ] && deny_invalid_state
ACTIVE_STATE="$(tdd_session_active "$STATE_FILE")"
[ "$ACTIVE_STATE" = "invalid" ] && deny_invalid_state
if [ "$ACTIVE_STATE" != "true" ]; then
  exit 0
fi

if [ -z "$FILES" ]; then
  # No file could be determined (e.g. an apply_patch envelope we could not parse).
  # Cannot reason about the path rules safely, so do not block.
  exit 0
fi

# Path classification on the NORMALIZED form (dot-segments, duplicate slashes,
# case folding, traversal, leaf symlinks — including dangling ones — hard-link
# aliases by inode all collapse to the same class) so the state deny below
# cannot be evaded by an alternate spelling
# that the broader .zensu/ exemption would then allow. ONE node pass classifies
# EVERY file the patch touches and echoes self-describing `class<TAB>path`
# pairs, so the shell loops below never depend on positional alignment.
CLASSES="$(printf '%s' "$FILES" | SD="$(dirname "$STATE_FILE")" node -e '
  const path = require("path");
  const fs = require("fs");
  const lownorm = p => path.posix.normalize(String(p).replace(/\\/g, "/")).toLowerCase();
  const realdir = p => { try { return fs.realpathSync(p); } catch (_) { return path.resolve(p); } };
  const realfile = p => {
    try { return fs.realpathSync(p); }
    catch (_) { return path.join(realdir(path.dirname(p)), path.basename(p)); }
  };
  const SD = process.env.SD || "";
  let stateInodes = null;
  const sharesStateInode = st => {
    if (!st || !st.isFile() || st.nlink <= 1) return false;
    if (stateInodes === null) {
      stateInodes = {};
      try {
        fs.readdirSync(SD).forEach(n => {
          try { const t = fs.statSync(path.join(SD, n)); stateInodes[t.dev + ":" + t.ino] = 1; } catch (_) {}
        });
      } catch (_) {}
    }
    return stateInodes[st.dev + ":" + st.ino] === 1;
  };
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    const sAbs = lownorm(realdir(path.resolve(SD))) + "/";
    const out = s.split("\n").filter(Boolean).map(fpRaw => {
      const f = lownorm(fpRaw);
      const abs = path.resolve(fpRaw);
      let st = null;
      try { st = fs.lstatSync(abs); } catch (_) {}
      let leaf = abs;
      let depth = 0;
      while (depth++ < 32) {
        let ls = null;
        try { ls = fs.lstatSync(leaf); } catch (_) {}
        if (!ls || !ls.isSymbolicLink()) break;
        try { leaf = path.resolve(path.dirname(leaf), fs.readlinkSync(leaf)); } catch (_) { break; }
      }
      const fAbs = lownorm(realfile(leaf));
      let cls;
      if (f.indexOf("/.zensu/state/") >= 0 || f.indexOf(".zensu/state/") === 0 || fAbs.indexOf(sAbs) === 0 || sharesStateInode(st)) cls = "state";
      else if (f.indexOf("/.zensu/") >= 0 || f.indexOf(".zensu/") === 0) cls = "zensu";
      else cls = "other";
      return cls + "\t" + fpRaw;
    });
    process.stdout.write(out.join("\n"));
  });
' 2>/dev/null)"

# Classifier integrity check: the node pass must yield exactly one pair per
# file. On a mid-flight node failure (CLASSES empty or truncated) do NOT run
# the phase matrix half-evaluated — fall back to a conservative TEXTUAL pass:
# deny state spellings, exempt other .zensu/ spellings, and otherwise fail
# open exactly like the documented node-missing pass-through above.
TAB="$(printf '\t')"
FILES_COUNT="$(printf '%s\n' "$FILES" | grep -c .)"
CLASSES_COUNT="$(printf '%s\n' "$CLASSES" | grep -c .)"
if [ "$CLASSES_COUNT" -ne "$FILES_COUNT" ]; then
  SD_LOWER="$(printf '%s' "$(dirname "$STATE_FILE")" | tr '[:upper:]' '[:lower:]' | tr '\\' '/' | sed -e 's#//*#/#g' -e ':a' -e 's#/\./#/#g' -e 'ta')"
  STATE_HIT=""
  while IFS= read -r FILE_PATH; do
    [ -z "$FILE_PATH" ] && continue
    FP_LOWER="$(printf '%s' "$FILE_PATH" | tr '[:upper:]' '[:lower:]' | tr '\\' '/' | sed -e 's#//*#/#g' -e ':a' -e 's#/\./#/#g' -e 'ta')"
    case "$FP_LOWER" in
      */.zensu/state/*|.zensu/state/*|"$SD_LOWER"/*) STATE_HIT="$FILE_PATH"; break ;;
    esac
  done <<EOF
$FILES
EOF
  if [ -n "$STATE_HIT" ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"TDD-Phase-Gate: edit blocked — a session-state path (.zensu/state/) was detected while the path classifier was unavailable; state flags change only through zensu-log.sh (e.g. --tdd-begin, --tdd-reset, --phase)."}}'
    exit 0
  fi
  exit 0
fi

# Session-state hardening: while a session is active, edits on the session-state
# files are denied in BOTH modes — flipping `vanilla`/`active` there would
# silently un-gate the session. Legitimate state writes go through zensu-log.sh
# via the shell tool, which this hook never sees. Checked BEFORE the vanilla
# bypass and the .zensu/ exemption on purpose; ANY state-classed file denies the
# whole patch.
STATE_HIT=""
while IFS="$TAB" read -r CLASS FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue
  if [ "$CLASS" = "state" ]; then
    STATE_HIT="$FILE_PATH"
    break
  fi
done <<EOF
$CLASSES
EOF

if [ -n "$STATE_HIT" ]; then
  PAYLOAD_FILE="$STATE_HIT" PAYLOAD_TOOL="$TOOL_NAME" node -e '
    const logCommand = "PLUGIN_ROOT=\"$(node \"$HOME/.zensu/session-control/codex/v3/resolve-v3.js\" --field plugin_root)\" && bash \"$PLUGIN_ROOT/hooks/lib/zensu-log.sh\"";
    const file = process.env.PAYLOAD_FILE || "(unknown)";
    const tool = process.env.PAYLOAD_TOOL || "apply_patch";
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          "TDD-Phase-Gate: " + tool + " on " + file + " blocked — direct edits to the session-state files (.zensu/state/) are denied while a session is active; state flags change only through " + logCommand + " (e.g. --tdd-begin, --tdd-reset, --phase)."
      }
    }));
  '
  echo
  exit 0
fi

# Vanilla implementation mode: the per-session `vanilla` flag was frozen into
# the state file by `--tdd-begin` (hooks.tddImplementation=false at begin time).
# The gate reads ONLY the state flag — never live config — so a mid-session
# config flip can neither un-gate a strict session nor wedge a vanilla one.
VANILLA_STATE="$(tdd_vanilla_mode "$STATE_FILE")"
[ "$VANILLA_STATE" = "invalid" ] && deny_invalid_state
if [ "$VANILLA_STATE" = "true" ]; then
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

# Evaluate every touched file. Files classed `zensu` (plan/log artifacts) are
# exempt; `state` was already denied above. Deny the whole patch if ANY file
# fails its phase rule (name the first such file).
DENIED_FILE=""
while IFS="$TAB" read -r CLASS FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue
  [ "$CLASS" = "zensu" ] && continue
  IS_TEST_PATH=$(tdd_is_test_path "$FILE_PATH")
  if ! decide_allow_file "$IS_TEST_PATH"; then
    DENIED_FILE="$FILE_PATH"
    break
  fi
done <<EOF
$CLASSES
EOF

if [ -z "$DENIED_FILE" ]; then
  exit 0
fi

PAYLOAD_PHASE="$PHASE" PAYLOAD_STEP="$STEP" PAYLOAD_FILE="$DENIED_FILE" PAYLOAD_TOOL="$TOOL_NAME" node -e '
  const phase = process.env.PAYLOAD_PHASE || "UNINITIALIZED";
  const step  = process.env.PAYLOAD_STEP || "(none)";
  const file  = process.env.PAYLOAD_FILE || "(unknown)";
  const tool  = process.env.PAYLOAD_TOOL || "apply_patch";
  const logCommand = "PLUGIN_ROOT=\"$(node \"$HOME/.zensu/session-control/codex/v3/resolve-v3.js\" --field plugin_root)\" && bash \"$PLUGIN_ROOT/hooks/lib/zensu-log.sh\"";
  const header =
    "TDD-Phase-Gate: " + tool + " on " + file + " blocked.\n" +
    "Current phase: " + phase + ", step: " + step + ".\n" +
    "Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step " + step + ") | (GREEN_PASS only on test paths).\n";
  const reason = header +
    "Action:\n" +
    "  1. New test file: " + logCommand + " --phase RED_WRITE --step <id>\n" +
    "  2. IMPL: first run the test, set RED_FAIL:\n" +
    "     " + logCommand + " --phase RED_RUN --step <id>\n" +
    "     (run the test command)\n" +
    "     " + logCommand + " --phase RED_FAIL --step <id> --reason \"...\"\n" +
    "     " + logCommand + " --phase IMPL --step <id>\n" +
    "  3. Refactor: " + logCommand + " --phase REFACTOR --step <id>\n" +
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
