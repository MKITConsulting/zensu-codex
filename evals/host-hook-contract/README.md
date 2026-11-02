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
outlives the run. Codex and the app server get exactly that environment: `PATH`
and `TMPDIR` come from the caller, and nothing else does. The probe refuses to
start with an inherited
`CODEX_HOME`, so it never touches a real Codex configuration, and it refuses
`--only` together with `--record` or `--check`, because a recording measures
every scenario.

Every child process the probe starts, the `codex plugin` installs and the app
server included, runs asynchronously in its own tracked process group, so no
child blocks the event loop while a signal waits. A timeout stops the whole
group, and each run reaps its group before the next one starts. On SIGINT or
SIGTERM the probe starts no new process, stops every running group with SIGTERM,
waits a bounded time, sends SIGKILL to what is left, removes the sandbox and
exits with `128 + <signal number>`; a second signal kills at once. The sandbox
is also removed after an error, unless `--keep` is given.

## How it measures

`contract.js` holds every marker, file name, prompt, call id, role name, hook
matcher and scenario name that the scenarios plant and the analysis looks for,
so the two sides cannot drift apart: the analysis refuses to read a scenario the
contract does not name. The fixture recorder runs inside the installed plugin
and cannot load it, so the probe hands it its deny and Stop markers through the
`PROBE_MODE` environment variable.

`mock-model.js` serves the Responses API and hands every request to the
scenario's responder in `probe.js`. The responder replays a script of function
calls, code-mode `exec` calls and messages, each tool call with a fixed call id.
It routes each request by the thread metadata Codex puts in `client_metadata`,
so a subagent and a subagent's own child each get their own script. Every
request body is kept for the analysis. When the responder or a scripted item
fails, the mock still answers with its fallback stream, and reports the error
out of band to the run.

`fixture/plugins/hookprobe/hooks/record.js` is registered on every hook event
the host declares. Each invocation writes its payload and environment through a
temporary file and a rename, so a record is never read half-written, and the
`PROBE_MODE` environment variable selects its answer: a deny for named tools
(JSON or exit 2), optionally only inside subagents; one of four Stop or
SubagentStop output shapes, with the number of blocks before it lets go; or
context injection on SessionStart and UserPromptSubmit. Further PreToolUse
groups register the recorder behind the matchers listed in `contract.js`; they
only record, so the analysis can see which matcher fires for which tool. The
fixture also ships a skill and an agent role, to measure how the host names and
finds them.

`probe.js` runs 70 scenarios on three tool surfaces. An unknown model slug gets
the classic surface with plain function tools. `gpt-6-sol`, a catalog slug
marked `tool_mode: code_mode_only`, gets code mode, where every tool runs inside
one JavaScript `exec` tool. `gpt-5.5`, the one catalog model without that mark,
gets plain function tools with a freeform `apply_patch` and no multi-agent tools.

- The `codex exec` groups measure the tool surfaces and payloads; deny for the
  shell, `apply_patch` and spawning, from the root thread and inside a subagent;
  the Stop shapes; subagents, their tool calls and their SubagentStop blocks,
  also a hold that outlasts the parent's wait; agent roles, their sandbox, the
  shipped reviewer profile and the children it can spawn; a subagent's messages
  to the root thread; compaction; the model-shell environment and the hook
  working directory; and `codex exec` without the hook trust bypass, without the
  `[features]` table and with trusted hooks.
- The app-server group drives `codex app-server` through `app-server-client.js`
  and measures skill and hook listings; hook trust, including a version bump,
  script and command edits and appended or inserted hook groups; the deny and
  Stop block of trusted hooks; `request_user_input` in Default and Plan mode;
  plan items and the permission mode of a Plan-mode turn; interrupt; manual
  compaction; PermissionRequest; and a plugin update under an open thread:
  `plugin/install` replaces the trusted fixture with a newer version that also
  adds a labelled UserPromptSubmit entry while a thread is loaded, that thread
  runs a turn before the update, one after it and one after the hooks are
  trusted again, and a fresh app server then resumes it. Each hook record names
  the installation that ran it and the plugin root its environment carries, so
  the analysis can tell the old copy from the new one and see whether the added
  entry runs.

`analyze.js` turns the raw runs into facts that hold no path, id or hash, so a
second run on the same version reproduces them exactly. A fact the runs cannot
support is recorded as `unverified` with its reason. A run fails its control,
which means nothing was measured and must never read as a measured absence,
when:

- its setup failed, a hook record could not be read, or the mock reported a
  responder or script error;
- the process could not start, exceeded its time bound, ended on a signal, or
  exited with another status than the scenario expects (0 unless it says
  otherwise);
- an app-server turn ended with any status but `completed`, or the app server
  failed; the app server's exit, stderr tail and unparsed lines are kept in the
  run;
- the model received no request in a scenario that needs one, or the first
  request lacks the tool surface the scenario targets;
- no plugin hook ran in a scenario that needs one, or a hook trust grant did not
  take;
- a spawn scenario saw no subagent request.

The Codex binary is resolved from `--codex` or `PATH` and identified by
`--version`, run with a time bound and only `PATH` and an empty temporary
`HOME`. The TUI strings and the schemas come from the native binary: the
launcher itself when it is one, otherwise a `vendor/…/bin/codex` in a platform
package (`@openai/codex-*`) nested in or beside the `@openai/codex` package the
launcher belongs to. The walk starts only when the launcher's package is
`@openai/codex`, skips every directory and file that neither the current user
nor root owns or that group or others can write, and keeps the first candidate
whose own `--version` prints the same version.

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

The gate in each result is the phase-0 stop condition of the port, and every
one of its five inputs must hold:

- `denyShell`: a JSON deny blocks shell commands on all three surfaces.
- `denyApplyPatch`: a JSON deny blocks `apply_patch` in code mode and on
  `gpt-5.5`.
- `denySubagent`: inside a subagent, a JSON deny blocks shell commands on the
  classic surface and in code mode, and `apply_patch` and spawning in code mode.
- `stopBlocks`: a Stop `decision: "block"` blocks on all three surfaces.
- `trustedGates`: with the hooks trusted and no trust bypass, the shell deny and
  the Stop block work in `codex exec` and in the app server.

## In the test suite

`tests/structure/test-host-hook-contract.sh` runs in CI without a Codex binary.
It validates every recorded result and its gate, checks every schema directory,
and resolves every `facts` citation of `docs/codex-port.md` in the results
files. On synthetic runs it derives one positive case per fact group, removes
each gate source one at a time, covers every run-control branch and every
SubagentStop block target, and checks that an empty run set measures nothing.
It runs the recorder for every output shape and checks each emitted key against
the output schema of every recorded version. It checks the sandbox environment,
the refusals of an inherited `CODEX_HOME` and of `--only`, the version probe,
the native-binary walk on a fake npm layout, the process-group cleanup, the
app-server client's shutdown and escalation, the `runProcess` timeout and its
refusal while stopping, the probe's handling of one and of two SIGINTs while a
fake Codex runs, the mock, the responder routing, the fixture matchers,
the schema extractor and its binary resolution, the reviewer role rewrite, that
leaves without their source scenario read `unverified`, that each recorded
`conditions` matches the scenario table, and that the scenario order runs every
untrusted-hook scenario before the first trust grant.

The live probe needs a Codex binary and takes a little over three minutes per
version on an Apple Silicon Mac, so it runs on demand: after every Codex upgrade
and at the end of every port phase.
