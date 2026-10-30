#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec node "$ROOT/hooks/lib/ai-work-capture-v1.js" hook
