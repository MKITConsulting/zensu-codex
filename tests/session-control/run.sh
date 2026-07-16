#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -d "$ROOT/plugins/zensu" ]; then
  CORE="$ROOT/plugins/zensu/hooks/lib/session-control-core-v1.js"
else
  CORE="$ROOT/hooks/lib/session-control-core-v1.js"
fi
SESSION_CONTROL_CORE="$CORE" node --test "$ROOT/tests/session-control/session-control-core-v1.test.js"
