# config-gate (offline)

Deterministic, no-API tests for `plugins/zensu/hooks/lib/zensu-config.sh` — the
config-resolution layer every hook is gated by. Runs in the default (no-arg)
`tests/run-all.sh` path.

- `test-hook-enabled.sh` — `zensu_hook_enabled` is default-on unless the hook key
  is explicitly `false`; fail-open when the config file is missing.
- `test-log-style.sh` — `_zensu_log_style` resolves `logging.timestampStyle`
  (wall/relative/none; unknown → wall).

Complements `tests/structure/test-config-merge.sh` (global+project deep merge) —
the two together cover the config surface without overlap.

Run: `bash run-eval.sh` (or `--self-check`, an offline no-op alias).
