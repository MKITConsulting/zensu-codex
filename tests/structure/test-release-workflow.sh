#!/usr/bin/env bash
# Release-pipeline invariants for .github/workflows/release.yml. Pins the two
# defects that a live v0.3.2 release exposed so they cannot silently regress:
#
#   Bug 1 — the `prepare` job spliced the git-cliff section onto a `## [Unreleased]`
#           anchor that CHANGELOG.md never carries, so the section was dropped and
#           the release shipped with the OLD CHANGELOG heading (caught only later
#           by test-version-sync.sh). Fixed: splice above the newest `## [x.y.z]`
#           heading + a post-splice guard that fails prepare loudly.
#
#   Bug 2 — the `publish` job gated on the commit subject
#           (`startsWith(head_commit.message, 'chore(release): bump version to')`).
#           A squash-merge derives its subject from the PR title, so a differently
#           titled release PR made publish skip silently — no tag, no release.
#           Fixed: a subject-independent gate classifies the version tag and
#           manifest transition on every push to main. Only the version-changing
#           SHA or an idempotent same-tag replay may publish.
#
# Assertions run against the ACTIVE workflow config (comment lines stripped) so
# that prose mentioning the old patterns cannot mask a real regression.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

WF="$ROOT/.github/workflows/release.yml"
CL="$ROOT/CHANGELOG.md"
CLASSIFIER="$ROOT/scripts/classify-release-push.sh"

if [ ! -f "$WF" ]; then
  bad "release.yml missing"
  printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# Active config only: drop YAML + shell (`run:` block) comment lines.
ACTIVE="$(grep -vE '^[[:space:]]*#' "$WF")"

# Bug 2 — publish must NOT depend on the commit subject.
if printf '%s\n' "$ACTIVE" | grep -Fq 'head_commit.message'; then
  bad "publish still gates on head_commit.message (subject-fragile — Bug 2)"
else
  ok "publish is not gated on the commit subject"
fi

# Bug 2 — the version/tag classifier is the real gate. Keep it outside YAML so
# its race-sensitive behavior can be executed below instead of string-matched.
if printf '%s\n' "$ACTIVE" | grep -Fq 'publish-gate:' \
   && printf '%s\n' "$ACTIVE" | grep -Fq 'bash scripts/classify-release-push.sh "$GITHUB_SHA"' \
   && printf '%s\n' "$ACTIVE" | grep -Fq 'needs: publish-gate' \
   && printf '%s\n' "$ACTIVE" | grep -Fq "needs.publish-gate.outputs.should_publish == 'true'"; then
  ok "publish uses the executable version/tag classifier"
else
  bad "publish lost the subject-independent executable classifier"
fi

