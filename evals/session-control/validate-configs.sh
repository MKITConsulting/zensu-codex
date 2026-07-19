#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$DIR/../.." && pwd -P)"
export PROMPTFOO_DISABLE_UPDATE=1
export PROMPTFOO_DISABLE_TELEMETRY=1
OWN_CONFIG_DIR=0
if [ -z "${PROMPTFOO_CONFIG_DIR:-}" ]; then
  PROMPTFOO_CONFIG_DIR="$(mktemp -d -t zensu-promptfoo-validate-XXXXXX)"
  export PROMPTFOO_CONFIG_DIR
  OWN_CONFIG_DIR=1
fi
cleanup() {
  if [ "$OWN_CONFIG_DIR" = 1 ]; then rm -rf "$PROMPTFOO_CONFIG_DIR"; fi
}
trap cleanup EXIT

PF="$ROOT/node_modules/.bin/promptfoo"
[ -x "$PF" ] || { echo 'Promptfoo is missing; run npm ci' >&2; exit 2; }
[ "$($PF --version 2>/dev/null | awk 'NF { v=$0 } END { sub(/\r$/, "", v); print v }')" = 0.121.18 ] \
  || { echo 'Promptfoo 0.121.18 is required' >&2; exit 2; }

"$PF" validate config -c \
  "$DIR/promptfooconfig-contract.yaml" \
  "$DIR/promptfooconfig-live.yaml" \
  "$DIR/promptfooconfig-concurrency.yaml" \
  "$DIR/promptfooconfig-adversarial.yaml"
