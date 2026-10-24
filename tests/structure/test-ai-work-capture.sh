#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
node --test "$ROOT/tests/structure/ai-work-capture.test.js"
