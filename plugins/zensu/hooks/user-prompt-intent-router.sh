#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled intentRouter || exit 0
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

printf '%s' "$PROMPT" | grep -qiE '(^|[^[:alnum:]])(zensu|product|feature|roadmap|milestone|bootstrap|ghost.?scan|journey|tier)(s|es|ing|ed)?([^[:alnum:]]|$)' || exit 0

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This prompt contains a product/planning keyword, so it MIGHT be a Zensu product-planning or product-tracking request — or it might just be ordinary work that mentions such a word. FIRST decide which. If it IS a genuine request to plan, track, bootstrap, scan, or manage features / roadmap / journeys / tiers in Zensu: your VERY NEXT action is to run the project-context triage — ASK the user these three questions directly and do NOT guess them: (1) is the code already built, or are you starting fresh? (2) is there a plan, vision, or spec document? (3) if both exist, does the plan describe items not yet built? Do NOT read files, do NOT launch search subagents, and do NOT try to 'ground' or understand the repo first before asking — the user answers these in seconds, and grounding-first is the same deferral trap as the 'no writes yet' excuse. Asking is READ-ONLY and is always allowed. Once the user answers, route per the zensu-plm Decision Rules — fresh code + plan doc -> bootstrap (greenfield); built code + no plan -> ghost-scan (brownfield); built code + plan with unbuilt items -> hybrid — and carry out the work through the zensu-plm agent rather than driving the zensu CLI directly. If instead this is an ordinary implementation, coding, UI, design, debugging, refactor, or content task that merely contains a word like 'product', 'feature', or 'tier' (for example 'add a modern hero section to my landing page', 'add a feature flag to checkout', 'optimize the cache tier latency'): IGNORE this notice entirely and answer the request normally — do NOT mention zensu-plm, do NOT run the triage. This is advisory steering, not a hard gate."
  }
}
JSON
exit 0
