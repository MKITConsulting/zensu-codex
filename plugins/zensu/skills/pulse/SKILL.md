---
name: zensu-pulse
description: Your Developer Journal — privacy-first session tracking that records your session boundaries and which features you touch (never code content). Use at the start and end of each coding session to understand your development patterns.
---

# $zensu-pulse

Your Developer Journal: privacy-first session tracking that helps you understand your development patterns.

## Prerequisites

- Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`) and on `PATH`
- Authenticated: `zensu auth login` (check with `zensu auth status`)
- Git repository (for HEAD SHA and branch context)

## When to Use

Run this workflow at the start and end of each coding session. Pulse records your session boundaries and which features you touch — never code content, only file paths and session metadata.

## Phase 1: Session Start

At the beginning of your coding session:

1. Get the current git HEAD SHA: `git rev-parse HEAD`
2. Get the current branch: `git branch --show-current`
3. Run `zensu pulse start` with:
   - `--head-sha`: the HEAD SHA
   - `--branch`: current branch name
   - `--project`: absolute path to the project root
   - `--product`: (optional) Zensu product UUID if known
4. Save the returned `session_id` for use during the session

Sessions are idempotent — calling with the same `--head-sha` returns the existing session, so it's safe to call multiple times.

## Phase 2: During Work

Work as normal. Pulse captures the session at its boundaries (start in Phase 1, end in Phase 3) — there is no per-command logging step to run. At session end the changed files you report are mapped to the features they touch.

**Privacy controls:**
- Only structured data is recorded (session metadata, feature IDs, file paths)
- Code content is never recorded
- Error messages are only logged if the user has enabled `freetext_logging`
- Users can disable tracking entirely via privacy settings

## Phase 3: Session End & Review

When wrapping up your coding session:

1. Get changed files: `git diff --name-only HEAD~1` (or since session start SHA)
2. Run `zensu pulse end <session-id>` with:
   - `--changed-files`: comma-separated list of changed file paths
3. Zensu automatically maps changed files -> features via `feature_source_files`
4. Run `zensu pulse summary <session-id>` to review:
   - Total duration
   - Activity recorded
   - Which features were touched

## Privacy First

Pulse is designed as "Your Developer Journal" — personal and private by default:

- **Tracking**: Can be disabled entirely (no data recorded)
- **Freetext**: Error messages stripped unless explicitly opted in
- **Team visibility**: Off by default — your sessions are only visible to you
- **Retention**: Data auto-expires after 90 days (configurable)

Manage privacy settings via the Zensu web UI or API.

## Example Session Flow

```
# Start of day
> zensu pulse start --head-sha abc123 --branch feat/auth --project /home/dev/myapp

# ... work on features, create revisions, run security reviews ...

# End of day
> zensu pulse end <session-id> --changed-files src/auth.go,src/auth_test.go,src/middleware.go

# Review what you accomplished
> zensu pulse summary <session-id>
```

## CLI Commands Used

| Command | Phase | Purpose |
|---------|-------|---------|
| `zensu pulse start` | 1 | Start session with git HEAD and branch |
| `zensu pulse end` | 3 | End session with changed file paths |
| `zensu pulse summary` | 3 | Review session activity breakdown |
