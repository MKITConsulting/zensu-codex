# Codex port status

This document records how the native Codex plugin relates to upstream Zensu: what
the Codex host does, which Zensu function is taken over, which one is rebuilt
natively, and which one is excluded, each with its reason. Phase 0 fills the host
section below. Later phases add the per-function status.

## Phase 0: what the Codex host does

Every statement in this section comes from the host probe in
`evals/host-hook-contract/`, run against the real Codex binary with a local mock
model, a throwaway `HOME` and a throwaway `CODEX_HOME`. The probe needs no
credentials. It points every HTTP(S) and ALL proxy variable at a closed loopback
port, because on 0.157.1 an unisolated run showed Codex cloning its curated plugin
marketplace from `https://github.com/openai/plugins.git` in a background `git`
process that outlived Codex. The recorded results are machine-written:

- `evals/host-hook-contract/results/0.157.1.json` (installed version)
- `evals/host-hook-contract/results/0.163.0.json` (newest release at measurement time)

Re-measure after any Codex upgrade:

```bash
bash evals/host-hook-contract/run-probe.sh --check
bash evals/host-hook-contract/run-probe.sh --codex <path to another codex> --check
```

`--check` exits non-zero when the measured contract drifts from the recorded one.
The embedded hook schemas live next to the results in
`evals/host-hook-contract/schemas/<version>/`. `schemas/0.144.1/` comes from the
earlier phase1 branch and has no recorded results.

### Conditions

- **Surfaces.** The classic surface uses an unknown model slug and gets plain
  function tools. The code-mode surface uses `gpt-6-sol`, which wraps every tool
  in one JavaScript `exec` tool. The model catalog bundled with both versions
  marks every listed model except `gpt-5.5` as `tool_mode: code_mode_only`, so
  most users get code mode.
- **Coverage.** Tool payloads, deny, Stop, SubagentStop, subagents and their tool
  calls, agent roles and `request_user_input` were measured on both surfaces;
  `apply_patch` exists only in code mode. Compaction, PermissionRequest,
  interrupt, hook trust, plan approval and `codex exec` without the trust bypass
  were measured on the classic surface only. The role tool profile, the roles of
  an untrusted project and the workspace-write parent were measured in code mode
  only.
- **Settings.** Unless a scenario overrides it, `config.toml` sets
  `approval_policy = "never"`, `sandbox_mode = "danger-full-access"` and
  `[features] hooks = true` and `plugins = true`. Every `codex exec` run passes
  `--dangerously-bypass-hook-trust`, except the two that measure trust. App-server
  runs measure trust first and then grant it through `config/batchWrite`. Each
  results file lists every override under `conditions`.

### Answers and decisions

