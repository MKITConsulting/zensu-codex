#!/bin/bash
# evals/config-gate/run-eval.sh — offline, deterministic config-gate tests for
# plugins/zensu/hooks/lib/zensu-config.sh. No API, no codex. `--self-check` is
# accepted as a no-op alias (these tests are already offline) so run-all.sh's
# tri-mode can call it uniformly.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
for t in "$DIR"/test-*.sh; do
  [ -f "$t" ] || continue
  if bash "$t"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
done
echo "----"
echo "config-gate: $PASS suites passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
