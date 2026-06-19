# Changelog

All notable changes to `zensu-codex` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to track
parity with upstream [`zensu-claude-code`](https://github.com/MKITConsulting/zensu-claude-code).

## [Unreleased]

### Changed

- **Re-home the plugin from the MCP server to the typed `zensu` CLI** (parity with upstream [`zensu-claude-code` #117](https://github.com/MKITConsulting/zensu-claude-code/pull/117)). The plugin now drives Zensu through the GitHub-CLI-style `zensu <noun> <verb>` binary (≥ 0.2.0; verified against the installed 0.3.0) instead of the 74-tool hosted MCP server, reclaiming ~22k context tokens per request. The hosted MCP server at `mcp.zensu.dev` stays live for the Zensu web app's own AI assistant — it is just no longer wired into the plugin.
- **All 10 skills + the `zensu-plm` agent now call `zensu` CLI commands** instead of MCP tools. Prerequisites updated to "install the CLI (`curl -fsSL https://zensu.dev/install.sh | sh`) + `zensu auth login`"; "MCP Tools Used" tables renamed to "CLI Commands Used"; MCP-prompt sections dropped (no CLI equivalent). Codex-specific formats preserved (`$zensu-` invocation, YAML frontmatter, `.toml` agents, Codex multi-agent fan-out).
- **Session banner** now warns when the `zensu` CLI is not on `PATH` (`session-start-banner.sh`), with install + `zensu auth login` hints.
- **Docs** (`README.md`, `AGENTS.md`, `plugins/zensu/AGENTS.zensu.md`, `plugins/zensu/docs/documentation-guide.md`): install via `curl … zensu.dev/install.sh`, auth via `zensu auth login` (OAuth2+PKCE; `--with-token zsk_…` for CI), self-hosting via `--api-url` / `ZENSU_API_URL`, plus a new **Troubleshooting** section. `zensu-help` topic routing repinned to the CLI surface.
- **`tests/smoke.sh`**: dropped the `.mcp.json` JSON-validity check; added a "CLI migration" section asserting `.mcp.json` is gone, `plugin.json` has no `mcpServers` key, agents declare no `mcp_servers`, no `mcp__` refs remain in skills/agents, and the mutating skills drive the `zensu` CLI.

### Removed

- **`plugins/zensu/.mcp.json`** and the **`mcpServers`** key (+ the stale `"mcp"` keyword) from `plugins/zensu/.codex-plugin/plugin.json`. The plugin no longer registers an MCP server.

### Notes — intentional divergences from `zensu-claude-code` #117

- **The PreToolUse write-gate is intentionally NOT ported (deferred).** #117 added a `PreToolUse(Bash)` gate that denies freelance `zensu` mutations outside a skill/agent workflow. On Codex this cannot enforce: verification against Codex 0.137.0 showed `PreToolUse(shell)` does **not** fire reliably for `zensu` commands (empirically a trusted-plugin `PreToolUse(shell)` hook did not fire while `PostToolUse(shell)` did; `codex exec` forces `approval: never`; the official docs note shell interception via `unified_exec` is incomplete), and Codex hook payloads carry no `agent_type`, so the upstream `zensu-plm` exemption has no equivalent. Codex still steers work through the workflow via the session primer, the `zensu-plm` delegation convention, and the planning/TDD hooks. Follow-up: revisit a `PostToolUse`-based advisory check, or a `PreToolUse` gate, once Codex's shell interception stabilizes.
- **No `--workflow-begin --tools` preamble in the skills.** Upstream skills declare a workflow tool-allowlist for the gate to consume; with the gate deferred (and no workflow-state machinery in Codex's `zensu-log.sh`), that preamble would call non-existent flags, so it is omitted.
- **CLI flag corrections for v0.3.0** (where #117's skill text had drifted): `zensu features list` has no `--compact`; `zensu security review` uses `--type` (not `--review-type`); `zensu ghost batch` uses `--approve-ids` / `--reject-ids`; `zensu products bootstrap-step` takes a positional `<step>` (not `--step`).

## [0.1.1] - 2026-06-07

### Changed

- **Install is now native** — removed `install.sh`/`uninstall.sh`; install via Codex's own plugin system (`codex plugin marketplace add <dir|owner/repo>` → `codex /plugins`). The MCP server, skills, subagents, and hooks register from `.codex-plugin/plugin.json`.
- **Marketplace layout fixed** — moved the plugin into `plugins/zensu/` and set the marketplace `source` to `{ "source": "local", "path": "./plugins/zensu" }` (object form, `./`-prefixed, plugin in its own subdir). The prior root-level string source resolved to zero plugins ("No plugins available in this marketplace").
- **`$zensu-tdd` review chain made Codex-correct** — route findings strictly by severity (Critical/Important → fix + re-review; Suggestion/Minor/Nit/Low → buffer into the report, never re-review unless `hooks.autoFixIncludeSuggestions=true`); invoke `$zensu-self-review` as an explicit, mandatory terminal step (no auto-start hook on Codex); honest framing that the Stop hook only reminds and cannot hard-block on Codex.
- **TDD command protocol** embedded prominently in the skill + session-start primer.
- **`/zensu:ghost-scan` no longer creates the v1 baseline revision client-side — it is minted server-side by `ghost_apply` (zensu-monorepo #266).** Removed Phase 5b from the ghost-scan skill (replaced with a server-side note), dropped the agent's ghost-scan baseline workflow step + Important Rule, and removed the `create_revision` row from the skill's MCP-tools table. Keeping the client step would 400 against a #266 backend (its baseline is `planned`; `create_revision` requires the prior revision `released`/`superseded`). Ported from zensu-claude-code #109; release-coupled to the #266 deploy.

### Docs

- Documented the hook **trust-review** (`/hooks` → Trust is required before any non-managed hook runs) and the `plugin_hooks` feature-flag gating (under development on Codex 0.130.0, so plugin-bundled hooks are off by default); noted `CLAUDE_PLUGIN_ROOT` env-injection compatibility (openai/codex PR #19705).

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
