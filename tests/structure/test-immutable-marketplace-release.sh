#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/release.yml"
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

expect_text() {
  if grep -Fq -- "$2" "$WORKFLOW"; then check "$1" PASS
  else check "$1" FAIL; fi
}

expect_text "publish verifies the immutable marketplace target" \
  '- name: Verify immutable marketplace release target'
expect_text "production source is constrained to the official repository" \
  'test "$(jq -r '\''.plugins[0].source.url'\'' .agents/plugins/marketplace.json)" = https://github.com/MKITConsulting/zensu-codex.git'
expect_text "production source ref must equal the manifest release tag" \
  'test "$(jq -r '\''.plugins[0].source.ref'\'' .agents/plugins/marketplace.json)" = "$TAG"'
expect_text "a pre-existing tag at another commit fails closed" \
  'already exists at $TAG_SHA, not exact main SHA'
expect_text "a mutable published release fails closed" \
  'existing published release $TAG is mutable; refusing to trust or replace it'
expect_text "the exact-SHA archive is built before an existing release can be skipped" \
  'git archive --format=zip -o "$EXPECTED_ASSET" "$GITHUB_SHA"'
expect_text "an existing immutable asset must equal the exact-SHA archive byte-for-byte" \
  'cmp -s "$EXPECTED_ASSET" "$EXISTING_DIR/$ASSET"'
expect_text "an existing immutable release must have the exact title" \
  'existing immutable release title does not match $TAG'
expect_text "an existing immutable release must have the exact generated notes" \
  'existing immutable release notes do not match generated notes'
expect_text "only a draft release may be resumed" \
  'test "$(jq -r '\''.draft'\'' <<<"$RELEASE_JSON")" = true'
expect_text "draft creation targets the gated commit" \
  'gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --draft \'
expect_text "draft upload is constrained to one asset" \
  'test "$(jq '\''.assets | length'\'' <<<"$RELEASE_JSON")" = 1'
expect_text "the uploaded asset digest must match the local package" \
  'test "$(jq -r '\''.assets[0].digest'\'' <<<"$RELEASE_JSON")" = "$LOCAL_DIGEST"'
expect_text "draft metadata is normalized before upload" \
  'gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=true --prerelease=false --title "$TAG" --notes-file "${{ runner.temp }}/notes.md"'
expect_text "draft title is verified before upload" \
  'test "$(jq -r '\''.name'\'' <<<"$RELEASE_JSON")" = "$TAG"'
expect_text "draft body is verified against generated notes" \
  'test "$(jq -r '\''.body'\'' <<<"$RELEASE_JSON")" = "$EXPECTED_BODY"'
expect_text "immutable releases are checked before publish work" \
  '- name: Require immutable releases before publish work'
expect_text "immutable releases are rechecked immediately before publication" \
  '- name: Recheck immutable releases immediately before publish'
expect_text "the dedicated immutable-release secret is mandatory" \
  'IMMUTABLE_RELEASES_ADMIN_TOKEN is required'
expect_text "the validated draft is explicitly published" \
  'gh release edit "${{ steps.v.outputs.tag }}" --repo "$GITHUB_REPOSITORY" --draft=false'
expect_text "draft metadata and asset are revalidated immediately before publish" \
  '- name: Revalidate draft metadata and asset immediately before publish'
expect_text "the published release must become immutable" \
  'test "$(jq -r '\''.immutable'\'' <<<"$RELEASE_JSON")" = true'
expect_text "the published asset digest is verified by download" \
  'test "sha256:$(sha256sum "$VERIFY_DIR/$ASSET" | awk '\''{print $1}'\'')" = "$API_DIGEST"'
expect_text "final verification rebuilds the exact-SHA archive independently" \
  'git archive --format=zip -o "$FINAL_EXPECTED_ASSET" "$GITHUB_SHA"'
expect_text "final downloaded asset must equal the exact-SHA archive byte-for-byte" \
  'cmp -s "$FINAL_EXPECTED_ASSET" "$VERIFY_DIR/$ASSET"'
expect_text "the final tag must resolve to the gated SHA" \
  'test "$(git rev-list -n 1 "$TAG")" = "$GITHUB_SHA"'
expect_text "post-bump version invariants are re-run" \
  'bash tests/structure/test-version-sync.sh'
expect_text "post-bump immutable release invariants are re-run" \
  'bash tests/structure/test-immutable-marketplace-release.sh'

IMMUTABLE_GETS="$(grep -Fc 'repos/$GITHUB_REPOSITORY/immutable-releases' "$WORKFLOW")"
if [ "$IMMUTABLE_GETS" -eq 2 ]; then
  check "immutable-release policy is checked exactly twice" PASS
else
  check "immutable-release policy is checked exactly twice" FAIL
fi

GH_API_CALLS="$(grep -c 'gh api ' "$WORKFLOW")"
VERSIONED_API_CALLS="$(grep -c 'gh api -H "X-GitHub-Api-Version: 2026-03-10"' "$WORKFLOW")"
if [ "$GH_API_CALLS" -eq 8 ] && [ "$VERSIONED_API_CALLS" -eq "$GH_API_CALLS" ]; then
  check "every immutable-release and release/asset API read pins 2026-03-10" PASS
else
  check "every immutable-release and release/asset API read pins 2026-03-10" FAIL
fi

if grep -Fq 'softprops/action-gh-release' "$WORKFLOW"; then
  check "release publication does not use an opaque action" FAIL
else
  check "release publication does not use an opaque action" PASS
fi

GATE_LINE="$(grep -nF -- '- name: Exact-SHA Session Control publish gate' "$WORKFLOW" | cut -d: -f1)"
RELEASE_LINE="$(grep -nF -- '- name: Create or validate draft and upload the single asset' "$WORKFLOW" | tail -1 | cut -d: -f1)"
if [ -n "$GATE_LINE" ] && [ -n "$RELEASE_LINE" ] && [ "$GATE_LINE" -lt "$RELEASE_LINE" ]; then
  check "exact-main-SHA gate precedes draft creation or mutation" PASS
else
  check "exact-main-SHA gate precedes draft creation or mutation" FAIL
fi

GATE_DECL="$(sed -n "${GATE_LINE},$((GATE_LINE + 3))p" "$WORKFLOW")"
if printf '%s\n' "$GATE_DECL" | grep -Fq 'if:'; then
  check "exact-SHA publish gate is unskippable for existing releases" FAIL
else
  check "exact-SHA publish gate is unskippable for existing releases" PASS
fi

FINAL_LINE="$(grep -nF -- '- name: Verify immutable release, exact tag SHA, and asset digest' "$WORKFLOW" | cut -d: -f1)"
FINAL_DECL="$(sed -n "${FINAL_LINE},$((FINAL_LINE + 3))p" "$WORKFLOW")"
if printf '%s\n' "$FINAL_DECL" | grep -Fq 'if:'; then
  check "final immutable release verification is unskippable" FAIL
else
  check "final immutable release verification is unskippable" PASS
fi

printf '%s\n' "----" "test-immutable-marketplace-release: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
