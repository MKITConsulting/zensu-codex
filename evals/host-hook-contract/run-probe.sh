#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${CODEX_HOME:-}" ]; then
  echo 'run-probe: refusing to run with an inherited CODEX_HOME' >&2
  exit 2
fi
command -v node >/dev/null 2>&1 || { echo 'run-probe: node is not on PATH' >&2; exit 2; }
exec node "$ROOT/probe.js" "$@"
