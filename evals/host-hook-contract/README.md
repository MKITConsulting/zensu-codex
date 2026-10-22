# Host hook contract probe

Measures what the Codex host does with plugin hooks, skills, agent roles and
tools, so that the native plugin is built on measured behaviour rather than on
strings read out of the binary. The answers and the decisions drawn from them
live in `docs/codex-port.md`.

```bash
bash evals/host-hook-contract/run-probe.sh --check
bash evals/host-hook-contract/run-probe.sh --codex <path to codex> --record
bash evals/host-hook-contract/extract-hook-schemas.sh --codex <path to codex> --check
```

No credentials and no quota. Every run builds a throwaway `HOME` and
`CODEX_HOME` under the system temp directory, installs the `hookprobe` fixture
plugin from the `probe-market` fixture marketplace, and points the model
provider at a local mock of the Responses API. Every HTTP(S) and ALL proxy
variable points at a closed loopback port, with only loopback hosts exempt, so
no client that honors those variables reaches the network; a client that
ignores them is not isolated. Without that, Codex clones its curated plugin
marketplace from github.com in the background at startup, and the clone
outlives the run. The probe refuses to start with an inherited `CODEX_HOME`, so
it never touches a real Codex configuration. The sandbox is removed when the
run ends, also after an error, SIGINT or SIGTERM, unless `--keep` is given; on
a signal the probe stops its running Codex processes first.

## How it measures

`contract.js` holds every marker, file name, prompt, call id, role name and
hook matcher that the scenarios plant and the analysis looks for, so the two
sides cannot drift apart. The fixture recorder runs inside the installed plugin
and cannot load it, so the probe hands it its deny and Stop markers through the
`PROBE_MODE` environment variable.

`mock-model.js` serves the Responses API and hands every request to the
scenario's responder in `probe.js`. The responder replays a script of function
calls, code-mode `exec` calls and messages, each tool call with a fixed call id.
It routes each request by the subagent thread metadata Codex puts in
`client_metadata`, so a subagent gets its own script. Every request body is kept
for the analysis.

`fixture/plugins/hookprobe/hooks/record.js` is registered on every hook event
the host declares. Each invocation writes its payload and environment, and the
`PROBE_MODE` environment variable selects its answer: a deny for a named tool
(JSON or exit 2), one of four Stop or SubagentStop output shapes, or context
injection on SessionStart and UserPromptSubmit. Further PreToolUse groups
register the recorder behind the matchers listed in `contract.js`; they only
record, so the analysis can see which matcher fires for which tool. The
fixture also ships a skill and an agent role, to measure how the host names and
finds them.

`probe.js` runs 47 scenarios. The `codex exec` groups measure tool payloads,
deny, Stop, subagents and their tool calls, agent roles and their sandbox,
compaction, the model-shell environment, and `codex exec` without the hook
trust bypass or without the `[features]` table. The app-server group drives
`codex app-server` through `app-server-client.js` and measures skill and hook
listings, hook trust, `request_user_input` in Default and Plan mode, plan
items, interrupt, manual compaction and PermissionRequest.

Two tool surfaces are measured. An unknown model slug gets plain function
tools; a catalog slug marked `tool_mode: code_mode_only` gets code mode, where
every tool runs inside one JavaScript `exec` tool. The model catalog bundled
with 0.157.1 and 0.163.0 marks every listed model except `gpt-5.5` that way.

`analyze.js` turns the raw runs into facts that hold no path, id or hash, so a
second run on the same version reproduces them exactly. A fact the runs cannot
support is recorded as `unverified` with its reason. A run fails its control
when a scenario cannot start, exceeds its time bound or reaches no model; when
its first request lacks the tool surface it targets; when no plugin hook ran in
a scenario that needs one; when a hook trust grant did not take; when a spawn
scenario saw no subagent request; or when no native Codex binary was found.
Those cases mean nothing was measured, which must never read as a measured
absence.

## Outputs

- `results/<version>.json` — the facts and the gate for one Codex version.
  `--record` writes it; `--check` re-measures and exits non-zero on any drift.
  `--print` shows the facts without writing. `conditions` records the defaults
  and every per-scenario override; the launcher (npm package or native binary)
  is recorded but never counts as drift.
- `schemas/<version>/` — the draft-07 hook input and output schemas the binary
  embeds, extracted verbatim by `schemas.js`. They are the contract's shape,
  never its behaviour: a schema that accepts `decision` says nothing about
  which thread a block re-invokes. `schemas/0.144.1/` was extracted on the
  earlier phase1 branch and has no results file.

The gate in each result is the phase-0 stop condition of the port: a JSON
deny must block shell commands on both surfaces and `apply_patch` in code mode,
and a Stop `decision: "block"` must block on both surfaces.

## In the test suite

`tests/structure/test-host-hook-contract.sh` runs in CI without a Codex binary.
It validates every recorded result and its gate, checks every schema directory
and the citations in `docs/codex-port.md`, and exercises the mock, the
recorder, the fixture matchers, the schema extractor, the scenario order and
the fact derivation on synthetic runs. The live probe needs a Codex binary and
takes about half a minute per version, so it runs on demand: after every Codex
upgrade and at the end of every port phase.