| Question | 0.157.1 | 0.163.0 | Decision for the native plugin |
|---|---|---|---|
| Which hook events fire? | All 12 registered events fire: SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, SubagentStart, SubagentStop, Stop, Interrupt, SessionEnd. SessionEnd has no output schema. Plugin hooks also run when `config.toml` has no `[features]` table. | Same. | Register native entry scripts on all 12 events where upstream needs them. Treat SessionEnd as notification only. Setup enables no feature flag. |
| What do hooks see in their environment? | `CLAUDE_PLUGIN_ROOT` and `PLUGIN_ROOT` point at the installed plugin, `CLAUDE_PLUGIN_DATA` and `PLUGIN_DATA` at `plugins/data/<plugin>-<marketplace>` under `CODEX_HOME`. No `CLAUDE_PROJECT_DIR` and no thread id variable. The hook runs in the project directory, and the payload carries `cwd`. | Same. | Upstream code that reads the plugin root and data variables works unchanged. The project directory comes from the payload `cwd`. |
| Is the thread id visible in model shells, and does it equal the hook `session_id`? | Yes. In a root-thread shell `CODEX_THREAD_ID` and `CODEX_SESSION_ID` both equal the hook `session_id`. In a subagent's shell `CODEX_THREAD_ID` is the subagent thread, which hooks report as `agent_id`, and `CODEX_SESSION_ID` is still the root thread. Hooks themselves get the id only in the payload. | Same, plus `CODEX_TOOL_CALL_ID` and `CODEX_APPLY_PATCH_PRESERVE_LINE_ENDINGS` in model shells. | A model shell binds to the main session only when its `CODEX_THREAD_ID` equals the root `session_id`, so a subagent shell never binds as main. `CODEX_SESSION_ID` names the root thread in every shell and never binds. This replaces the current plugin's rule that `CODEX_THREAD_ID` is never a Session Control selector; the `ZENSU_*` propagation is no longer needed for binding. |
| Do subagent hooks identify the subagent? | Yes, on both surfaces. SubagentStart and the tool hooks inside a subagent (`Bash`, and `apply_patch` in code mode) carry `session_id` as the root thread, `agent_id` as the subagent thread, `agent_type` as the role name or `default`, and the subagent's `turn_id`; SubagentStop carries the same fields. A subagent turn fires no SessionStart and no Stop. On the classic surface UserPromptSubmit also fires for the subagent, with the agent fields and the spawn message verbatim as `prompt`; in code mode it does not fire. | Same. | Reviewer and evidence gates key on `agent_id` and `agent_type` in PreToolUse, SubagentStart and SubagentStop. UserPromptSubmit logic ignores payloads that carry agent fields. |
| Do skills get a namespace? | Yes. A plugin skill is listed as `<plugin>:<skill>`, both in `skills/list` and in the model instructions. | Same. | Use bare skill names (`tdd`), so the skill appears as `zensu:tdd`. Today's `zensu-tdd` would appear as `zensu:zensu-tdd`. |
| Where are agent roles found, and what do they control? | `$CODEX_HOME/agents/<name>.toml`, the project's `.codex/agents/`, and `[agents.<name>]` in config. A plugin's `agents/` directory is **not** loaded. With roles present, `spawn_agent` gains an `agent_type` parameter listing them, and the role's `developer_instructions` reach the subagent. When a project role and a `$CODEX_HOME` role share a name, the project role wins, also in an untrusted project, whose roles are listed, spawned and instructed like any other. A role's `sandbox_mode = "read-only"` does not stop the subagent from writing the project, neither under a `danger-full-access` nor under a `workspace-write` parent, while a read-only parent sandbox does block the parent's own writes. A role with the `[features]` and `[tools]` tables of the current reviewer role loses only `exec_command` and `write_stdin`; `apply_patch`, the collaboration tools, the goal tools and `view_image` stay. | Same. | `$zensu-setup` installs the reviewer roles into `$CODEX_HOME/agents/`, and skills spawn them with `agent_type`. The role is not a security boundary: native PreToolUse gates keyed on `agent_type` deny reviewer writes, and the doctor flags every project role that uses a Zensu reviewer name. |
| What do the tool payloads look like? | `exec_command` reaches hooks as `Bash` with `{command}`, also for a `tty: true` call, so a hook cannot tell an interactive process apart. `apply_patch`, offered only in code mode, reaches hooks as `apply_patch` with the whole patch text in `tool_input.command`; a multi-file patch is one event. `write_stdin` fires no PreToolUse and no PostToolUse. In code mode the nested tools fire the same events and the outer `exec` tool fires none. On the classic surface spawning reaches hooks as `spawn_agent` and waiting as `multi_agent_v1wait_agent`; in code mode they are `collaborationspawn_agent` and `collaborationwait_agent`. `request_user_input` keeps its name. PostToolUse `tool_response` is a string. | Same. | Upstream shell gates read the Claude `Bash` shape unchanged. Edit gates need one native reader that extracts every path from the patch text. Readers of `tool_response` take a string. Spawn gates use the `tool_name` values above. |
| Does a deny work per tool? | Yes. A PreToolUse deny, JSON `permissionDecision: "deny"` or exit 2, blocks `Bash` on both surfaces and `apply_patch` in code mode; the side effect does not happen and the reason reaches the model. `Bash` and `^Bash$` fire for shell commands, `^exec_command$` never fires. `^apply_patch$` and `^(Edit\|Write\|MultiEdit)$` both fire for `apply_patch`, but its payload `tool_name` stays `apply_patch`, so a script that checks for Claude edit names lets it pass. `spawn_agent` fires for the classic spawn only; no tested matcher fires for `collaborationspawn_agent`, `collaborationwait_agent`, `multi_agent_v1wait_agent` or `request_user_input`. | Same. | Gates register on `Bash` and `apply_patch` and decide by the payload's Codex `tool_name`. Spawn gates register without a matcher and filter by `tool_name`. |
| Where is `request_user_input` available? | Offered in Default mode on both surfaces, but there it answers that it is unavailable in Default mode, in `codex exec` and in the app server alike. In Plan mode the app server sends `item/tool/requestUserInput` on both surfaces; the answer reaches the model as `answers.<question id>.answers[]`. At most 3 questions with 2-3 options. | Same. | Questions use `request_user_input` in Plan mode only. In Default mode, in `codex exec` and in subagents, skills ask in prose. |
| What does plan approval look like? | A `<proposed_plan>` block becomes a separate `plan` item. No hook payload carries the collaboration mode: tool calls in a Plan-mode turn fire PreToolUse, and every hook in that turn reports `permission_mode: "bypassPermissions"`, never `plan`. The binary carries the TUI approval strings `Implement this plan?` and `Implement the plan.`, and a fresh-context variant that starts with `A previous agent produced the plan below to accomplish the user`. Sent as a prompt, `Implement the plan.` reaches UserPromptSubmit verbatim, and so does a spawn message with that text in a classic subagent. Which prompt the TUI sends is read from the binary, not observed in the TUI. | Same. | Plan approval is detected at UserPromptSubmit from either approval prompt, only in payloads without `agent_id` and `agent_type`. There is no plan-approval hook event. |
| Is `update_plan` available? | No. It is offered on no measured surface (classic, code mode, and Plan mode on both). | No. | Skills report progress in prose. Goals are not a substitute; they are for explicitly requested objectives. |
| How does hook trust behave? | Untrusted plugin hooks are skipped silently, in the app server and in `codex exec` alike; the turn still runs. In the app server no `warning`, `configWarning`, `deprecationNotice`, `guardianWarning` or `error` notification names a hook, and no `hook/started` or `hook/completed` notification arrives, while a trusted turn sends both for every run with source `plugin`. `codex exec` mentions skipped hooks neither in its JSON events nor on stderr, and runs them once they are trusted. `hooks/list` reports the hooks as `untrusted` without an error. Trust is stored per hook in `config.toml` as `[hooks.state."<plugin>@<marketplace>:<hooks file>:<event in snake case>:<group index>:<hook index>"] trusted_hash`. It survives a version bump and an edit to the hook script. An edited `hooks.json` entry turns that hook `modified`, and inserting a group before existing ones re-keys them, so they read `modified` or `untrusted` until the old file is restored. | Same. | `hooks.json` is append-only: a release never inserts, removes or reorders a group or hook, only appends, and keeps every existing entry byte-stable; logic lives in the scripts. The doctor reports untrusted or modified hooks from `hooks/list`, and unattended `codex exec` runs check trust before they start, because nothing else surfaces it. |
| Does Stop blocking work? | Yes, on both surfaces. `decision: "block"` and exit 2 block and re-invoke the model with the reason, wrapped in `<hook_prompt hook_run_id="stop:…">`. `continue: false` and `systemMessage` do not block; the turn ends after one model request. `stop_hook_active` is false first, true on re-entry. Stop does not fire when a subagent's turn ends. | Same. | The Stop chain enforcer is ported as is. |
| Which thread does a SubagentStop block re-invoke? | The subagent, on both surfaces. The block reason reaches only subagent requests, and SubagentStop fires again with `stop_hook_active: true`. | Same. | A reviewer can be held at SubagentStop until it returns a valid result. |
| When does PermissionRequest fire? | With on-request approvals in the app server, alongside the client approval request `item/commandExecution/requestApproval`. Under `codex exec` with `approval_policy = "on-request"` no PermissionRequest hook fires, because `codex exec` forces the approval policy to Never. | Same. | No Zensu gate depends on PermissionRequest. |
| Do compaction and interrupt fire hooks? | Yes. Automatic and manual compaction both fire PreCompact and PostCompact with `trigger` `auto` or `manual`, and SessionStart fires again with `source: "compact"`, after a manual compaction in the turn that follows it. Interrupt fires on `turn/interrupt`. | Same. | SessionStart with `source: "compact"` is where context is re-injected after compaction. |

