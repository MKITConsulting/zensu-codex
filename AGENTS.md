# zensu-codex — repository guide

This repo is the **Codex CLI port** of the `zensu-claude-code` plugin (a Product
Lifecycle Manager). It packages the same behavior as a native Codex plugin:
`.codex-plugin/plugin.json` manifest, `skills/`, `agents/` (subagents), `hooks/`,
and `.mcp.json`, plus an `install.sh` that wires the stable Codex surfaces.

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
- `.codex-plugin/plugin.json` — Codex plugin manifest.
- `.agents/plugins/marketplace.json` — local marketplace descriptor.
- `.mcp.json` — the `zensu` HTTP MCP server.
- `skills/<name>/SKILL.md` — 10 skills (YAML frontmatter `name`/`description`).
- `agents/zensu-*.toml` — 3 Codex subagents.
- `hooks/` — lifecycle hook scripts + `hooks/lib/` shared helpers + `hooks.json`.
- `AGENTS.zensu.md` — the conventions block `install.sh` appends to `~/.codex/AGENTS.md`.
- `docs/` — TDD workflow + documentation guide.
- `reference/` — the original Claude Code agent definitions (source of truth for ports).
- `install.sh` / `uninstall.sh`.

## Local test
```bash
./install.sh                 # wire into ~/.codex (idempotent)
bash tests/smoke.sh          # offline checks (JSON/TOML, hook syntax, gate behavior)
```
See `README.md` for the full Claude Code → Codex mapping and fidelity matrix.
