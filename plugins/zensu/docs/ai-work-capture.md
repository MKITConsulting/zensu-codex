# Automatic work capture

## Confirmed product scope

Automatic capture requires an explicitly human-confirmed repository product.
After the user confirms the exact product, run `zensu ai-work bind --product <uuid> --confirm`
in the repository. Never infer confirmation from a folder name, remote, existing
configuration, a prior unassigned record, or permission to implement a task.
The CLI validates the product against the current personal OAuth account and
organization. Its private binding lives in the Git common directory, outside
tracked files, and is shared by worktrees of that repository. It contains IDs and
an origin fingerprint, never credentials or the remote URL.

`zensu ai-work context` revalidates the binding. A host, account, organization,
origin or product-access change requires renewed explicit confirmation. Missing
bindings return `ready=false` and `workScope=unassigned`; the helper returns
`skipped_unassigned` without creating a work entry. Continue authorized coding.
Do not create a placeholder or silently switch to cross-product capture.

Only when the user explicitly requests work spanning products, supply
`--cross-product-reason <specific-reason>` on `begin`. The reason is required for
that goal and cannot be a repository default. Normal product work (including its
tests) keeps the confirmed product; run purpose and product scope are independent.

Receipts freeze product/cross-product scope, reason and authenticated identity
before declaration. Checkpoints revalidate the same scope. A changed binding
cannot retarget a pending report. Legacy receipts without confirmed scope remain
untouched and cannot auto-submit new results: use a new explicitly scoped goal.
Existing unassigned server entries appear in the separate **Unassigned** tab,
excluded from regular result metrics, with history and human acceptance retained.

Requires the product-scope backend and CLI `ai-work bind`, `context --cross-product`,
and `start --product/--cross-product-reason`. Upgrade backend, CLI, then plugins;
missing protocol support is visible incomplete capture. No fallback to an older
unscoped command is allowed. Submission never accepts a result.


For an authorized implementation task with confirmed product scope, record the already agreed objective once;
the user should not re-enter it in the dashboard. This is independent of the
Zensu review workflow and private Pulse tracking. Do not collect transcripts,
prompts, diffs, file lists, provider credentials or token usage.

Use the plugin root and the exact `captureSessionKey` provided by the capture
SessionStart primer. It is scoped to the trusted host session; do not invent it
or borrow a child/session key. It does not grant workflow-state access.
Run its `hooks/lib/ai-work-capture-v1.js` with Node and these arguments:

| Action | Arguments |
| --- | --- |
| `begin` | `--workspace` current worktree, `--session` exact session key, `--task` stable goal key, `--title` concise agreed objective, `--criteria` agreed criteria version or digest |
| `checkpoint` | `--workspace` same worktree, `--session` same session key, `--review-file` explicit result description JSON |

Pass each value as a separate quoted argument. The objective is at most 160
characters. Use a feature/revision or a new goal UUID as the task key, not a
chat-start event. Reuse the task key, objective and criteria on retries. A changed
goal/criteria needs a new key. If a specification file exists, use its SHA-256 as
the criteria version; only the digest is sent. Do not invent a fulfilled criterion.

The installed `zensu` CLI must provide `ai-work context/start/get/submit` and use a
personal `zensu auth login` OAuth grant. API keys, work-order tokens, unrelated
OAuth clients and relayed credentials are refused. Never borrow another account,
read credential files or change login automatically. Explain unavailable capture
and continue authorized coding. Keep this independent of Pulse opt-in.

The helper stores a private receipt inside this worktree's Git directory, scoped
to the host session. It writes stable IDs before requests, binds the API host and
reporting account, and keeps an interrupted submission for an exact retry. A
conflict remains visible; do not discard the receipt or overwrite another result.
No automatic historical import or worker delegation is performed.

At Stop, the hook checks only an already begun goal and submits a new clean Git
HEAD automatically. Uncommitted work and unchanged starting HEAD stay incomplete.
Before the final response, also invoke `checkpoint` after the final commit so its
result is available to the user. Submission is a report of a concrete version,
not proof of authorship, execution time, completion, or human approval.

Include the returned `reviewUrl` in the handoff. The human uses that authenticated
web dialog to accept the exact version, or revoke it later. Never call acceptance
from the reporter, infer it from "done"/merge/release, or open/operate the decision
dialog on the user's behalf without their explicit instruction. A later result
does not inherit acceptance. A stale review link cannot decide the newer result.

