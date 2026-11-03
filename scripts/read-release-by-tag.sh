#!/usr/bin/env bash
# The tag endpoint omits drafts. Search all accessible release pages so draft
# retries remain idempotent, and never interpret failed requests as absence.
set -euo pipefail
REPOSITORY="${1:?repository required}"
TAG="${2:?tag required}"
REQUIRED="${3:-}"
READY=true
[ -z "$REQUIRED" ] || [ "$REQUIRED" = --required ] || exit 2
if [ "$#" -gt 3 ]; then
  if [ "$REQUIRED" != --required ] || [ "$#" -ne 5 ] || [ "$4" != --until ] || [ -z "$5" ]; then exit 2; fi
  READY="$5"
fi
ATTEMPTS=1
[ -z "$REQUIRED" ] || ATTEMPTS=10
for ATTEMPT in $(seq 1 "$ATTEMPTS"); do
  RESPONSE="$(gh api -H "X-GitHub-Api-Version: 2026-03-10" --paginate --slurp "repos/$REPOSITORY/releases?per_page=100")" || {
    echo 'Release lookup failed; refusing to infer that the release is absent' >&2
    exit 1
  }
  jq -e 'type == "array" and all(.[]; type == "array") and all(.[][]; type == "object")' <<<"$RESPONSE" >/dev/null || exit 1
  MATCHES="$(jq -c --arg tag "$TAG" '[.[][] | select(.tag_name == $tag)]' <<<"$RESPONSE")"
  COUNT="$(jq 'length' <<<"$MATCHES")"
  READY_STATE=1
  if [ "$COUNT" = 1 ]; then
    READY_STATE=0
    jq -e ".[0] | ($READY)" <<<"$MATCHES" >/dev/null || READY_STATE=$?
    [ "$READY_STATE" -le 1 ] || exit 2
  fi
  if [ "$COUNT" -gt 1 ] || [ "$READY_STATE" = 0 ] || [ "$ATTEMPT" = "$ATTEMPTS" ]; then break; fi
  sleep 2
done
if [ "$COUNT" = 0 ] && [ -z "$REQUIRED" ]; then exit 0; fi
[ "$COUNT" = 1 ] || { echo 'Release lookup did not find exactly one required release' >&2; exit 1; }
[ "$READY_STATE" = 0 ] || { echo "Release $TAG did not reach the awaited state after $ATTEMPT reads" >&2; exit 1; }
jq -e '.[0] | (.id | type == "number") and (.draft | type == "boolean")' <<<"$MATCHES" >/dev/null || exit 1
jq -c '.[0]' <<<"$MATCHES"
