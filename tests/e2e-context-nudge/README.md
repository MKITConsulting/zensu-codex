# e2e-context-nudge

End-to-end harness for `hooks/user-prompt-context-nudge.sh` (UserPromptSubmit).

- **Deterministic contract** (`run.sh --self-check`, no API): hook present, `bash -n`,
  wired into `hooks.json` UserPromptSubmit, fail-open on empty / transcript-less stdin.
  This is the primary deterministic coverage for the hook (no structure test exists).
- **Live** (`run.sh`, needs an authenticated `codex` CLI): drives a real `codex exec`
  session so the hook reads a genuine transcript; SKIP-safe when codex/auth is absent.

Invoked by `tests/run-all.sh --self-check` / `--live`. `setup-fixtures.sh` builds a
throwaway clean-git fixture for the live layer.