# Regression for the delayed-publish race: if the release tag is still absent,
# a later feature SHA with the same manifest version must not steal the release.
if [ -f "$CLASSIFIER" ]; then
  TMP_REPO="$(mktemp -d)"
  trap 'rm -rf "$TMP_REPO"' EXIT
  git -C "$TMP_REPO" init -q
  git -C "$TMP_REPO" config user.name "Release Gate Test"
  git -C "$TMP_REPO" config user.email "release-gate@example.invalid"
  mkdir -p "$TMP_REPO/plugins/zensu/.codex-plugin"
  printf '{"version":"0.3.2"}\n' > "$TMP_REPO/plugins/zensu/.codex-plugin/plugin.json"
  git -C "$TMP_REPO" add .
  git -C "$TMP_REPO" commit -qm "chore: seed version"
  git -C "$TMP_REPO" tag v0.3.2

  printf '{"version":"0.4.0"}\n' > "$TMP_REPO/plugins/zensu/.codex-plugin/plugin.json"
  git -C "$TMP_REPO" commit -qam "chore(release): bump version to 0.4.0"
  RELEASE_SHA="$(git -C "$TMP_REPO" rev-parse HEAD)"
  RELEASE_RESULT="$(RELEASE_CLASSIFIER_REPO_ROOT="$TMP_REPO" bash "$CLASSIFIER" "$RELEASE_SHA")"

  printf 'feature\n' > "$TMP_REPO/feature.txt"
  git -C "$TMP_REPO" add feature.txt
  git -C "$TMP_REPO" commit -qm "feat: later feature"
  FEATURE_SHA="$(git -C "$TMP_REPO" rev-parse HEAD)"
  FEATURE_RESULT="$(RELEASE_CLASSIFIER_REPO_ROOT="$TMP_REPO" bash "$CLASSIFIER" "$FEATURE_SHA")"

  git -C "$TMP_REPO" tag v0.4.0 "$RELEASE_SHA"
  REPLAY_RESULT="$(RELEASE_CLASSIFIER_REPO_ROOT="$TMP_REPO" bash "$CLASSIFIER" "$RELEASE_SHA")"
  TAGGED_FEATURE_RESULT="$(RELEASE_CLASSIFIER_REPO_ROOT="$TMP_REPO" bash "$CLASSIFIER" "$FEATURE_SHA")"

  printf '{"version":"0.3.9"}\n' > "$TMP_REPO/plugins/zensu/.codex-plugin/plugin.json"
  git -C "$TMP_REPO" commit -qam "chore: invalid version downgrade"
  DOWNGRADE_SHA="$(git -C "$TMP_REPO" rev-parse HEAD)"
  if RELEASE_CLASSIFIER_REPO_ROOT="$TMP_REPO" bash "$CLASSIFIER" "$DOWNGRADE_SHA" >/dev/null 2>&1; then
    DOWNGRADE_REJECTED=false
  else
    DOWNGRADE_REJECTED=true
  fi

  if [ "$RELEASE_RESULT" = true ] \
     && [ "$FEATURE_RESULT" = false ] \
     && [ "$REPLAY_RESULT" = true ] \
     && [ "$TAGGED_FEATURE_RESULT" = false ] \
     && [ "$DOWNGRADE_REJECTED" = true ]; then
    ok "classifier binds publication to the exact release SHA and rejects downgrades"
  else
    bad "classifier results unsafe: release=$RELEASE_RESULT feature=$FEATURE_RESULT replay=$REPLAY_RESULT tagged_feature=$TAGGED_FEATURE_RESULT downgrade_rejected=$DOWNGRADE_REJECTED"
  fi
else
  bad "release classifier script missing"
fi

# Bug 1 — no splice may anchor on a `## [Unreleased]` heading (absent from
# CHANGELOG). The bracketed `[Unreleased]` form is the anchor; git-cliff's
# `--unreleased` flag is legitimate and must not trip this check.
if printf '%s\n' "$ACTIVE" | grep -Eqi '\[unreleased\]'; then
  bad "prepare still anchors the CHANGELOG splice on [Unreleased] (Bug 1)"
else
  ok "prepare does not anchor the CHANGELOG splice on [Unreleased]"
fi

# Bug 1 — prepare must fail loudly when the section did not splice in.
if printf '%s\n' "$ACTIVE" | grep -Fq 'section not spliced'; then
  ok "prepare guards that the new version became the newest CHANGELOG heading"
else
  bad "prepare lacks the post-splice CHANGELOG-heading guard (Bug 1)"
fi

# The prepare commit subject stays conventional (notes/tooling depend on it).
if printf '%s\n' "$ACTIVE" | grep -Fq 'chore(release): bump version to'; then
  ok "prepare commits with the conventional 'bump version to' subject"
else
  bad "prepare no longer uses the conventional release commit subject"
fi

# The splice anchor must exist: CHANGELOG carries at least one semver heading.
if [ -f "$CL" ] && grep -qE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CL"; then
  ok "CHANGELOG.md carries a '## [x.y.z]' heading for the splice anchor"
else
  bad "CHANGELOG.md has no '## [x.y.z]' heading — splice-above anchor missing"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
