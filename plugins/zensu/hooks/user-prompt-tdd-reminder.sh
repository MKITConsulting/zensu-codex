#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled tddReminder || exit 0
command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$INPUT" 2>/dev/null || true

PROMPT="$(PAYLOAD="$INPUT" node -e '
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    process.stdout.write(typeof j.prompt === "string" ? j.prompt : "");
  } catch (_) { process.stdout.write(""); }
' 2>/dev/null)"

[ -n "$PROMPT" ] || exit 0

SESSION_ID="$(PAYLOAD="$INPUT" node -e '
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    process.stdout.write(typeof j.session_id === "string" ? j.session_id : "");
  } catch (_) { process.stdout.write(""); }
' 2>/dev/null)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
STATE_FILE="$(tdd_state_file "$SESSION_ID")"
[ "$(tdd_session_active "$STATE_FILE")" = "true" ] && exit 0

if zensu_hook_enabled tddImplementation; then
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Zensu TDD reminder. If THIS request will lead you to add or modify executable code (functions, classes, methods, types, conditionals, loops, exports/imports, JSX/TSX components, React hooks, styles that affect rendered output, or schema/config that drives runtime behavior), do NOT silently hand-implement: before your FIRST code edit determine whether to run the strict TDD flow, and unless a fast-path applies, ASK. (a) NOT a code change — a question, explanation, code review, doc/comment/prose edit, static-config-only edit with no runtime logic, debugging discussion, or a Zensu product-planning request (handled separately by the planning notice) — IGNORE this and answer the request normally. (b) A TDD session is already active for this session — IGNORE this; that flow already asks about TDD. (c) Otherwise — the request adds or modifies executable code and you stated no preference — your action BEFORE the first apply_patch/Edit/Write on a code file is to ASK the user inline a single question such as 'Run the strict TDD flow (RED→GREEN + review chain) for this?' with options 'Yes — TDD flow' and 'No — implement directly'. If the user chooses Yes → invoke the $zensu-tdd skill, passing this request as the feature specification, and begin that message with 'Executing via $zensu-tdd'. If the user chooses No → implement directly in the main thread (never run --tdd-begin, so the phase-gate stays inactive and edits flow freely) and begin that message with 'Skipping TDD: user declined'. Fast-paths that skip the question: the request already states an EXPLICIT TDD preference — an affirmation matching 'use tdd', 'with tdd', 'tdd please', 'mit tdd', 'tdd bitte' (run TDD without asking) or a negation matching 'no tdd', 'skip tdd', \"don't use tdd\", 'kein tdd', 'ohne tdd' (implement directly without asking); or you are running non-interactively in Auto Mode / headless with no human to answer (default to running TDD, do NOT ask). Generic action phrases ('go', 'go ahead', 'start now', 'implement', 'mach mal', 'los gehts', 'jetzt umsetzen') are NOT a TDD preference — ask anyway. If uncertain whether the request adds executable code, ask. This is advisory steering, not a hard gate."
  }
}
JSON
else
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Zensu workflow reminder (vanilla implementation mode configured via hooks.tddImplementation=false: the $zensu-tdd workflow implements WITHOUT the RED→GREEN ceremony but keeps the evidence discipline and the full review chain). If THIS request will lead you to add or modify executable code (functions, classes, methods, types, conditionals, loops, exports/imports, JSX/TSX components, React hooks, styles that affect rendered output, or schema/config that drives runtime behavior), do NOT silently hand-implement: before your FIRST code edit determine whether to run the Zensu workflow, and unless a fast-path applies, ASK. (a) NOT a code change — a question, explanation, code review, doc/comment/prose edit, static-config-only edit with no runtime logic, debugging discussion, or a Zensu product-planning request (handled separately by the planning notice) — IGNORE this and answer the request normally. (b) A TDD session is already active for this session — IGNORE this; that flow already asks. (c) Otherwise — the request adds or modifies executable code and you stated no preference — your action BEFORE the first apply_patch/Edit/Write on a code file is to ASK the user inline a single question such as 'Run the Zensu workflow (vanilla implementation + review chain) for this?' with options 'Yes — Zensu workflow' and 'No — implement directly'. If the user chooses Yes → invoke the $zensu-tdd skill, passing this request as the feature specification — the skill detects vanilla mode itself at --tdd-begin and implements directly (tests at your discretion) under the Phase 5/6 evidence discipline and the auto-review chain — and begin that message with 'Executing via $zensu-tdd (vanilla mode)'. If the user chooses No → implement directly in the main thread (never run --tdd-begin, so the phase-gate stays inactive and edits flow freely) and begin that message with 'Skipping TDD: user declined'. Fast-paths that skip the question: the request already states an EXPLICIT preference — an affirmation matching 'use tdd', 'with tdd', 'tdd please', 'mit tdd', 'tdd bitte' (run the workflow without asking) or a negation matching 'no tdd', 'skip tdd', \"don't use tdd\", 'kein tdd', 'ohne tdd' (implement directly without asking); or you are running non-interactively in Auto Mode / headless with no human to answer (default to running the workflow, do NOT ask). Generic action phrases ('go', 'go ahead', 'start now', 'implement', 'mach mal', 'los gehts', 'jetzt umsetzen') are NOT a preference — ask anyway. If uncertain whether the request adds executable code, ask. This is advisory steering, not a hard gate."
  }
}
JSON
fi
exit 0
