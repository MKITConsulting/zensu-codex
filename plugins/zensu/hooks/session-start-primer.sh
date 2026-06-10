#!/bin/bash
# SessionStart hook — model-facing orientation. Injects a short primer via
# hookSpecificOutput.additionalContext so the agent proactively follows Zensu
# conventions (plan -> ask about $zensu-tdd). Fires only on fresh starts
# (source=startup/clear); silent on resume/compact. Gated by hooks.sessionBanner
# (same flag as the user banner).
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled sessionBanner || exit 0
command -v node >/dev/null 2>&1 || exit 0

SOURCE="$(node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ try { const j=JSON.parse(s||"{}");
    process.stdout.write(typeof j.source==="string"?j.source:""); } catch(_){ process.stdout.write(""); } });
' 2>/dev/null)"
case "$SOURCE" in
  resume|compact) exit 0 ;;
esac

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Zensu PLM plugin is active. Convention: for any task that adds or modifies executable code, plan the change first; before you start implementing, ASK the user whether to run the strict TDD flow via the $zensu-tdd skill. On yes, run strict RED→GREEN TDD in the main thread — FIRST arm the phase-gate via bash $(cat ~/.zensu/plugin-root)/hooks/lib/zensu-log.sh --tdd-begin, then declare every phase BEFORE acting via --phase <RED_WRITE|RED_RUN|RED_FAIL|IMPL|GREEN_RUN|GREEN_PASS> --step <id> (the --step id is required on every marker; the gate matches IMPL against RED_FAIL per step and DENIES production edits without it), and the review chain (spawn the zensu-code-reviewer subagent, or fan out five zensu-review-aspect subagents) must run to completion. On no, implement directly. Fast-paths that skip the question: doc-only changes, an explicit TDD preference already stated by the user, or a non-interactive run. Feature planning and tracking run via the zensu-plm agent and the $zensu-bootstrap or $zensu-ghost-scan skills. Use $zensu-help to answer questions about Zensu. This is a one-time per-session orientation."
  }
}
JSON
exit 0
