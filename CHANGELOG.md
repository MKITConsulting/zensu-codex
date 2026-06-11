# Changelog

All notable changes to `zensu-codex` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to track
parity with upstream [`zensu-claude-code`](https://github.com/MKITConsulting/zensu-claude-code).

## [Unreleased]

### Changed

- **`/zensu:ghost-scan` no longer creates the v1 baseline revision client-side — it is minted server-side by `ghost_apply` (zensu-monorepo #266).** Removed Phase 5b from the ghost-scan skill (replaced with a server-side note), dropped the agent's ghost-scan baseline workflow step + Important Rule, and removed the `create_revision` row from the skill's MCP-tools table. Keeping the client step would 400 against a #266 backend (its baseline is `planned`; `create_revision` requires the prior revision `released`/`superseded`). Ported from zensu-claude-code #109; release-coupled to the #266 deploy.

## [0.2.0] - 2026-06-12

Port of the upstream **vanilla implementation mode** (zensu-claude-code PR #112).
Not ported from #112: the `user-prompt-tdd-reminder.sh` mode variants — that
hook (upstream #107) is not yet present in this port; port both together.

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
  rebuilds (preserve-all, ported from #112); `--tdd-reset` also clears the
  `vanilla` flag (ported); `tdd_set_flag` rejects non-boolean or empty values
  instead of coercing to `true` (Codex-local, not in #112 — upstreaming
  candidate).
- `stop-chain-enforcer.sh` fix-round directives follow the session's frozen
  mode (strict: under the gate; vanilla: fix directly, keep the evidence
  discipline). Codex-local divergence from #112, which left this hook
  mode-blind: on Codex the Stop hook is the only wired carrier of the
  mode-aware fix discipline (`post-review-tdd-delegate.sh` never fires) —
  upstreaming candidate.

### Fixed
- The pre-edit gate's envelope scan for `*** Update/Add/Delete File:` markers
  now runs only for `apply_patch` payloads (or when no `file_path` was found),
  so Claude-style `Edit`/`Write` payloads whose CONTENT embeds patch-envelope
  examples no longer inject phantom paths (corrects 0.1.0 behavior;
  Codex-local hardening).
- `zensu-log.sh` arg loops are shift-safe (`shift 2 || break`) — dangling
  `--session`/`--step`/`--reason` values no longer spin the parser (ported
  from #112).
- State writers recover from array-shaped (corrupt) state files instead of
  silently dropping flags (ported from #112).
- Codex-local hardening beyond #112 (introduced with this release's classifier;
  upstreaming candidates): the pre-edit gate validates its path classifier's
  output and falls back to a conservative normalized-textual state-deny when
  node fails mid-flight; leaf symlinks (including dangling ones and chains) and
  hard-link aliases of state files are resolved before classification.
- `--tdd-begin` writes the mode flag BEFORE the `active` flag and aborts
  without activating when that write fails, so a session can never come up
  active under the wrong discipline (Codex-local, fail-closed activation —
  upstreaming candidate; upstream #112 warns and stays active).
## [0.1.0] - 2026-06-06

Initial Codex CLI port of `zensu-claude-code` v0.8.0. Behavior parity, packaged
as a native Codex plugin and wired into the stable Codex surfaces.

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
- **Docs** — `README.md` (full reference + Claude Code → Codex fidelity matrix),
  `docs/tdd-manager-workflow.md`, `docs/documentation-guide.md`.

### Changed (vs upstream)
- Manifest path `.claude-plugin/` → `.codex-plugin/`; skill invocation
  `/zensu:x` → `$zensu-x`; subagent refs `zensu:code-reviewer` →
  `zensu-code-reviewer`; `TaskCreate`/`TaskUpdate` → Codex `update_plan`;
  `AskUserQuestion` → ask inline.

### Not ported (no Codex event; behavior preserved as convention)
- `plan-approved-delegate.sh` (Claude `ExitPlanMode`) → moved to `AGENTS.md` +
  the session-start primer.
- `post-review-tdd-delegate.sh` auto-fix loop (Claude `PostToolUse` on subagent
  completion) → driven by the `$zensu-tdd` skill prose, backstopped by the Stop
  chain-enforcer. Both scripts are retained for reference / Claude Code compat.

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
  the hook env, which the ported hooks already honor.
