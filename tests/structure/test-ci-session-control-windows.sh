#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ci.yml"
CODEX_SUITE="$ROOT/tests/structure/test-session-control-codex.sh"
CORE_SUITE="$ROOT/tests/session-control/session-control-core-v1.test.js"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

if [ ! -f "$WORKFLOW" ]; then
  check "CI workflow exists" FAIL
  printf '%s\n' "----" "test-ci-session-control-windows: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "CI workflow exists" PASS

JOB_BLOCK="$(awk '
  /^  session-control-windows:[[:space:]]*$/ {
    capture = 1
    start = NR
  }
  capture && NR > start && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
  capture { print }
' "$WORKFLOW")"

contains_once() {
  local label="$1"
  local expected="$2"
  local count
  count="$(printf '%s\n' "$JOB_BLOCK" | grep -F -c "$expected" || true)"
  if [ "$count" -eq 1 ]; then check "$label" PASS
  else check "$label" FAIL; fi
}

contains_once "dedicated Windows Session Control job is present" "session-control-windows:"
contains_once "job runs on windows-latest" "runs-on: windows-latest"
contains_once "job has a bounded timeout" "timeout-minutes: 20"
contains_once "job selects Git for Windows bash" "shell: bash"
contains_once "job provisions Node 20" "node-version: 20"
contains_once "job prints the effective Node runtime" "run: node --version"
contains_once "job executes the shared Core suite" "run: bash tests/session-control/run.sh"
contains_once "job executes the Codex Session Control and resolver v3 suite" \
  "run: bash tests/structure/test-session-control-codex.sh"

if printf '%s\n' "$JOB_BLOCK" | grep -Eq '^[[:space:]]+if:'; then
  check "Windows functional suites are unconditional" FAIL
else
  check "Windows functional suites are unconditional" PASS
fi

WINDOWS_BRANCHES="$(grep -F -c 'if [ "$IS_WINDOWS" -eq 1 ]; then' "$CODEX_SUITE" || true)"
if [ "$WINDOWS_BRANCHES" -eq 2 ] \
  && grep -qF 'POSIX 0600 mode assertion is skipped on Windows ACL filesystems' "$CODEX_SUITE" \
  && grep -qF 'runtime symlink assertion is skipped where Git Bash cannot guarantee symlink creation' "$CODEX_SUITE"; then
  check "Codex suite limits Windows branches to mode and symlink assertions" PASS
else
  check "Codex suite limits Windows branches to mode and symlink assertions" FAIL
fi

WINDOWS_CORE_SKIPS="$(grep -E -c 'skip: WINDOWS' "$CORE_SUITE" || true)"
if [ "$WINDOWS_CORE_SKIPS" -eq 4 ] \
  && grep -qF "test('runtime digest rejects symlinks below runtime roots'" "$CORE_SUITE" \
  && grep -qF "test('registers a POSIX-private immutable record'" "$CORE_SUITE" \
  && grep -qF "test('never replaces a planted immutable-record symlink'" "$CORE_SUITE" \
  && grep -qF "test('rejects a symlinked workflow state directory'" "$CORE_SUITE" \
  && grep -qF "test('rejects every explicit workflow state directory override on every host'" "$CORE_SUITE"; then
  check "shared Core limits Windows skips to POSIX mode and true symlink assertions" PASS
else
  check "shared Core limits Windows skips to POSIX mode and true symlink assertions" FAIL
fi

printf '%s\n' "----" "test-ci-session-control-windows: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
