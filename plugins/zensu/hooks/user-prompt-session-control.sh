#!/bin/bash
set -euo pipefail
command -v node >/dev/null 2>&1 || exit 0
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec node "$ROOT/hooks/lib/codex-session-adopt-v1.js"
