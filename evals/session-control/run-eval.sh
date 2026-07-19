#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$DIR/../.." && pwd -P)"
MODE="${1:-contract}"
export PROMPTFOO_DISABLE_UPDATE=1
export PROMPTFOO_DISABLE_TELEMETRY=1
# Source identity is always content-addressed. Retired ambient revision and
# authority overrides are removed before every eval; live Git identity remains
# separate wrapper-owned evidence after source/installed runtime verification.
unset ZENSU_SOURCE_REVISION ZENSU_SOURCE_REVISION_AUTHORITY
OWN_CONFIG_DIR=0
CONCURRENCY_LEDGER=""
if [ -z "${PROMPTFOO_CONFIG_DIR:-}" ]; then
  PROMPTFOO_CONFIG_DIR="$(mktemp -d -t zensu-promptfoo-XXXXXX)"
  export PROMPTFOO_CONFIG_DIR
  OWN_CONFIG_DIR=1
fi
if [ -z "${ZENSU_EVIDENCE_DIR:-}" ]; then
  ZENSU_EVIDENCE_DIR="$PROMPTFOO_CONFIG_DIR/session-control-evidence"
  export ZENSU_EVIDENCE_DIR
fi
mkdir -p "$ZENSU_EVIDENCE_DIR"
chmod 700 "$ZENSU_EVIDENCE_DIR"
cleanup() {
  if [ "$OWN_CONFIG_DIR" = 1 ]; then rm -rf "$PROMPTFOO_CONFIG_DIR"; fi
  if [ -n "$CONCURRENCY_LEDGER" ]; then rm -rf "$CONCURRENCY_LEDGER"; fi
}
trap cleanup EXIT

case "$MODE" in
  self-check|contract|live|concurrency|adversarial|nightly|release) ;;
  *) printf 'usage: %s {self-check|contract|live|concurrency|adversarial|nightly|release}\n' "$0" >&2; exit 2 ;;
esac

"$DIR/run-self-check.sh"
[ "$MODE" = self-check ] && exit 0

if [ ! -x "$ROOT/node_modules/.bin/promptfoo" ]; then
  printf 'session-control eval: repo-local Promptfoo is missing; run npm ci\n' >&2
  exit 2
fi
VERSION="$($ROOT/node_modules/.bin/promptfoo --version 2>/dev/null | awk 'NF { version=$0 } END { sub(/\r$/, "", version); print version }')"
if [ "$VERSION" != '0.121.18' ]; then
  printf 'session-control eval: expected Promptfoo 0.121.18, got %s\n' "$VERSION" >&2
  exit 2
fi

run_config() {
  local suite="$1"
  local repeat=1 result_file
  printf '\n== Session Control Promptfoo suite: %s ==\n' "$suite"
  if [ "$suite" = concurrency ]; then
    CONCURRENCY_LEDGER="$(mktemp -d -t zensu-concurrency-ledger-XXXXXX)"
    chmod 700 "$CONCURRENCY_LEDGER"
    export ZENSU_CONCURRENCY_LEDGER
    export ZENSU_CONCURRENCY_WIDTH=4
    repeat=3
  elif [ "$suite" = adversarial ]; then
    repeat=5
  fi
  result_file="$ZENSU_EVIDENCE_DIR/promptfoo-$suite-results.json"
  (
    cd "$DIR"
    if [ "$suite" = contract ]; then
      env -u ZENSU_EXPECTED_SOURCE_REVISION \
        "$ROOT/node_modules/.bin/promptfoo" eval \
        --no-cache --no-table --no-write -o "$result_file" -c "promptfooconfig-$suite.yaml"
    else
      "$ROOT/node_modules/.bin/promptfoo" eval \
        --no-cache --no-table --no-write -o "$result_file" -c "promptfooconfig-$suite.yaml"
    fi
  )
  node "$DIR/lib/verify-promptfoo-results.js" \
    "$result_file" "$DIR/scenarios/catalog.yaml" "$suite" "$repeat"
  if [ "$suite" = concurrency ]; then
    node "$DIR/lib/verify-concurrency-ledger.js" \
      "$CONCURRENCY_LEDGER" "$ZENSU_EXPECTED_PLUGIN_ROOT" 12 4
    printf 'Concurrency audit: 12 unique sessions contended in three four-way waves on one immutable record.\n'
    rm -rf "$CONCURRENCY_LEDGER"
    CONCURRENCY_LEDGER=""
    unset ZENSU_CONCURRENCY_LEDGER
    unset ZENSU_CONCURRENCY_WIDTH
  fi
}

