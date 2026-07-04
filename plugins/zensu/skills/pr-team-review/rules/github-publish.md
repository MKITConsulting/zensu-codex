# GitHub Publish — `gh api` Reviews Reference

How to post one consolidated review with bundled inline comments via `gh api`.

## Endpoint

```
POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews
```

Docs: <https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request>

## Payload Shape

```json
{
  "commit_id": "<40-char head SHA>",
  "event": "COMMENT" | "REQUEST_CHANGES" | "APPROVE",
  "body": "<markdown overall body>",
  "comments": [
    {
      "path": "src/main/java/.../X.java",
      "line": 42,
      "side": "RIGHT",
      "body": "<markdown inline comment>"
    },
    {
      "path": "src/main/java/.../Y.sql",
      "start_line": 10,
      "line": 14,
      "start_side": "RIGHT",
      "side": "RIGHT",
      "body": "<multi-line range comment>"
    }
  ]
}
```

## Submission

Write the full payload to a file, post it via `--input`:

```bash
gh api -X POST repos/<owner>/<repo>/pulls/<n>/reviews \
  --input $WORKDIR/_synthesis.json
```

Capture the response — `id` and `html_url` are the values you return to the user.

## `line` + `side` Rules

| File `changeType` (from `gh pr view --json files`) | Default `side` for new content | Notes |
|---|---|---|
| `ADDED` | `RIGHT` | Every line is in the diff; any line number valid |
| `MODIFIED` | `RIGHT` for new lines, `LEFT` for removed lines | Line must be in the diff hunk — out-of-hunk → 422 |
| `RENAMED` | `RIGHT` | Use the new path |
| `REMOVED` | `LEFT` | Use the old path |

**Multi-line comments**: provide `start_line` + `line` (both on same `side`). GitHub renders as a range.

**`position` (legacy)**: don't use unless `line`/`side` doesn't fit. `position` is the line offset within the unified diff — fragile.

## Single-Submit vs Multi-Submit

**Always single-submit**: bundle all inline comments in the `comments[]` array of ONE review. Why:
- Atomic: either all post or none.
- One notification email to PR author + reviewers (not 25).
- One entry in the PR's review history.
- Easy to revoke (one `DELETE /reviews/<id>`).

**Don't** loop over `gh api .../pulls/comments` for each inline — that creates N orphaned comments with no review wrapper.

## Idempotency

Re-running the skill on the same PR posts an **additional** review. There's no native idempotency key. If you want to suppress duplicates, hash the synthesis body and check existing reviews before posting:

```bash
HASH=$(jq -r '.body' $WORKDIR/_synthesis.json | sha256sum | head -c 8)
if gh api repos/<o>/<r>/pulls/<n>/reviews | jq -e ".[] | select(.body | contains(\"$HASH\"))" > /dev/null; then
  echo "Already posted — skipping"
  exit 0
fi
# else inject HASH into body footer and post
```

Default behaviour: post without dedup, accept that re-runs create additional reviews.

## Auth Pre-Check

Before any POST:

```bash
gh auth status 2>&1 | grep -q "Logged in" || { echo "gh auth required"; exit 1; }
```

Required scopes:
- `repo` (full) for private repos
- `public_repo` for public repos only

If scopes missing: `gh auth refresh -s repo`.

## Failure Modes

| HTTP status | Cause | Fix |
|---|---|---|
| 401 | Token invalid/expired | `gh auth refresh` |
| 403 | Scope missing OR fine-grained token restriction | `gh auth refresh -s repo` |
| 404 | PR doesn't exist OR no read access | Verify PR URL + repo membership |
| 422 (line out of diff) | Inline `line` not in any diff hunk | Drop comment, refetch diff to find valid line, retry |
| 422 (commit_id mismatch) | Head SHA changed since fetch | Re-run `git rev-parse pr-<n>-review`, update payload, retry |
| 500 / 502 | GitHub transient | Wait 30s, retry once |

For 422 line-out-of-diff: identify the offending comment(s) by binary search — `jq 'del(.comments[<i>])' payload.json > shrunk.json` and retry until POST succeeds.

## Fallback: Per-Comment Posting

If the single-submit fails for non-retryable reasons (e.g. malformed payload), fall back to:

```bash
# Overall body only
gh pr review <n> --repo <o>/<r> --comment --body-file /tmp/body.md

# Each inline separately (review_id from previous submit OR use pulls/comments without review)
gh api repos/<o>/<r>/pulls/<n>/comments \
  -X POST \
  -f path=<path> \
  -F line=<line> \
  -f side=RIGHT \
  -f body=<markdown> \
  -f commit_id=<sha>
```

This loses atomicity but unblocks the user. Mention the fallback in the final message.

## Verification After Post

```bash
gh api repos/<o>/<r>/pulls/<n>/reviews/<id>/comments | jq length
# Should equal len(payload.comments)
gh pr view <n> --repo <o>/<r> --json reviews | jq '.reviews[-1] | {state, author: .author.login, submittedAt}'
```

Return `html_url` from the POST response to the user (format: `https://github.com/<o>/<r>/pull/<n>#pullrequestreview-<id>`).
