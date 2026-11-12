#!/bin/bash
# Synchronous, presentation-only refresh; never replaces the tool result.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 0
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" != "$ROOT" ]; then
  exit 0
fi
export CLAUDE_PLUGIN_ROOT="$ROOT"
command -v node >/dev/null 2>&1 || exit 0
INPUT="$(cat)"
PROJECT="$(printf '%s' "$INPUT" | node -e 'try{const p=JSON.parse(require("fs").readFileSync(0,"utf8"));if(typeof p.cwd==="string")process.stdout.write(p.cwd)}catch{}' 2>/dev/null)"
if [ -n "$PROJECT" ] && [ -d "$PROJECT" ]; then
  export CLAUDE_PROJECT_DIR="$PROJECT"
fi
source "$ROOT/hooks/lib/zensu-config.sh"
read -r ENABLED DEFAULT SELF_REVIEW <<< "$(zensu_zen_mode_flags)"
printf '%s' "$INPUT" | node "$ROOT/hooks/lib/zen-mode-v1.js" --post-tool --enabled "$ENABLED" --default "$DEFAULT" --self-review "$SELF_REVIEW"
# A presentation failure must never become Codex's exit-2 blocking decision.
exit 0
