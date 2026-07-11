# e2e-intent-router

End-to-end harness for `hooks/user-prompt-intent-router.sh` (UserPromptSubmit).

- **Deterministic contract** (`run.sh --self-check`, no API): hook present, `bash -n`,
  wired into `hooks.json` UserPromptSubmit, fail-open on empty stdin. The rich routing
  assertions live in `tests/structure/test-intent-router-hook.sh` (default suite).
- **Live** (`run.sh`): PLACEHOLDER today — prints a NOTE and asserts nothing live.
  Deepen with a real `codex exec` planning prompt + a hook-log assertion before
  treating the live layer as coverage.

Invoked by `tests/run-all.sh --self-check` / `--live`. `setup-fixtures.sh` builds a
throwaway clean-git fixture for the FUTURE live layer — run it manually when
deepening; `run-all.sh` does not invoke it.