### Gate

Gate verdict: continue. A JSON PreToolUse deny blocks `Bash` on both surfaces and `apply_patch` in code mode, and a Stop `decision: "block"` blocks on both surfaces, on 0.157.1 and on 0.163.0, measured under `codex exec` with the trust bypass and the `[features]` table named in the conditions.

### Corrections to the master plan

- The plan expected `request_user_input` in the main thread outside `codex exec`. Measured: it works only in Plan mode, on both surfaces.
- The plan expected progress through `update_plan`. Measured: the tool does not exist on any surface, so progress is reported in prose.
- The plan expected agent roles installed "where Codex finds them", with reviewers confined by `sandbox_mode = "read-only"`. Measured: the plugin's `agents/` directory is not that place, `$CODEX_HOME/agents/` is, and the role's sandbox does not stop writes, so reviewer read-only needs a hook gate.
- The plan expected session binding through Codex's thread id if model shells show it. Measured: they show it, and only `CODEX_THREAD_ID` tells a subagent shell from the main thread; `CODEX_SESSION_ID` does not.
- The plan expected shell gates on `exec_command` and `write_stdin`. Measured: `write_stdin` fires no hook, so input typed into a running process is invisible to every gate.
- The plan expected `codex exec` to run without `spawn_agent`, so spawn tests were planned for the app server. Measured: `codex exec` offers `spawn_agent` on both surfaces (`multi_agent_v1.spawn_agent` on the classic surface, `collaboration.spawn_agent` in code mode), and SubagentStart and SubagentStop fire there with `agent_id` and `agent_type`. Unattended `codex exec` runs can therefore spawn the reviewer roles, but their hooks run only once trusted: the spawn runs passed the trust bypass, and without it `codex exec` skips untrusted hooks.

