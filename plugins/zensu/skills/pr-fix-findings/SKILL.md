---
name: zensu-pr-fix-findings
description: Fix every open review comment on a GitHub pull request end-to-end — locate the PR, pull the unresolved review threads, triage independent vs dependent work, implement each fix through the Zensu workflow, parallelize independent fixes, push, resolve the threads on the PR, and report back. Use when the user wants to address, fix, or resolve PR review feedback / reviewer findings, or to work through a review.
---

# $zensu-pr-fix-findings

Resolve **every open review comment** on a pull request: implement each fix through
the Zensu workflow, parallelize independent fixes, push, resolve the threads on the
PR, and report back.

## When to Use

- A PR has review comments / change requests you want addressed in one pass.
- You want iterative, repeatable cleanup of review feedback.
- Reviewer left inline findings across several files and the fixes are mostly independent.

Not for: authoring a brand-new review from scratch, or planning unbuilt work (use
`$zensu-bootstrap`).

## Prerequisites

- `gh` CLI authenticated (`gh auth status`).
- Zensu CLI installed and authenticated (`zensu auth status`; `zensu auth login` if needed).
- The current branch has an open PR, or a PR number is supplied as an argument.

## Arguments

- Optional PR number to target. Omitted → the PR for the current branch.

## Procedure

1. **Locate the PR.**
   - With a PR number: `gh pr view <n> --json number,url,state,headRefName,baseRefName`.
   - Otherwise: `gh pr view --json number,url,state,headRefName,baseRefName` (current branch).
   - If no PR exists or `state != OPEN`: stop and report. Never push to a closed/merged PR.

2. **Collect unresolved feedback.**
   - Inline review comments: `gh api repos/{owner}/{repo}/pulls/<n>/comments --paginate`.
   - Unresolved review threads (authoritative for resolution state) via GraphQL —
     `reviewThreads { isResolved, isOutdated, comments { body, path, line, author } }`;
     keep only `isResolved == false`.
   - Top-level review bodies: `gh api repos/{owner}/{repo}/pulls/<n>/reviews`.
   - Build a worklist of actionable items. Skip pure praise, already-addressed, and outdated-and-moot threads.

3. **Triage for parallelism.**
   - Group items by independence. Items touching disjoint files/concerns are
     independent → safe to fix in parallel. Items on the same file/region or with
     ordering dependencies → sequential.
   - When several items are independent, fan them out across parallel subagents (one
     per item or cluster, isolated worktrees if they edit files concurrently). A
     single small item does not need fan-out — fix it inline.

4. **Implement each fix via the Zensu workflow.**
   - Code changes go through the Zensu workflow (`$zensu-tdd`) so the evidence audit
     + review chain run. For parallel fan-out, each agent implements its item and
     returns a structured result (files changed, what was fixed, residual risk).
   - After edits: run the relevant type-check / tests. Fix what you broke.

5. **Land the changes.**
   - Re-verify the PR is still OPEN (`gh pr view --json state`) before pushing.
   - Commit with a Conventional Commit message referencing the addressed comments,
     push to the PR branch. Clean commit messages — no watermark / co-author lines.

6. **Resolve the threads.**
   - For each addressed thread: reply to the comment with a one-line note on the fix
     (commit SHA), then resolve it via GraphQL `resolveReviewThread`.
   - Leave threads you could NOT resolve open, with a reply explaining why or what
     decision you need.

7. **Report back.**
   - Summary table: comment → action taken → commit → resolved?
   - Call out anything that needs a human decision, anything skipped, and the
     test / type-check results.

## Loop behaviour

When invoked repeatedly (e.g. under a loop runner): each iteration re-fetches
unresolved threads.

- If **none remain**, report "all review comments resolved" and stop.
- Otherwise address the next batch and continue.

Stop early and ask the user when you hit a fix that needs a product/architecture
decision, an auth error (`zensu auth login`), or a failing gate you cannot satisfy.
