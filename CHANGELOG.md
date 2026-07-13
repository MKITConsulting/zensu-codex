# Changelog

All notable changes to `zensu-codex` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Fixed

- **witness**: Close the Codex `exec_command`/`exec` witness gap a live autopilot run exposed (empty witness log → "cross-check unavailable"). The shell matchers in `hooks.json` (PostToolUse witness + PreToolUse source-write gate) now fire for the `exec_command` function tool and the `exec` custom tool in addition to `shell`/`Bash`, anchored (`^(shell|Bash|exec_command|exec)$`) so unrelated `*exec*` tool names cannot match; command extraction is shared between the two hooks (`hooks/lib/shell-command-extract.js`) and tolerates every observed tool_input shape (`command` string/argv, `cmd`, `input`, raw-string `tool_input`); `exit=`/`tail=` are extracted from the `exec`/`exec_command` string response (`"Exit code: N … Output: …"`) only for those tools, never from a raw stdout that merely starts that way. Witness activation additionally heals headless session-id divergence: when the exact resolved session id has no active TDD state but exactly ONE active `tdd-phase-*.json` exists **and its id is `fallback_*`-shaped** (a session armed under a real thread UUID, or a git-tracked/planted state file, is never adopted), the witness records under that session's id with an `origin=<resolved id>` suffix so adopted evidence stays distinguishable from exact-match evidence; zero, multiple, or non-fallback sole-active states keep strict exact-match (concurrent-session safety). Symlinked witness dir/log targets are refused (no arbitrary-write via a planted log path). Regression net: `tests/structure/test-exec-command-witness.sh` (anchored-matcher pins, exec_command/exec payload e2e incl. negative exit and envelope-spoof guard, extraction-branch coverage, fallback-shape adoption with `origin=` tagging and line-count, non-fallback/multi-active negatives, gate denial across raw-string/`{cmd}`/`{input}`/argv shapes).

## [0.3.0] - 2026-07-12

### Changed

- **tdd** (breaking): `hooks.tddImplementation` now defaults to `false` — vanilla implementation mode is the default and strict RED→GREEN is an explicit opt-in (`true`), matching zensu-claude-code. Resolution is strict-boolean (only `true` arms the gate; absent, `false`, or non-boolean values stay vanilla) via the new `zensu_tdd_strict_enabled`. The example config, session banner/primer, plan-approved directive, and prompt reminder now describe vanilla as the default.

## [0.2.0] - 2026-07-11

### Added

- **hooks**: Port the Bash source-write gate — a `PreToolUse` (`shell`/`Bash`) guard that blocks raw shell writes (`>>`, `tee`, `sed -i`, `dd of=`) clobbering tracked source or escaping the worktree into a sibling checkout. Gated by `hooks.bashWriteGate` (default-on).
- **skills**: Port `pr-team-review` — multi-agent GitHub PR review that auto-casts a persona team, reviews in parallel (Codex subagent batch), and publishes one consolidated `gh api` review.
- **skills**: Port `autopilot` — idea → ready, validated PR autonomously (one plan gate, then build + team-review + fix + validate loop; credential-blind; never auto-merges).
- **tests**: Add the eval/e2e harness foundation — `tests/run-all.sh` gains a tri-mode gate (deterministic no-arg | `--self-check` skeletons | `--live`); a `codex exec`-driven promptfoo wrapper (`scripts/codex-promptfoo-wrapper.sh`); offline `evals/config-gate/`; `tests/e2e-{intent-router,context-nudge}/` scaffolds; and a reference live eval (`evals/tdd/`) asserting Codex follows `$zensu-tdd` end-to-end via post-run state. Node/promptfoo touch only the `--live` path; the no-arg suite stays pure bash. Opt-in `.github/workflows/evals.yml` (never runs on push).

### Fixed

