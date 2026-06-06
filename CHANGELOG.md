# Changelog

All notable changes to `zensu-codex` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to track
parity with upstream [`zensu-claude-code`](https://github.com/MKITConsulting/zensu-claude-code).

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
- **`AGENTS.zensu.md`** — persistent Zensu conventions appended to
  `~/.codex/AGENTS.md`, carrying the plan→ask-TDD and review-chain directives.
- **`install.sh` / `uninstall.sh`** — idempotent wiring of the stable surfaces
  (`codex mcp add`, `~/.codex/skills`, `~/.codex/agents`, merged
  `~/.codex/hooks.json` with absolute paths, guarded `AGENTS.md` block,
  `~/.zensu/config.json` seed).
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
