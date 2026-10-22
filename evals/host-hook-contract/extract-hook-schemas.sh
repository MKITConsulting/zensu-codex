#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo 'extract-hook-schemas: node is not on PATH' >&2; exit 2; }
exec node "$ROOT/schemas.js" "$@"
