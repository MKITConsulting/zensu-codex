#!/bin/bash

set -u

CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

zensu_hook_enabled pulseSession || exit 0

HEAD=$(git rev-parse HEAD 2>/dev/null) || { echo "zensu: not a git repository, pulse session skipped"; exit 0; }
BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && BRANCH="detached"
echo "zensu: pulse session ready — HEAD=$HEAD branch=$BRANCH"
