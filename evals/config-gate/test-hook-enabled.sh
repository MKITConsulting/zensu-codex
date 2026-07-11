#!/bin/bash
# zensu_hook_enabled: default-on unless the hook key is explicitly false; fail-open
# when the config file is missing. Exercised against the Codex config key set.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/plugins/zensu/hooks/lib/zensu-config.sh"

PASS=0; FAIL=0
ck() { [ "$2" = "$3" ] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); }; }
mkcfg() { local f; f="$(mktemp)"; printf '%s' "$1" > "$f"; printf '%s' "$f"; }
onoff() { if ZENSU_CONFIG="$1" zensu_hook_enabled "$2"; then echo on; else echo off; fi; }

C="$(mkcfg '{"hooks":{}}')";                            ck "absent bashWriteGate -> on (default)"     "$(onoff "$C" bashWriteGate)" on
C="$(mkcfg '{"hooks":{"bashWriteGate":false}}')";       ck "bashWriteGate:false -> off"               "$(onoff "$C" bashWriteGate)" off
C="$(mkcfg '{"hooks":{"tddReminder":true}}')";          ck "tddReminder:true -> on"                   "$(onoff "$C" tddReminder)" on
C="$(mkcfg '{"hooks":{"intentRouter":false}}')";        ck "intentRouter:false -> off"                "$(onoff "$C" intentRouter)" off
C="$(mkcfg '{"hooks":{"chainEnforcer":false}}')";       ck "chainEnforcer:false -> off"               "$(onoff "$C" chainEnforcer)" off
ck "missing config -> on (fail-open)" "$(onoff "/no/such/config-$$.json" sessionBanner)" on

echo "----"; echo "test-hook-enabled: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
