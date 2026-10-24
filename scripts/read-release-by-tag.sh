#!/usr/bin/env bash
# The tag endpoint omits drafts. Search all accessible release pages so draft
# retries remain idempotent, and never interpret failed requests as absence.
set -euo pipefail
REPOSITORY="${1:?repository required}"
TAG="${2:?tag required}"
REQUIRED="${3:-}"
[ -z "$REQUIRED" ] || [ "$REQUIRED" = --required ] || exit 2
RESPONSE="$(gh api -H "X-GitHub-Api-Version: 2026-03-10" --paginate --slurp "repos/$REPOSITORY/releases?per_page=100")" || {
  echo 'Release lookup failed; refusing to infer that the release is absent' >&2
  exit 1
}
jq -e 'type == "array" and all(.[]; type == "array") and all(.[][]; type == "object")' <<<"$RESPONSE" >/dev/null || exit 1
MATCHES="$(jq -c --arg tag "$TAG" '[.[][] | select(.tag_name == $tag)]' <<<"$RESPONSE")"
COUNT="$(jq 'length' <<<"$MATCHES")"
if [ "$COUNT" = 0 ] && [ -z "$REQUIRED" ]; then exit 0; fi
[ "$COUNT" = 1 ] || { echo 'Release lookup did not find exactly one required release' >&2; exit 1; }
jq -e '.[0] | (.id | type == "number") and (.draft | type == "boolean")' <<<"$MATCHES" >/dev/null || exit 1
jq -c '.[0]' <<<"$MATCHES"
