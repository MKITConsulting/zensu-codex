#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 2
case "${1:-}" in
  --on|--off|--status) ;;
  *)
    echo "usage: zensu-zen-mode.sh --on | --off | --status" >&2
    exit 2
    ;;
esac
command -v node >/dev/null 2>&1 || { echo "zensu-zen-mode.sh: node is not on PATH" >&2; exit 2; }
source "$ROOT/hooks/lib/zensu-session.sh"
if ! PROJECT="$(zensu_resolve_project_dir)"; then
  echo "zensu-zen-mode.sh: Session Control context unavailable ($(zensu_resolve_cause "${ZENSU_SESSION_KEY:-}")); export the exact injected ZENSU_SESSION_KEY in the same shell command" >&2
  exit 2
fi
export CLAUDE_PROJECT_DIR="$PROJECT"
source "$ROOT/hooks/lib/zensu-config.sh"
read -r ENABLED DEFAULT _ <<< "$(zensu_zen_mode_flags)"
exec node "$ROOT/hooks/lib/zen-mode-v1.js" "$1" --default "$DEFAULT" --enabled "$ENABLED"
