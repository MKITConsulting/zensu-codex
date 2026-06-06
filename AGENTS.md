# zensu-codex — repository guide

This repo is the **Codex CLI port** of the `zensu-claude-code` plugin (a Product
Lifecycle Manager). It packages the same behavior as a native Codex plugin:
`.codex-plugin/plugin.json` manifest, `skills/`, `agents/` (subagents), `hooks/`,
and `.mcp.json`. It installs through Codex's native plugin system
(`codex plugin marketplace add` + `codex /plugins`).

## Conventions
- **English only.** All code, comments, docs, commit messages, skill/agent
  prose, and fixtures are English. Runtime `.zensu/` artifacts are local-only and
  gitignored — never commit them.
- **Conventional commits.**
- Keep parity with upstream `zensu-claude-code`: the skills, agents, hook
  state-machine, and config schema mirror it. When porting an upstream change,
  preserve the workflow logic verbatim and adapt only the engine-specific edges
  (tool names, payload fields, plugin-root/project-dir resolution).

## Layout
The repo is a Codex plugin **marketplace**; the plugin payload lives under
`plugins/zensu/` (the layout Codex expects — `marketplace.json` points at it).
- `.agents/plugins/marketplace.json` — marketplace descriptor (`source` → `./plugins/zensu`).
- `plugins/zensu/` — the plugin root (contains `.codex-plugin/plugin.json`):
  - `.codex-plugin/plugin.json` — manifest; `.mcp.json` — the `zensu` MCP server.
  - `skills/<name>/SKILL.md` — 10 skills (YAML frontmatter `name`/`description`).
  - `agents/zensu-*.toml` — 3 Codex subagents.
  - `hooks/` — lifecycle hook scripts + `hooks/lib/` shared helpers + `hooks.json`.
  - `docs/` — TDD workflow + documentation guide; `AGENTS.zensu.md` — optional conventions block.
- `reference/` — the original Claude Code agent definitions (source of truth for ports).
- `tests/smoke.sh` — offline checks.

## Local test
```bash
codex plugin marketplace add "$PWD"   # register this checkout as a local marketplace
codex /plugins                        # install "Zensu"
bash tests/smoke.sh                   # offline checks (JSON/TOML, hook syntax, gate behavior)
```
See `README.md` for the full Claude Code → Codex mapping and fidelity matrix.
