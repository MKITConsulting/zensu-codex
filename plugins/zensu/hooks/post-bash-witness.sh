#!/bin/bash
# PostToolUse hook — the test-run witness. Records every shell command run while
# a TDD session is active to .zensu/logs/witness-<sid>.log, as an independent
# anti-hallucination evidence channel the $zensu-tdd Phase 6 audit cross-checks
# against claimed test runs. Wired to the host's shell tools (Codex `shell`,
# `exec_command`, `exec`; Claude Code `Bash`).
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"

# Drain stdin BEFORE any early exit — exiting with an undrained pipe can EPIPE
# the host's payload write once tool_response exceeds the pipe buffer (the gate
# mirrors this ordering).
INPUT="$(cat)"

if [ "${ZENSU_TEST_WITNESS:-}" = "off" ]; then exit 0; fi

if ! command -v node >/dev/null 2>&1; then exit 0; fi

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$INPUT" 2>/dev/null || true

TMP_FIELDS="$(mktemp 2>/dev/null)" || exit 0
printf '%s' "$INPUT" | ZENSU_EXTRACT_LIB="$CLAUDE_PLUGIN_ROOT/hooks/lib/shell-command-extract.js" node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      // Command extraction is shared with the source-write gate parser so the
      // two hooks can never drift apart on tool shapes.
      const { extractShellCommand } = require(process.env.ZENSU_EXTRACT_LIB);
      const cmd = extractShellCommand(j.tool_input);
      // Response: tolerate the different shapes Codex / Claude use. The
      // "Exit code: N … Output: …" string envelope is trusted ONLY for the
      // tools known to emit it — a raw stdout that merely starts with
      // "Exit code:" must not spoof the recorded exit.
      const resp = j.tool_response || j.tool_output || j.output || {};
      const pick = (o, k) => (o && typeof o[k] !== "undefined") ? o[k] : undefined;
      const toolName = (typeof j.tool_name === "string") ? j.tool_name : "";
      const envelopeTool = (toolName === "exec_command" || toolName === "exec");
      const respStr = (typeof resp === "string") ? resp : "";
      let exit = pick(resp, "exit_code");
      if (typeof exit !== "number") exit = pick(resp, "exitCode");
      if (typeof exit !== "number") exit = pick(j, "exit_code");
      if (typeof exit !== "number" && envelopeTool && respStr) {
        const m = respStr.match(/^Exit code:\s*(-?\d+)/);
        if (m) exit = Number(m[1]);
      }
      exit = (typeof exit === "number") ? String(exit) : "?";
      let stdout = pick(resp, "stdout");
      if (typeof stdout !== "string") stdout = pick(resp, "output");
      if (typeof stdout !== "string") {
        const oi = envelopeTool ? respStr.indexOf("\nOutput:\n") : -1;
        stdout = (oi >= 0) ? respStr.slice(oi + 9) : respStr;
      }
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
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`). When the
# exact resolved id has no active state, heal ONLY the diagnosed headless id
# divergence: --tdd-begin armed under a fallback_<key> id while this hook
# resolves the payload thread UUID. Adoption requires (a) EXACTLY ONE active
# tdd-phase-*.json (tdd_find_single_active_session — zero or multiple stay
# exact-match-only, concurrent-session safety) and (b) that sole id being
# fallback_*-shaped — a session armed under a real thread UUID never absorbs
# foreign sessions' commands, and a planted non-fallback state file cannot turn
# the witness into a passive logger. A git-TRACKED sole-active state is also
# refused: a legitimately-armed session writes its state at runtime (untracked),
# so a tracked active state can only be a committed plant shipped by a hostile
# repo — refusing it closes the clone-and-passively-log vector. Adopted lines
# carry origin=<resolved id> so the Phase 6 audit can tell adopted evidence from
# exact-match evidence (subagent threads spawned by the review chain surface
# here as distinct origins, never as unmarked main-thread lines).
#
# Healing is witness-only by design: the edit gate (pre-edit-tdd-reminder.sh)
# and the Stop enforcer stay exact-match — enforcement must NEVER activate on an
# inferred identity, so do not port adoption into those hooks.
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
ORIGIN=""
if [ "$(tdd_session_active "$(tdd_state_file "$SANITIZED_SESSION")")" != "true" ]; then
  ADOPTED="$(tdd_find_single_active_session)"
  case "$ADOPTED" in
    fallback_*) ;;
    *) exit 0 ;;
  esac
  ADOPTED_STATE="$(tdd_state_file "$ADOPTED")"
  if command -v git >/dev/null 2>&1 && \
     git -C "$(dirname "$ADOPTED_STATE")" ls-files --error-unmatch -- "$ADOPTED_STATE" >/dev/null 2>&1; then
    exit 0
  fi
  ORIGIN="$SANITIZED_SESSION"
  SANITIZED_SESSION="$ADOPTED"
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
WITNESS_DIR="$PROJECT_DIR/.zensu/logs"
WITNESS_LOG="$WITNESS_DIR/witness-${SANITIZED_SESSION}.log"
# With adoption the log filename derives from on-disk state (attacker-influenceable
# in a hostile repo); refuse to follow a symlink at ANY component of the log path
# (`.zensu`, `.zensu/logs`, or the log file itself — git preserves symlinks on
# clone) so a `>>` append can never land on a target outside the project's real
# .zensu/logs.
[ -L "$PROJECT_DIR/.zensu" ] && exit 0
[ -L "$WITNESS_DIR" ] && exit 0
mkdir -p "$WITNESS_DIR" 2>/dev/null || exit 0
[ -L "$WITNESS_LOG" ] && exit 0

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-config.sh"
TS_PREFIX=""
if [ "$(_zensu_log_style)" != "none" ]; then
  TS_PREFIX="[$(date +%H:%M:%S)] "
fi
if [ -n "$ORIGIN" ]; then
  printf '%sBASH cmd=%s exit=%s tail=%s interrupted=%s origin=%s\n' "$TS_PREFIX" "$CMD_JSON" "$EXIT_CODE" "$TAIL_JSON" "$INTERRUPTED" "$ORIGIN" >> "$WITNESS_LOG" 2>/dev/null || true
else
  printf '%sBASH cmd=%s exit=%s tail=%s interrupted=%s\n' "$TS_PREFIX" "$CMD_JSON" "$EXIT_CODE" "$TAIL_JSON" "$INTERRUPTED" >> "$WITNESS_LOG" 2>/dev/null || true
fi

exit 0