require_live_inputs() {
  local codex_version
  : "${ZENSU_CODEX_HOME_OVERRIDE:?live eval requires ZENSU_CODEX_HOME_OVERRIDE}"
  : "${ZENSU_EXPECTED_SOURCE_ROOT:?live eval requires ZENSU_EXPECTED_SOURCE_ROOT}"
  : "${ZENSU_EXPECTED_PLUGIN_ROOT:?live eval requires ZENSU_EXPECTED_PLUGIN_ROOT}"
  : "${ZENSU_EXPECTED_SOURCE_REVISION:?live eval requires ZENSU_EXPECTED_SOURCE_REVISION}"
  [ -s "$ZENSU_CODEX_HOME_OVERRIDE/auth.json" ] || { echo 'live eval Codex auth is missing' >&2; exit 2; }
  [ -s "$ZENSU_CODEX_HOME_OVERRIDE/config.toml" ] || { echo 'live eval Codex config is missing' >&2; exit 2; }
  [ "$(git -C "$ZENSU_EXPECTED_SOURCE_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$ZENSU_EXPECTED_SOURCE_ROOT" && pwd -P)" ] \
    || { echo 'live eval source root is not the exact Git checkout root' >&2; exit 2; }
  [ -s "$ZENSU_EXPECTED_PLUGIN_ROOT/.codex-plugin/plugin.json" ] || { echo 'live eval plugin root is invalid' >&2; exit 2; }
  [[ "$ZENSU_EXPECTED_SOURCE_REVISION" =~ ^[a-f0-9]{40,64}$ ]] || { echo 'live eval source revision is not an exact Git SHA' >&2; exit 2; }
  command -v codex >/dev/null 2>&1 || { echo 'live eval Codex CLI is missing' >&2; exit 2; }
  codex_version="$(codex --version 2>/dev/null | tr -d '\r')"
  [ "$codex_version" = 'codex-cli 0.144.1' ] || {
    printf 'live eval expected Codex CLI codex-cli 0.144.1, got %s\n' "$codex_version" >&2
    exit 2
  }
  node "$DIR/lib/release-integrity.js" \
    "$ZENSU_EXPECTED_SOURCE_ROOT" "$ZENSU_EXPECTED_SOURCE_REVISION" "$ZENSU_EXPECTED_PLUGIN_ROOT" >/dev/null
}

case "$MODE" in
  contract)
    run_config contract
    ;;
  live|concurrency|adversarial)
    require_live_inputs
    run_config "$MODE"
    ;;
  nightly)
    require_live_inputs
    run_config contract
    run_config live
    run_config concurrency
    run_config adversarial
    ;;
  release)
    require_live_inputs
    node "$DIR/lib/release-integrity.js" "$ZENSU_EXPECTED_SOURCE_ROOT" "$ZENSU_EXPECTED_SOURCE_REVISION" "$ZENSU_EXPECTED_PLUGIN_ROOT" >/dev/null
    run_config contract
    run_config live
    run_config concurrency
    run_config adversarial
    node "$DIR/lib/release-integrity.js" "$ZENSU_EXPECTED_SOURCE_ROOT" "$ZENSU_EXPECTED_SOURCE_REVISION" "$ZENSU_EXPECTED_PLUGIN_ROOT" >/dev/null
    ;;
esac
