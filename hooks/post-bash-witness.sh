#!/bin/bash
# PostToolUse hook — the test-run witness. Records every shell command run while
# a TDD session is active to .zensu/logs/witness-<sid>.log, as an independent
# anti-hallucination evidence channel the $zensu-tdd Phase 6 audit cross-checks
# against claimed test runs. Wired to the host's shell tool (Codex `shell`,
# Claude Code `Bash`).
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"

if [ "${ZENSU_TEST_WITNESS:-}" = "off" ]; then exit 0; fi

if ! command -v node >/dev/null 2>&1; then exit 0; fi

INPUT="$(cat)"

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$INPUT" 2>/dev/null || true

TMP_FIELDS="$(mktemp 2>/dev/null)" || exit 0
printf '%s' "$INPUT" | node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const ti = j.tool_input || {};
      // Command: Codex shell passes an argv array (e.g. ["bash","-lc","..."]);
      // Claude Bash passes a string. Normalize both to one string.
      let cmd = "";
      if (typeof ti.command === "string") cmd = ti.command;
      else if (Array.isArray(ti.command)) cmd = ti.command.join(" ");
      else if (typeof ti.cmd === "string") cmd = ti.cmd;
      // Response: tolerate the different shapes Codex / Claude use.
      const resp = j.tool_response || j.tool_output || j.output || {};
      const pick = (o, k) => (o && typeof o[k] !== "undefined") ? o[k] : undefined;
      let exit = pick(resp, "exit_code");
      if (typeof exit !== "number") exit = pick(resp, "exitCode");
      if (typeof exit !== "number") exit = pick(j, "exit_code");
      exit = (typeof exit === "number") ? String(exit) : "?";
      let stdout = pick(resp, "stdout");
      if (typeof stdout !== "string") stdout = pick(resp, "output");
      if (typeof stdout !== "string") stdout = (typeof resp === "string") ? resp : "";
      const tail = String(stdout).slice(-200);
      const interrupted = (pick(resp, "interrupted") === true) ? "true" : "false";
      const session = (typeof j.session_id === "string" && j.session_id) ? j.session_id : "";
      process.stdout.write(JSON.stringify(cmd) + "\n" + exit + "\n" + JSON.stringify(tail) + "\n" + interrupted + "\n" + session + "\n");
    } catch (_) { process.stdout.write("\"\"\n?\n\"\"\nfalse\n\n"); }
  });
' > "$TMP_FIELDS" 2>/dev/null

{ read -r CMD_JSON; read -r EXIT_CODE; read -r TAIL_JSON; read -r INTERRUPTED; read -r SESSION; } < "$TMP_FIELDS"
rm -f "$TMP_FIELDS"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
SANITIZED_SESSION="$(zensu_resolve_session_id "$SESSION")"

# Activation: record witness lines only while a main-thread TDD session is active
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`).
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
if [ "$(tdd_session_active "$(tdd_state_file "$SANITIZED_SESSION")")" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
WITNESS_DIR="$PROJECT_DIR/.zensu/logs"
WITNESS_LOG="$WITNESS_DIR/witness-${SANITIZED_SESSION}.log"
mkdir -p "$WITNESS_DIR" 2>/dev/null || exit 0

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-config.sh"
TS_PREFIX=""
if [ "$(_zensu_log_style)" != "none" ]; then
  TS_PREFIX="[$(date +%H:%M:%S)] "
fi
printf '%sBASH cmd=%s exit=%s tail=%s interrupted=%s\n' "$TS_PREFIX" "$CMD_JSON" "$EXIT_CODE" "$TAIL_JSON" "$INTERRUPTED" >> "$WITNESS_LOG" 2>/dev/null || true

exit 0
