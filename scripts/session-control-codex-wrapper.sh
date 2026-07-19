#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec node "$ROOT/evals/session-control/lib/codex-live-provider.js" "$@"
