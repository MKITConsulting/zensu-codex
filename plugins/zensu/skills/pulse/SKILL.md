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
- The CLI must support `zensu pulse start --minimal-json`. If that flag is unavailable, stop with upgrade guidance; never fall back to raw `--json`.

## When to Use

Run this workflow at the start and end of each coding session. Pulse records your session boundaries and which features you touch — never code content, only file paths and session metadata.

## Phase 1: Session Start

At the beginning of your coding session:

1. Obtain the exact start commit before calling the CLI. Run it as its own read-only invocation so the exact stdout is visible to the agent:

   ```bash
   git rev-parse --verify 'HEAD^{commit}'
   ```

   Require exactly 40 lowercase hexadecimal characters (`^[0-9a-f]{40}$`). Retain that exact value in the agent's working context and stop if the read or validation fails.
2. In a new invocation, assign only that validated hex token to `PULSE_START_SHA`. Capture free-form repository values locally and pass every value as one quoted argument; never copy branch or path output into shell source:

   ```bash
   PULSE_START_SHA='<validated 40-character SHA from the preceding read>'
   BRANCH="$(git branch --show-current)"
   PROJECT_ROOT="$(git rev-parse --show-toplevel)"
   zensu pulse start --minimal-json \
     --head-sha "$PULSE_START_SHA" \
     --branch "$BRANCH" \
     --project "$PROJECT_ROOT"
   ```

   If a product is known, assign its canonical UUID to `PRODUCT_ID` and append `--product "$PRODUCT_ID"` in that same invocation.
3. Inspect the JSON response:
   - If `status` is `tracking_disabled`, tell the user that server-side Pulse tracking is disabled and stop this workflow successfully. Do not save a session ID and do not run `pulse end` or `pulse summary` later.
   - Otherwise require a non-empty canonical UUID in `id` and retain it in the agent's working context for use during the session; retain the full start HEAD SHA alongside it so Phase 3 can diff the complete session. Treat the UUID and SHA as opaque data and never invent, infer, or persist an empty session ID. Do not assume shell variables persist between agent command invocations; reassign the remembered values inside every later invocation and double-quote their expansions.

Sessions are idempotent — calling with the same `--head-sha` returns the existing session, so it's safe to call multiple times.

## Phase 2: During Work

Work as normal. Pulse captures the session at its boundaries (start in Phase 1, end in Phase 3) — there is no per-command logging step to run. At session end the changed files you report are mapped to the features they touch.

**Privacy controls:**
- Only structured data is recorded (session metadata, feature IDs, file paths)
- Code content is never recorded
- Error messages are only logged if the user has enabled `freetext_logging`
- Users can disable tracking entirely via privacy settings
- The server-side privacy setting is authoritative. The local `hooks.pulseSession` flag only controls the host's startup context and never overrides server consent.
- Do not add a privacy preflight request or local consent cache. The command response is the single client decision point.
- `--minimal-json` exposes only `id` or `status`; do not use raw `--json` for agent session boundaries because it may include user, organization, path, and activity metadata.

## Phase 3: Session End & Review

This phase runs only when Phase 1 stored a non-empty session ID and the full start HEAD SHA. If no session was created, skip the entire phase.

When wrapping up your coding session:

1. Recover the validated UUID and full start HEAD SHA from the agent's working context; do not rely on variables from an earlier shell call.
2. Capture tracked changes since the remembered start SHA and currently untracked, non-ignored files with NUL delimiters. Check both Git commands before invoking the CLI: if either discovery step fails, abort without ending the session. Pass each path with its own quoted `--changed-file` argument so commas and surrounding spaces remain part of the filename. The backend deliberately rejects control characters such as newlines:

   ```bash
   PULSE_SESSION_ID='<canonical UUID remembered in agent context>'
   PULSE_START_SHA='<validated full start HEAD SHA remembered in agent context>'
   CHANGED_FILES_FILE="$(mktemp)" || exit 1
   trap 'rm -f -- "$CHANGED_FILES_FILE"' EXIT
   if ! git diff --name-only -z "$PULSE_START_SHA" -- > "$CHANGED_FILES_FILE"; then
     printf '%s\n' 'Unable to collect tracked changed files; Pulse session was not ended.' >&2
     exit 1
   fi
   if ! git ls-files --others --exclude-standard --full-name -z >> "$CHANGED_FILES_FILE"; then
     printf '%s\n' 'Unable to collect currently untracked files; Pulse session was not ended.' >&2
     exit 1
   fi
   CHANGED_FILE_ARGS=()
   while IFS= read -r -d '' CHANGED_FILE; do
     CHANGED_FILE_ARGS+=(--changed-file "$CHANGED_FILE")
   done < "$CHANGED_FILES_FILE"
   zensu pulse end "$PULSE_SESSION_ID" "${CHANGED_FILE_ARGS[@]}" --minimal-json
   ```

3. Inspect the JSON response. If `status` is `tracking_disabled`, report the successful privacy no-op and stop; do not run `pulse summary`.
4. Zensu automatically maps changed files -> features via `feature_source_files`
5. In a separate shell invocation, reassign the same remembered UUID before running the summary:

   ```bash
   PULSE_SESSION_ID='<same canonical UUID remembered in agent context>'
   zensu pulse summary "$PULSE_SESSION_ID"
   ```

   Review:
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

Use the same value-provenance rules as the canonical phases. First make the start commit visible:

```bash
git rev-parse --verify 'HEAD^{commit}'
```

After validating exactly 40 lowercase hexadecimal characters, use that remembered value in a new invocation:

```bash
PULSE_START_SHA='<validated 40-character SHA from the preceding read>'
BRANCH="$(git branch --show-current)"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
zensu pulse start --head-sha "$PULSE_START_SHA" --branch "$BRANCH" --project "$PROJECT_ROOT" --minimal-json
```

If the response contains a real session ID, work normally. Run the canonical Phase 3 workflow above: it reassigns that ID and the exact remembered start SHA, checks NUL-delimited tracked and untracked Git discovery before ending, and runs the summary only after a successful enabled-session end. Do not replace it with a recomputed HEAD or a separate manual end example.

## CLI Commands Used

| Command | Phase | Purpose |
|---------|-------|---------|
| `zensu pulse start --minimal-json` | 1 | Start a session or detect the server-side privacy no-op without exposing unrelated metadata |
| `zensu pulse end "$PULSE_SESSION_ID" --minimal-json` | 3 | End a real session or detect a mid-session privacy opt-out without exposing unrelated metadata |
| `zensu pulse summary "$PULSE_SESSION_ID"` | 3 | Review session activity breakdown for the validated session |
