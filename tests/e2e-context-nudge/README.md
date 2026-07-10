# e2e-context-nudge

End-to-end harness for `hooks/user-prompt-context-nudge.sh` (UserPromptSubmit).

- **Deterministic contract** (`run.sh --self-check`, no API): hook present, `bash -n`,
  wired into `hooks.json` UserPromptSubmit, fail-open on empty / transcript-less stdin.
  This is the primary deterministic coverage for the hook (no structure test exists).
- **Live** (`run.sh`): PLACEHOLDER today — prints a NOTE and asserts nothing live.
  Deepen with a real `codex exec` session whose transcript the hook reads before
  treating the live layer as coverage.

Invoked by `tests/run-all.sh --self-check` / `--live`. `setup-fixtures.sh` builds a
throwaway clean-git fixture for the FUTURE live layer — run it manually when
deepening; `run-all.sh` does not invoke it.
