#!/usr/bin/env bash
# Classify whether a main-branch push is the exact release SHA that may publish
# the version declared by the plugin manifest.
set -euo pipefail

ROOT="${RELEASE_CLASSIFIER_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHA="${1:-${GITHUB_SHA:-HEAD}}"
MANIFEST="plugins/zensu/.codex-plugin/plugin.json"

cd "$ROOT"

SHA="$(git rev-parse --verify "${SHA}^{commit}")"
VER="$(git show "${SHA}:${MANIFEST}" | jq -er '.version')"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid plugin version '$VER' in $MANIFEST" >&2
  exit 1
}
TAG="v$VER"

if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  TAG_SHA="$(git rev-list -n 1 "$TAG")"
  if [ "$TAG_SHA" = "$SHA" ]; then
    echo "Version tag $TAG already targets this SHA; revalidating publication idempotently." >&2
    printf 'true\n'
  else
    echo "Version tag $TAG targets $TAG_SHA; this push is not its release SHA." >&2
    printf 'false\n'
  fi
  exit 0
fi

# A missing tag alone is not a release signal: after a failed/delayed publish,
# a later feature push still sees the tag missing. Only the commit that changes
# the manifest version versus main's first parent may create the new release.
PARENT="$(git rev-parse --verify "${SHA}^1^{commit}")"
PARENT_VER="$(git show "${PARENT}:${MANIFEST}" | jq -er '.version')"
[[ "$PARENT_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid parent plugin version '$PARENT_VER' in $MANIFEST" >&2
  exit 1
}

semver_greater_than() {
  local candidate_major candidate_minor candidate_patch
  local parent_major parent_minor parent_patch
  IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$1"
  IFS=. read -r parent_major parent_minor parent_patch <<< "$2"
  (( 10#$candidate_major > 10#$parent_major )) && return 0
  (( 10#$candidate_major < 10#$parent_major )) && return 1
  (( 10#$candidate_minor > 10#$parent_minor )) && return 0
  (( 10#$candidate_minor < 10#$parent_minor )) && return 1
  (( 10#$candidate_patch > 10#$parent_patch ))
}

if semver_greater_than "$VER" "$PARENT_VER"; then
  echo "Version changed from $PARENT_VER to $VER and $TAG is absent; this is the release SHA." >&2
  printf 'true\n'
elif [ "$PARENT_VER" != "$VER" ]; then
  echo "Version changed from $PARENT_VER to non-increasing $VER; refusing an invalid release transition." >&2
  exit 1
else
  echo "Version stayed at $VER while $TAG is absent; refusing to publish from a later feature SHA." >&2
  printf 'false\n'
fi
