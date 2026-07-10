# evals/tdd — reference live eval

Proves **Codex follows `$zensu-tdd` end-to-end** by driving a real `codex exec`
session (via `scripts/codex-promptfoo-wrapper.sh`) through the `add-feature`
fixture and asserting on the plugin's **post-run state**, not on model prose.

- `promptfooconfig.yaml` — promptfoo config; provider = the codex-exec wrapper,
  `working_dir` = `test-projects/add-feature`.
- `scenarios/tdd-happy.yaml` — spec + a deterministic `javascript` assertion on the
  wrapper-flattened state: `chainDone=true` + a witness `BASH cmd=` line (a test
  actually ran). `RED_FAIL`/`GREEN_PASS` are strict-mode-only FSM markers reported
  as bonus signal (vanilla mode writes no phase markers).
- `test-projects/add-feature/` — a minimal empty Node project (`node --test`).

## Run

- Structure only (no API): `bash run.sh --self-check` — also runs in
  `tests/run-all.sh --self-check`.
- Live (COSTS API credits, needs `codex` authed + `promptfoo`/`npx`):
  `bash run.sh` or `bash tests/run-all.sh --live`.

## Prerequisites for the live run

- **Trust warning — the live run is UNSANDBOXED.** The wrapper invokes
  `codex exec --dangerously-bypass-approvals-and-sandbox`, so the model-driven
  agent executes arbitrary commands with your full user privileges; `-C` only
  sets the working dir, it contains nothing. Run live evals ONLY against
  fixtures you wrote yourself — a hostile fixture (`AGENTS.md` prompt
  injection) has whole-host blast radius. `codex` is resolved from `PATH`.
  The paid call is bounded by `ZENSU_CODEX_EXEC_TIMEOUT` (default 1800s, needs
  a `timeout`/`gtimeout` binary) and its stderr lands in
  `<isolated-dir>/.codex-stderr.log` (kept with `KEEP_ISOLATED=1`).
- promptfoo resolves repo-local first (`node_modules/.bin/promptfoo` via the
  committed lockfile — `npm ci`), then a global install, then
  `npx --no-install`; there is deliberately NO registry-latest fallback.
- `codex login --device-auth` (or a service `CODEX_HOME` with cached auth).
- To eval the **worktree** plugin (not the installed one), set
  `ZENSU_CODEX_HOME_OVERRIDE` to a `CODEX_HOME` that enables + trusts the worktree
  plugin's hooks (see `~/.codex/config.toml` `[plugins]` + `[hooks.state]`). The
  wrapper prints its actual target (`WORKTREE` vs `INSTALLED`) on stderr each run,
  so a live eval can never silently mis-target — but **auto-provisioning that
  trusting `CODEX_HOME` is future work**; today you build it by hand. Without the
  override, `--live` exercises the INSTALLED `zensu@zensu` plugin (origin), not
  this worktree.
- The isolated fixture clone is `git init`-ed automatically by the wrapper (the
  TDD witness/diff path wants a repo); the deterministic `--self-check` path never
  reaches that and is unaffected.
