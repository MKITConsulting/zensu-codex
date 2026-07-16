#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$ROOT/plugins/zensu/hooks"
LIB="$HOOKS/lib"
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

if [ -f "$LIB/codex-session-control-resolve-v3.js" ] \
  && [ -f "$LIB/codex-session-control-v1.js" ] \
  && grep -Fq "path.join(__dirname, 'codex-session-control-resolve-v3.js')" "$LIB/codex-session-control-v1.js"; then
  check "reader ABI v3 has one repo source and one publisher" PASS
else
  check "reader ABI v3 has one repo source and one publisher" FAIL
fi

LEGACY_FILES="$(find "$HOOKS" -type f \( \
  -name 'codex-plugin-root-*' -o \
  -name 'resolve-session-id*' -o \
  -name 'session-start-register-plugin-root*' \
\) -print)"
if [ -z "$LEGACY_FILES" ]; then
  check "legacy plugin-root and session-id resolver files are absent" PASS
else
  check "legacy plugin-root and session-id resolver files are absent" FAIL
fi

if rg -n 'session-id-current|plugin-roots/codex|codex-plugin-root-registry|codex-plugin-root-resolve|resolve-session-id' \
  "$HOOKS" --glob '!lib/session-control-core-v1.js' >"${TMPDIR:-/tmp}/zensu-resolver-sot.$$" 2>/dev/null; then
  check "runtime hooks contain no legacy resolver stragglers" FAIL
else
  check "runtime hooks contain no legacy resolver stragglers" PASS
fi
rm -f "${TMPDIR:-/tmp}/zensu-resolver-sot.$$"

SESSION_HELPER="$LIB/zensu-session.sh"
if grep -Fq 'resolve-v3.js' "$SESSION_HELPER" \
  && grep -Fq -- '--field project_root' "$SESSION_HELPER" \
  && ! grep -Eq 'CODEX_THREAD_ID|CLAUDE_PROJECT_DIR|TDD_STATE_DIR|PWD' "$SESSION_HELPER"; then
  check "project resolution uses only injected-key reader ABI v3" PASS
else
  check "project resolution uses only injected-key reader ABI v3" FAIL
fi

if rg -n '^: "\$\{CLAUDE_PLUGIN_ROOT|CODEX_PLUGIN_ROOT|ZENSU_PLUGIN_ROOT' "$HOOKS" --glob '*.sh' \
  >"${TMPDIR:-/tmp}/zensu-root-default.$$" 2>/dev/null; then
  check "executable hooks never trust inherited plugin-root defaults" FAIL
else
  check "executable hooks never trust inherited plugin-root defaults" PASS
fi
rm -f "${TMPDIR:-/tmp}/zensu-root-default.$$"

printf '%s\n' "----" "test-session-control-resolver-sot: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
