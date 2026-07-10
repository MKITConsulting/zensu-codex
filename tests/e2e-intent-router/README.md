# e2e-intent-router

End-to-end harness for `hooks/user-prompt-intent-router.sh` (UserPromptSubmit).

- **Deterministic contract** (`run.sh --self-check`, no API): hook present, `bash -n`,
  wired into `hooks.json` UserPromptSubmit, fail-open on empty stdin. The rich routing
  assertions live in `tests/structure/test-intent-router-hook.sh` (default suite).
- **Live** (`run.sh`, needs an authenticated `codex` CLI): drives a real `codex exec`
  session to prove the hook is reached; SKIP-safe when codex/auth is unavailable.

Invoked by `tests/run-all.sh --self-check` / `--live`. `setup-fixtures.sh` builds a
throwaway clean-git fixture for the live layer.
