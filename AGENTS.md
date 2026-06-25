# zensu-codex — repository guide

This repo is **Zensu for Codex** — the Zensu Product Lifecycle Manager packaged
as a native Codex CLI plugin: `.codex-plugin/plugin.json` manifest, `skills/`,
`agents/` (subagents), and `hooks/`. It installs through Codex's native plugin
system (`codex plugin marketplace add` + `codex /plugins`) and drives Zensu
through the typed [`zensu` CLI](https://zensu.dev) (the hosted MCP server is no
longer wired into the plugin).

## Conventions
- **English only.** All code, comments, docs, commit messages, skill/agent
  prose, and fixtures are English. Runtime `.zensu/` artifacts are local-only and
  gitignored — never commit them.
- **Conventional commits.**
- The skills, agents, hook state-machine, and config schema carry the Zensu
  workflow logic. When changing a workflow, keep that logic consistent across
  the skill prose, hooks, and subagents, and confine engine-specific edges (tool
  names, payload fields, plugin-root/project-dir resolution) to the adapters.

## Layout
The repo is a Codex plugin **marketplace**; the plugin payload lives under
`plugins/zensu/` (the layout Codex expects — `marketplace.json` points at it).
- `.agents/plugins/marketplace.json` — marketplace descriptor (`source` → `./plugins/zensu`).
- `plugins/zensu/` — the plugin root (contains `.codex-plugin/plugin.json`):
  - `.codex-plugin/plugin.json` — manifest (declares skills, agents, hooks).
  - `skills/<name>/SKILL.md` — 10 skills (YAML frontmatter `name`/`description`).
  - `agents/zensu-*.toml` — 3 Codex subagents.
  - `hooks/` — lifecycle hook scripts + `hooks/lib/` shared helpers + `hooks.json`.
  - `docs/` — TDD workflow + documentation guide; `AGENTS.zensu.md` — optional conventions block.
- `reference/` — canonical agent definitions (source of truth for the `agents/*.toml` subagents).
- `tests/run-all.sh` — deterministic test gate (CI + release): `tests/smoke.sh`
  plus every `tests/structure/test-*.sh`.

## Local test
```bash
codex plugin marketplace add "$PWD"   # register this checkout as a local marketplace
codex /plugins                        # install "Zensu"
bash tests/run-all.sh                 # deterministic gate (smoke + structure suites)
```
See `README.md` for the full Codex capability matrix (what's enforced vs advisory).

## Version bumps & releasing

The version lives in three places that must carry the same value in the same
commit: `plugins/zensu/.codex-plugin/plugin.json`, the README version badge,
and the newest `## [X.Y.Z]` CHANGELOG heading (commit subject
`chore(release): bump version to X.Y.Z`). Machine-enforced by
`tests/structure/test-version-sync.sh`. The marketplace descriptor carries no
version field, so it is exempt.

Releases run via the `Release` workflow (`.github/workflows/release.yml`):
dispatch it with a `version_type` (`patch`/`minor`/`major`) → the `prepare`
job runs the deterministic test gate, computes the next version from the
latest `vX.Y.Z` tag, bumps the version files together, generates the
`## [X.Y.Z]` CHANGELOG section from the conventional commits since the last
tag (git-cliff, `cliff.toml`), and pushes a `release/vX.Y.Z` branch → open +
squash-merge the PR from the printed Compare link → the `publish` job tags
main HEAD and publishes the GitHub Release (notes = the new CHANGELOG
section). Go-live is the merge itself — users install from main HEAD. For a
manual hotfix, follow the invariant by hand.
