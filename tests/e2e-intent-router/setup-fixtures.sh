#!/bin/bash
# Minimal clean-git fixture for the intent-router live layer. Idempotent.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
FX="$DIR/test-projects/host"
rm -rf "$FX"; mkdir -p "$FX"
(
  cd "$FX" && git init -q && git config user.email t@t && git config user.name t \
    && printf '# host\n' > README.md && git add README.md && git commit -qm init
) >/dev/null 2>&1 || true
echo "fixture: $FX"
