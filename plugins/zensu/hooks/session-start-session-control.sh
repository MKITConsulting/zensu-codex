#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec node "$ROOT/hooks/lib/codex-session-control-v1.js"