- **session**: Fix the headless-codex session-id bridge the live reference eval caught (`witnessRan=false`). `zensu_session_key` hashed locale-dependent `ps -o lstart=` output, so the SessionStart hook (clean C-locale env) and agent shells (`zsh -lc`, user locale) derived different keys for the same parent process and the keyed session-id cache was written under one key and read under another — the agent fell back to `fallback_<key>`, the witness hook (payload thread id) found no active state, and no witness log was recorded. Now the key pins `LC_ALL=C`, and `zensu_resolve_session_id` gains an env tier (`CODEX_THREAD_ID` > `CLAUDE_SESSION_ID` — host-native id first, so an id inherited from an outer Claude Code session cannot hijack a nested codex run) between the explicit payload arg and the project-global `session-id-current.txt` pointer, which also protects concurrent sessions in one project from pointer clobbering. Every tier now sanitizes AND caps ids at 64 chars (NAME_MAX safety), `zensu-log.sh` defers env precedence to the resolver, and the promptfoo wrapper scrubs both id vars at the `codex exec` boundary. Regression net: `tests/structure/test-session-id-bridge.sh` (offline capture-sid → `--tdd-begin` → witness simulation incl. the dual-session clobber and dual-CLI hijack cases) plus env-tier and locale-stability cases in `test-session-id-fallback.sh`.
- **harness**: Address all 23 findings of the 9-persona PR review — the `--live` tier can no longer green-wash (real CI provisioning that fails loudly without `CODEX_AUTH`, live prereq FAILs instead of SKIP-passes, explicit placeholder NOTEs), the wrapper validates its options JSON strictly (quoted `{}` default — a bash brace-expansion quirk appended a stray `}` to every payload), purges stale fixture `.zensu` state behind symlink guards, keeps codex stderr + bounds the paid call with a timeout, and the supply chain is pinned (committed lockfile, strict `npm ci`, `npx --no-install`, SHA-pinned actions, `@openai/codex@0.142.5`).

## [0.1.0] - 2026-06-27

### Added

