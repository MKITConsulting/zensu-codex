---
name: zensu-pulse
description: Your Developer Journal — privacy-first session tracking that records which MCP tools you use and which features you touch (never code content). Use at the start and end of each coding session to understand your development patterns.
---

# $zensu-pulse

Your Developer Journal: privacy-first session tracking that helps you understand your development patterns.

## Prerequisites

- Zensu MCP Server connected (plugin auto-configures via `.mcp.json`)
- `ZENSU_API_KEY` environment variable set (or OAuth browser login)
- Git repository (for HEAD SHA and branch context)

## When to Use

Run this workflow at the start and end of each coding session. Pulse automatically tracks which MCP tools you use and which features you touch — never code content, only file paths and tool names.

## Phase 1: Session Start

At the beginning of your coding session:

1. Get the current git HEAD SHA: `git rev-parse HEAD`
2. Get the current branch: `git branch --show-current`
3. Call `pulse_start_session` with:
   - `head_sha`: the HEAD SHA
   - `branch`: current branch name
   - `project_path`: absolute path to the project root
   - `product_id`: (optional) Zensu product UUID if known
4. Save the returned `session_id` for use during the session

Sessions are idempotent — calling with the same `head_sha` returns the existing session, so it's safe to call multiple times.

## Phase 2: During Work (Automatic)

While you work, Zensu automatically logs each MCP tool call:
- Tool name and category
- Duration in milliseconds
- Success/failure status
- Associated feature IDs (when tools operate on features)

No manual action required. The logging middleware captures this transparently.

**Privacy controls:**
- Only structured data is logged (tool names, feature IDs, file paths)
- Code content is never recorded
- Error messages are only logged if the user has enabled `freetext_logging`
- Users can disable tracking entirely via privacy settings

## Phase 3: Session End & Review

When wrapping up your coding session:

1. Get changed files: `git diff --name-only HEAD~1` (or since session start SHA)
2. Call `pulse_end_session` with:
   - `session_id`: from Phase 1
   - `changed_files`: comma-separated list of changed file paths
3. Zensu automatically maps changed files -> features via `feature_source_files`
4. Call `pulse_session_summary` with the `session_id` to review:
   - Total duration
   - Number of tool calls
   - Which features were touched
   - Tool call breakdown by category

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
> pulse_start_session head_sha=abc123 branch=feat/auth project_path=/home/dev/myapp

# ... work on features, create revisions, run security reviews ...
# (tool calls are automatically logged)

# End of day
> pulse_end_session session_id=<id> changed_files=src/auth.go,src/auth_test.go,src/middleware.go

# Review what you accomplished
> pulse_session_summary session_id=<id>
```

## MCP Tools Used

| Tool | Phase | Purpose |
|------|-------|---------|
| `pulse_start_session` | 1 | Start session with git HEAD and branch |
| `pulse_end_session` | 3 | End session with changed file paths |
| `pulse_session_summary` | 3 | Review session activity breakdown |