### Claims of the current plugin that no longer hold

The current plugin was validated on Codex 0.144.1. On 0.157.1 and 0.163.0 the
probe contradicts two claims of the repository README:

- The README calls the reviewer capability boundary host-enforced, with an
  OS-enforced read-only sandbox. Measured: a role's `sandbox_mode = "read-only"`
  does not stop writes, and the reviewer's `[features]` and `[tools]` tables
  remove only the shell tools.
- The README says plugin hooks require the `plugin_hooks` feature. Measured:
  plugin hooks run with no `[features]` table at all.

### Residual gaps

- `write_stdin` is unhooked, and a `tty: true` call reaches PreToolUse with only `{command}`, so an interactive process cannot be policed after it starts.
- Plan mode is visible to hooks only through the approval prompt text that a client chooses to send.
- Untrusted hooks fail silently in the app server and in `codex exec`. Only a trust check such as the doctor's, or a client that reads `hooks/list`, can surface it.
- `agent_type` is the role name alone, and a project role can take a Zensu reviewer's name, also in an untrusted project. The doctor check is the only planned guard against such a role's instructions.
- Whether a model-initiated message (`send_input`, `followup_task`, `send_message`) reaches the root thread's UserPromptSubmit is not measured.
- Only six matchers were tested, so which matcher catches the code-mode spawn names is open.
- The role sandbox and the tool profile were measured with `approval_policy = "never"` only.