Account attribution is an authenticated reporting account. It is not evidence
that the human personally wrote the code. Both dashboard scopes show the same
canonical unit; personal roles do not duplicate organization totals or credits.


## Declared source and run purpose

The reporter supplies its plugin name and packaged version automatically. These
are client declarations; personal OAuth authenticates the reporting account,
not the host or authorship. Use `--run-kind work` (the default) for normal product
implementation, including writing/running tests. Use `--run-kind test` explicitly
when the goal itself is a validation, demo or capture probe. Never guess from the
title, test commands or a green suite. Preserve the agreed purpose on retries.

New receipts freeze source, version and initial purpose before the first request.
An upgrade preserves existing receipt metadata; a receipt without confirmed product scope cannot resume automatic reporting. Historical receipts keep missing
metadata unknown; do not rewrite or delete them to force attribution. Purpose
corrections belong to the current owner/admin in the web UI, with a reason; the
reporter cannot classify, accept or revoke. Both dashboard scopes exclude declared
tests by default but offer an include-tests switch. Unknown records remain visible.
Billing credits stay separately unfiltered because they are not linked to runs.

Requires a CLI supporting the `ai-work start --source --source-version --run-kind`
flags and a backend supporting run metadata. Upgrade backend and CLI before the
plugin. Missing support is an incomplete capture, never a silent fallback. The
internal `--legacy-metadata` flag only replays pre-metadata receipts unchanged.

## Explain the result before human acceptance

Before the final checkpoint, write an explicit review JSON file and pass its path
with `--review-file`. This sends authored result descriptions to the selected API
host in addition to capture metadata; stay within the user's approved disclosure
scope. Never copy transcripts, diffs, credentials or private tool output. State
what changed, the agreed acceptance criteria, actual check results and remaining
limitations. Do not invent a passed check. The file is limited to 32 KiB:

```json
{
  "summary": "Added version-bound review details to the acceptance dialog.",
  "artifactUrl": "https://git.example.test/team/repo/commit/0123456789012345678901234567890123456789",
  "acceptanceCriteria": [
    {"text": "The reviewer sees implementation, criteria and evidence.", "status": "met"},
    {"text": "Manual production validation", "status": "not_checked"}
  ],
  "evidence": [
    {"label": "Focused tests", "description": "18 tests passed locally."},
    {"label": "Pull request", "url": "https://github.com/example/project/pull/123"}
  ],
  "limitations": "Not deployed; production validation is pending."
}
```

Criteria statuses are `met`, `not_met`, or `not_checked`, reported by the agent.
They are never human acceptance. Use at most 20 criteria and 20 evidence entries.
Summary/limitations allow 4000 characters, criteria 1000, evidence labels 200,
and evidence URLs/descriptions 2000. An evidence entry needs a description or
an HTTP(S) URL without embedded credentials. Links are references, not fetched
or independently verified by capture.

Requires a CLI supporting `ai-work submit --review-file` and a backend supporting
`reviewDetails`. Upgrade backend, CLI, then plugin. The helper freezes the content
inside its private pending receipt, passes a temporary private file to the CLI,
and confirms the saved content. A changed file cannot rewrite a pending result;
retry the frozen submission first. A changed report at the same commit creates
a new result version and does not inherit acceptance. Stop can replay a pending
report without the original file. Without an explicit file it preserves legacy
metadata-only capture; the web dialog marks absent information rather than
reconstructing it from earlier conversations.

### Link the immutable artifact to its source system

When the exact source URL is known and its disclosure is authorized, include
optional `artifactUrl` in the explicit review file. For a commit result, use the
source system's commit page for the full checkpoint HEAD, never a branch or
pull-request URL. Keep the actual repository and host; do not infer them from a
product name or unrelated evidence. Omit the field when the URL is unknown.
The helper does not discover or transmit local Git remotes automatically.

The field accepts up to 2000 characters, HTTP(S) only, without URL credentials,
whitespace, backslashes or control characters. Self-hosted systems are supported.
The web dialog and submission history link the artifact reference to this URL;
it remains a reporter assertion, not independent provenance verification.

Upgrade the backend and typed CLI to versions supporting `artifactUrl` before
using it. The helper freezes and confirms it with all other review details;
changing the URL requires a new result and never transfers human acceptance.
Old reports without a URL stay unchanged. An unsupported server/CLI is visible
incomplete capture, never permission to silently omit the field from a retry.
