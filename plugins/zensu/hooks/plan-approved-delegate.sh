#!/bin/bash
# NOT WIRED ON CODEX. Codex CLI has no ExitPlanMode tool / plan-approval event,
# so this hook is not registered in hooks/hooks.json. Its behavior (ask whether
# to run the strict TDD flow before implementing code) lives in AGENTS.md and the
# session-start primer for the Codex port. Kept here for reference and Claude Code
# compatibility.
#
# PostToolUse hook fired when ExitPlanMode succeeds (= user approved plan).
# Returns JSON via stdout that Claude Code injects as additionalContext
# next to the tool result. By default (autoTdd enabled) the directive tells
# the main agent to ASK the user — via the AskUserQuestion tool — whether to
# run the strict /zensu:tdd flow for this plan, then act on the answer IN THE
# MAIN THREAD (no subagent): run /zensu:tdd on yes, implement directly on no.
# Fast-paths skip the question — doc-only plans, an explicit TDD preference
# already stated in the approval message, and non-interactive Auto Mode
# (which defaults to /zensu:tdd because there is no human to answer).
#
# This is a command-type hook (not prompt-type) so the directive reaches
# the main agent verbatim instead of being summarized by a judge LLM.

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled autoTdd || exit 0

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The plan above was just approved by the user. Do NOT implement anything yet — first determine whether to run the strict TDD flow for this plan, and in most cases ASK the user. Fast-paths that need NO question: (A) the plan only modifies non-executable text — Markdown docs (README, CHANGELOG, *.md), code comments, plain prose, or static config files with no runtime logic — proceed directly without TDD and begin your next message with 'Skipping TDD: docs only'. README/CHANGELOG edits are ALWAYS in this category, even when adding markers, sections, or restructuring. (B) the user's approval message already states an EXPLICIT TDD preference — either a negation matching 'no tdd', 'skip tdd', 'no tdd-manager', \"don't use tdd\", 'direct edit' (then skip TDD, implement directly, begin with 'Skipping TDD: user opted out'), or an affirmation matching 'use tdd', 'with tdd', 'tdd please' (then run TDD without asking). (C) you are running non-interactively with no human to answer (Auto Mode / headless) — default to running TDD and do NOT ask. In EVERY OTHER case — the plan adds or modifies executable code (functions, classes, methods, types, conditionals, loops, exports, imports, JSX/TSX components, React hooks, styles that affect rendered output, schema/config files that drive runtime behavior) and the user stated no preference — your VERY NEXT TOOL CALL must be the AskUserQuestion tool: ask a single question such as 'Run the strict TDD flow (RED→GREEN + review chain) for this plan?' with options 'Yes — TDD flow' and 'No — implement directly'. Do NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that AskUserQuestion call. Then act on the answer YOURSELF in THIS main thread (never a subagent): if the user chooses Yes (or fast-path B-affirmation, or fast-path C) → your next tool call is the Skill tool with skill='zensu:tdd', passing the approved plan content (the markdown that appeared in the ExitPlanMode tool_input) as the feature specification — you execute strict RED→IMPL→GREEN TDD under the PreToolUse phase-gate and the auto-review chain — and you begin that message with the status line 'Executing via /zensu:tdd'. If the user chooses No → implement the plan directly in this main thread; the TDD phase-gate stays inactive (never run --tdd-begin) so your edits flow freely; begin that message with 'Skipping TDD: user declined'. Generic action phrases ('go ahead', 'start now', 'implement', 'immediately', 'go') are NOT a TDD preference — ask anyway. If uncertain whether the plan adds executable code, ask."
  }
}
JSON
