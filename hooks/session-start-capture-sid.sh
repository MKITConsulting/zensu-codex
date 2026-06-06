#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"

if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
else
  exit 0
fi

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "$PAYLOAD" ] && exit 0

command -v node >/dev/null 2>&1 || exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$PAYLOAD" 2>/dev/null || true

SID="$(PAYLOAD="$PAYLOAD" node -e '
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    process.stdout.write((typeof j.session_id === "string" && j.session_id) ? j.session_id : "");
  } catch (_) {}
' 2>/dev/null)"

[ -z "$SID" ] && exit 0

CACHE_DIR="${CLAUDE_PROJECT_DIR:-.}/.zensu/state"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
KEY="$(zensu_session_key)"
TARGET="$CACHE_DIR/session-id-${KEY}.txt"
TMP="$(mktemp "$CACHE_DIR/session-id-${KEY}.XXXXXX" 2>/dev/null)" || exit 0
if printf '%s\n' "$SID" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$TARGET" 2>/dev/null || rm -f "$TMP" 2>/dev/null
else
  rm -f "$TMP" 2>/dev/null
fi
exit 0
