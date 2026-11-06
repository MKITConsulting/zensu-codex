#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 0
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" != "$ROOT" ]; then
  exit 0
fi
export CLAUDE_PLUGIN_ROOT="$ROOT"
command -v node >/dev/null 2>&1 || exit 0
INPUT="$(cat)"
PROJECT="$(printf '%s' "$INPUT" | node -e 'try{const p=JSON.parse(require("fs").readFileSync(0,"utf8"));if(typeof p.cwd==="string")process.stdout.write(p.cwd)}catch{}' 2>/dev/null)"
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || exit 0
export CLAUDE_PROJECT_DIR="$PROJECT"
source "$ROOT/hooks/lib/zensu-config.sh"
zensu_hook_enabled contextAutoLoad || exit 0
[ -n "$(printf '%s' "$INPUT" | node "$ROOT/hooks/lib/codex-task-prompt-v1.js" 2>/dev/null)" ] || exit 0
printf '%s' "$INPUT" | node "$ROOT/hooks/lib/context-auto-load-v1.js" codex UserPromptSubmit
