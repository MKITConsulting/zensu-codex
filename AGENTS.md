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
- `.agents/plugins/marketplace.json` — production marketplace descriptor
  (official Git repository + `./plugins/zensu` subdirectory + immutable release tag).
- `plugins/zensu/` — the plugin root (contains `.codex-plugin/plugin.json`):
  - `.codex-plugin/plugin.json` — manifest (declares skills, agents, hooks).
  - `skills/<name>/SKILL.md` — 14 skills (YAML frontmatter `name`/`description`).
  - `agents/zensu-*.toml` — 3 Codex subagents.
  - `hooks/` — lifecycle hook scripts + `hooks/lib/` shared helpers + `hooks.json`.
  - `docs/` — TDD workflow + documentation guide; `AGENTS.zensu.md` — optional conventions block.
  - `assets/` — plugin icon (`zensu-logo.svg`, square) referenced by the manifest's `interface.logo` and `interface.composerIcon`.
- `reference/` — canonical agent definitions (source of truth for the `agents/*.toml` subagents).
- `tests/run-all.sh --ci` — deterministic non-Promptfoo CI/release gate:
  `tests/smoke.sh`, every allowlisted non-Promptfoo `tests/structure/test-*.sh`,
  `evals/config-gate/run-eval.sh --self-check`, and the credential-free Session
  Control self-check.

## Local test
```bash
LOCAL_MARKET="$(mktemp -d)"
node scripts/create-local-codex-marketplace.js "$PWD" "$LOCAL_MARKET"
codex plugin marketplace add "$LOCAL_MARKET" --json
codex plugin add zensu@zensu --json   # install the exact checked-out bytes
bash tests/run-all.sh                 # local deterministic gate, including Promptfoo self-checks
bash tests/run-all.sh --ci            # deterministic non-Promptfoo CI contract
```
See `README.md` for the full Codex capability matrix (what's enforced vs advisory).

## Version bumps & releasing

The release version is one invariant across the plugin manifest, README badge,
newest `## [X.Y.Z]` CHANGELOG heading, and the marketplace source ref
`vX.Y.Z` (commit subject `chore(release): bump version to X.Y.Z`). It is
machine-enforced by `tests/structure/test-version-sync.sh`.

Releases run via the `Release` workflow (`.github/workflows/release.yml`):
dispatch it with a `version_type` (`patch`/`minor`/`major`) → the `prepare`
job runs `bash tests/run-all.sh --ci`, computes the next version from the
latest `vX.Y.Z` tag, bumps the version files together, generates the
`## [X.Y.Z]` CHANGELOG section from the conventional commits since the last
tag (git-cliff, `cliff.toml`), and pushes a `release/vX.Y.Z` branch → open +
squash-merge the PR from the printed Compare link → the `publish` job validates
the exact clean main SHA, Session Control runtime digest, version/ref invariant,
and exact-SHA asset, then publishes an immutable GitHub Release. Promptfoo and
live-model evaluations are local-only and never run in GitHub Actions. Go-live
is the successful immutable release publication; an ordinary merge never
changes the tag-pinned production install source.
