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
#           Fixed: publish runs on any push to main and is gated by the
#           tag-existence idempotency guard, independent of the subject.
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

# Bug 2 — the tag-existence idempotency guard is the real gate and must remain.
if printf '%s\n' "$ACTIVE" | grep -Fq 'git rev-parse "v$VER"' \
   && printf '%s\n' "$ACTIVE" | grep -Fq 'skip=true'; then
  ok "publish keeps the tag-existence idempotency guard"
else
  bad "publish lost its tag-existence idempotency guard"
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