- **skills**: Add pr-fix-findings skill (#12)
- **self-review**: Narrative chain-end summary, every round, TL;DR last
- **hooks**: Add intent-router + tdd-reminder UserPromptSubmit hooks

### Changed

- Show vanilla mode in the workflow diagram (#11)
- Reframe zensu-codex as a standalone Codex plugin

### Fixed

- **tdd**: Drop unflippable plan checkboxes; Status column is sole completion tracker (#13)
- **ghost-scan**: Classify by data sensitivity, never default to internal
- **intent-router**: Drop stale MCP-tools phrasing after the CLI re-home (#7)

### Added

- **skills**: Port `pr-fix-findings` — resolve all open PR review comments end-to-end via the Zensu workflow, parallelize independent fixes, resolve threads on the PR, report back

## [0.0.1] - 2026-06-23

### Added

- **ci**: Add Release + CI pipelines with version-sync gate
- **tdd**: Add vanilla implementation mode (hooks.tddImplementation)
- **cli**: Re-home plugin from MCP tools to the typed zensu CLI
- **tdd**: Embed the command protocol prominently in skill and primer
- Add zensu-codex — the Zensu PLM as a native Codex CLI plugin

### Changed

- **readme**: Add agent & workflow overview Mermaid diagram
- **skills**: Codex-correct review-chain — buffer Low findings, run self-review explicitly
- Drop install.sh, install via native Codex plugin system
- Clarify hook trust-review and plugin_hooks gating

### Fixed

- **config**: Deep-merge project config over global instead of first-match shadowing
- **session**: Rank current-session pointer above transcript helper, anchor on git toplevel
- **ghost-scan**: Mint v1 baseline server-side, drop client-side Phase 5b
- **marketplace**: Move plugin into plugins/zensu with ./-prefixed local source
- **marketplace**: Use object plugin source so the local plugin resolves

## [0.2.0] - 2026-06-12

Adds **vanilla implementation mode**. (The `user-prompt-tdd-reminder.sh` mode
variants are not yet wired in.)

### Added
- **`hooks.tddImplementation` config key** (default `true` = strict RED→GREEN,
  unchanged behavior). `false` switches the `$zensu-tdd` workflow to **vanilla
  mode**: no RED→GREEN ceremony, no FSM phase markers, the PreToolUse edit gate
  passes through, tests at the agent's discretion — while plan/log artifacts,
  the Phase 5/6 evidence audits (build, coverage, witness cross-check), the
  review fan-out → `zensu-code-reviewer` → `$zensu-self-review` chain, and the
  Stop-hook guarantee stay fully enforced.
- **Per-session mode freeze** — `zensu-log.sh --tdd-begin` reads the config
  once, persists the `vanilla` flag into the session state, and echoes
  `mode: strict|vanilla`; hooks read only the frozen state flag, never live
  config. New `--mode` query verb echoes the frozen mode.
- **Session-state hardening** — while a session is active the gate denies edits
  to `.zensu/state/` in BOTH modes, classifying every file in the patch on its
  normalized path (dot-segments, duplicate slashes, case folding, traversal,
  resolved `TDD_STATE_DIR`), so the vanilla bypass cannot be used to
  self-un-gate; `.zensu/plans/`+`.zensu/logs/` exemptions preserved.
- **Mode-aware surfaces** — session banner/primer, the plan-approved and
  post-review reference hooks (kept in heredoc-parity lockstep), the
  `$zensu-tdd` skill (`## Vanilla Implementation Mode` deltas + Phase 0 mode
  echo), `$zensu-self-review` (`--mode` probe, direct fix round), and
  `$zensu-implement`. Ask flows keep asking, worded "Zensu workflow (vanilla
  implementation + review chain)".
- **Smoke coverage** — `tests/smoke.sh` gains hermetic vanilla-mode sections
  (state-lib plumbing, begin echo/persist/freeze, `--mode`, gate bypass +
  state-path deny spellings, witness + Stop-chain invariance, wording pins,
  heredoc parity, content pins) and pins `ZENSU_CONFIG` so the runner's real
  `~/.zensu/config.json` cannot bleed into the suite.

### Changed
- `zensu-tdd-phase.sh` state writers preserve unknown flags across `--phase`
  rebuilds (preserve-all); `--tdd-reset` also clears the `vanilla` flag;
  `tdd_set_flag` rejects non-boolean or empty values instead of coercing to
  `true`.
- `stop-chain-enforcer.sh` fix-round directives follow the session's frozen
  mode (strict: under the gate; vanilla: fix directly, keep the evidence
  discipline). On Codex the Stop hook is the only wired carrier of the
  mode-aware fix discipline (`post-review-tdd-delegate.sh` never fires).

### Fixed
- The pre-edit gate's envelope scan for `*** Update/Add/Delete File:` markers
  now runs only for `apply_patch` payloads (or when no `file_path` was found),
  so Claude-style `Edit`/`Write` payloads whose CONTENT embeds patch-envelope
  examples no longer inject phantom paths (corrects 0.1.0 behavior).
- `zensu-log.sh` arg loops are shift-safe (`shift 2 || break`) — dangling
  `--session`/`--step`/`--reason` values no longer spin the parser.
- State writers recover from array-shaped (corrupt) state files instead of
  silently dropping flags.
- Path-classifier hardening: the pre-edit gate validates its path classifier's
  output and falls back to a conservative normalized-textual state-deny when
  node fails mid-flight; leaf symlinks (including dangling ones and chains) and
  hard-link aliases of state files are resolved before classification.
- `--tdd-begin` writes the mode flag BEFORE the `active` flag and aborts
  without activating when that write fails, so a session can never come up
  active under the wrong discipline (fail-closed activation).

## [0.1.0] - 2026-06-06

Initial release of `zensu-codex` — the Zensu PLM packaged as a native Codex
plugin and wired into the stable Codex surfaces.

### Added
- **Codex plugin manifest** — `.codex-plugin/plugin.json` (skills, hooks,
  mcpServers, interface) plus `.agents/plugins/marketplace.json` for local
  marketplace install.
- **MCP server** — `.mcp.json` registers the `zensu` streamable-HTTP server
  (`https://mcp.zensu.dev/mcp`); installer uses `codex mcp add` with OAuth by
  default or `--bearer-token-env-var ZENSU_API_KEY` for CI.
- **10 skills** (`skills/*/SKILL.md`) with Codex YAML frontmatter, invoked as
  `$zensu-bootstrap`, `$zensu-ghost-scan`, `$zensu-implement`, `$zensu-tdd`,
  `$zensu-plan-review`, `$zensu-security-review`, `$zensu-self-review`,
  `$zensu-reset-review-limit`, `$zensu-pulse`, `$zensu-help`.
- **3 subagents** (`agents/*.toml`): `zensu-plm`, `zensu-code-reviewer`,
  `zensu-review-aspect` (the last runs under a `read-only` sandbox).
- **Lifecycle hooks** adapted to Codex tool/event shapes: the PreToolUse TDD
  phase-gate now parses the freeform `apply_patch` envelope (multi-file aware)
  in addition to `Edit`/`Write`/`MultiEdit`; the witness matches the `shell`
  tool; SessionStart banner/primer reworded for Codex; engine-neutral plugin-root
  and project-dir resolution via `hooks/lib/zensu-runtime.sh`.
- **`AGENTS.zensu.md`** — an optional Zensu-conventions block you can append to
  `~/.codex/AGENTS.md`, carrying the plan→ask-TDD and review-chain directives
  (also delivered at runtime by the session-start primer hook when hooks are on).
- **Native install** — the plugin installs through Codex's own plugin system
  (`codex plugin marketplace add <dir|owner/repo>` → `codex /plugins`); the MCP
  server, skills, subagents, and hooks register from `.codex-plugin/plugin.json`.
  Lifecycle hooks require enabling `plugin_hooks` and trusting them via `/hooks`.
- **Docs** — `README.md` (full reference + Codex capability matrix),
  `docs/tdd-manager-workflow.md`, `docs/documentation-guide.md`.

### Codex conventions
- Manifest at `.codex-plugin/plugin.json`; skills invoked as `$zensu-x`;
  subagents referenced as `zensu-code-reviewer` / `zensu-review-aspect`; plan
  tracking via Codex `update_plan`; user questions asked inline.

### No matching Codex event (behavior preserved as convention)
- `plan-approved-delegate.sh` (plan-approval) → carried by `AGENTS.md` + the
  session-start primer.
- `post-review-tdd-delegate.sh` auto-fix loop (subagent completion) → driven by
  the `$zensu-tdd` skill prose, backstopped by the Stop chain-enforcer. Both
  scripts are retained as the canonical reference implementation.

### Known limitations on Codex 0.130.0
- The `Stop` chain-enforcer cannot hard-block turn end (advisory, not enforced).
- The `UserPromptSubmit` context-nudge parser is Claude-transcript-shaped and is
  likely inert until adapted to Codex's rollout format.
- Plugin-bundled hooks are gated behind the `plugin_hooks` feature flag (under
  development / off by default on 0.130.0; verified via `codex features list` and
  openai/codex PR #19705), so a native marketplace install does not run the hooks.
  The installer wires the stable `~/.codex/hooks.json` surface instead.
- Hook trust-review: Codex skips any non-managed hook (user/project/plugin) until
  the user reviews and trusts it via the `/hooks` TUI command (trust is keyed to
  the hook's content hash). Both install paths therefore need a one-time
  `/hooks` → Trust before the hooks run; only managed `requirements.toml` hooks
  are exempt. When plugin hooks do run, Codex injects `CLAUDE_PLUGIN_ROOT` into
  the hook env, which the hooks already honor.
