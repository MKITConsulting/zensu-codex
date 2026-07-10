#!/bin/bash
# _zensu_log_style: resolves logging.timestampStyle to wall (default) / relative /
# none; any other value degrades to wall.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/plugins/zensu/hooks/lib/zensu-config.sh"

PASS=0; FAIL=0
ck() { [ "$2" = "$3" ] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); }; }
mkcfg() { local f; f="$(mktemp)"; printf '%s' "$1" > "$f"; printf '%s' "$f"; }

C="$(mkcfg '{"logging":{"timestampStyle":"wall"}}')";     ck "wall"          "$(ZENSU_CONFIG="$C" _zensu_log_style)" wall
C="$(mkcfg '{"logging":{"timestampStyle":"relative"}}')"; ck "relative"      "$(ZENSU_CONFIG="$C" _zensu_log_style)" relative
C="$(mkcfg '{"logging":{"timestampStyle":"none"}}')";     ck "none"          "$(ZENSU_CONFIG="$C" _zensu_log_style)" none
C="$(mkcfg '{"logging":{"timestampStyle":"bogus"}}')";    ck "invalid->wall" "$(ZENSU_CONFIG="$C" _zensu_log_style)" wall
C="$(mkcfg '{}')";                                         ck "absent->wall"  "$(ZENSU_CONFIG="$C" _zensu_log_style)" wall

echo "----"; echo "test-log-style: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
