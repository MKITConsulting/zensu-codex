#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/evals/host-hook-contract"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

for f in probe.js analyze.js contract.js codex-binary.js mock-model.js app-server-client.js processes.js schemas.js fixture/plugins/hookprobe/hooks/record.js; do
  if node --check "$PROBE/$f" 2>/dev/null; then ok "node --check $f"; else bad "node --check $f"; fi
done
for f in run-probe.sh extract-hook-schemas.sh; do
  if bash -n "$PROBE/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

OUT="$(env CODEX_HOME=/nonexistent bash "$PROBE/run-probe.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'inherited CODEX_HOME'; then
  ok "run-probe.sh refuses an inherited CODEX_HOME"
else
  bad "run-probe.sh did not refuse an inherited CODEX_HOME (exit $RC)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RESULT="$(ROOT="$ROOT" PROBE="$PROBE" WORK="$WORK" node <<'NODE'
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn, spawnSync } = require('node:child_process');

const ROOT = process.env.ROOT;
const PROBE = process.env.PROBE;
const WORK = process.env.WORK;
const lines = [];
const ok = (name) => lines.push(`ok ${name}`);
const bad = (name) => lines.push(`bad ${name}`);
const check = (cond, name) => (cond ? ok(name) : bad(name));

const analyze = require(path.join(PROBE, 'analyze.js'));
const contract = require(path.join(PROBE, 'contract.js'));
const schemas = require(path.join(PROBE, 'schemas.js'));
const probe = require(path.join(PROBE, 'probe.js'));
const processes = require(path.join(PROBE, 'processes.js'));
const codexBinary = require(path.join(PROBE, 'codex-binary.js'));
const { startMockModel } = require(path.join(PROBE, 'mock-model.js'));
const { CALLS, MARKERS, FILES, CONTEXT, PROMPTS, TUI_STRINGS, TWIN_ROLE } = contract;

const PLUGIN = { name: 'p', marketplace: 'm', id: 'p@m', version: '0.0.1' };
const stubFs = (files) => {
  const contents = Array.isArray(files) ? Object.fromEntries(files.map((name) => [name, ''])) : files;
  return {
    existsSync: (file) => Object.prototype.hasOwnProperty.call(contents, path.basename(file)),
    readFileSync: (file) => {
      const name = path.basename(file);
      if (!Object.prototype.hasOwnProperty.call(contents, name)) throw new Error('no file');
      return contents[name];
    },
  };
};
const ctxOf = (files = []) => ({ fs: stubFs(files), codexHome: '/h/codex-home', plugin: PLUGIN, tuiStrings: {} });
const derive = (runs, files) => analyze.deriveFacts(runs, ctxOf(files));
const run = (name, requests, hooks = [], extra = {}) => ({ name, requests, hooks, project: '/p', ...extra });
const output = (callId, text) => ({ input: [{ type: 'custom_tool_call_output', call_id: callId, output: text }] });
const hook = (event, payload, extra = {}) => ({ event, argv: [event], payload, ...extra });
const sub = (thread, parent, input = []) => ({ client_metadata: { thread_id: thread, 'x-codex-parent-thread-id': parent }, input });
const subOutput = (thread, parent, callId, text) => sub(thread, parent, [{ type: 'custom_tool_call_output', call_id: callId, output: text }]);
const blockRun = (name) => run(name, [{ input: [] }, { input: [{ type: 'message', role: 'user', content: MARKERS.stop }] }]);
const denied = [{ input: [] }, output(CALLS.deny, `${MARKERS.deny} Bash`)];
const parseJson = (text) => {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
};

function measuredLeaves(value, prefix = '') {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const keys = Object.keys(value);
    if (keys.length === 1 && keys[0] === 'unverified') return [];
    if (!keys.length) return [prefix || '<root>'];
    return keys.flatMap((key) => measuredLeaves(value[key], prefix ? `${prefix}.${key}` : key));
  }
  return [prefix || '<root>'];
}

const GATE_SOURCES = {
  denyShell: ['deny-classic-bash-json', 'deny-code-bash-json', 'deny-gpt55-bash-json'],
  denyApplyPatch: ['deny-code-patch-json', 'deny-gpt55-patch-json'],
  denySubagent: ['deny-sub-classic-bash-json', 'deny-sub-code-bash-json', 'deny-sub-code-patch-json', 'deny-sub-code-spawn-json'],
  stopBlocks: ['stop-decision-block', 'stop-code-decision-block', 'stop-gpt55-decision-block'],
  trustedGates: ['deny-classic-bash-json-trusted', 'stop-decision-block-trusted', 'app-gates'],
};

function gateRuns() {
  const subDenyRun = (name, tool) => run(name, [{ input: [] }, subOutput('t2', 't1', CALLS.subDeny, `${MARKERS.deny} ${tool}`)], [
    hook('PreToolUse', { tool_name: tool, agent_id: 't2', agent_type: 'default' }),
    hook('SubagentStart', { agent_id: 't2', agent_type: 'default' }),
  ]);
  return [
    ...['deny-classic-bash-json', 'deny-code-bash-json', 'deny-gpt55-bash-json', 'deny-code-patch-json', 'deny-gpt55-patch-json', 'deny-classic-bash-json-trusted'].map((name) => run(name, denied)),
    subDenyRun('deny-sub-classic-bash-json', 'Bash'),
    subDenyRun('deny-sub-code-bash-json', 'Bash'),
    subDenyRun('deny-sub-code-patch-json', 'apply_patch'),
    subDenyRun('deny-sub-code-spawn-json', 'collaborationspawn_agent'),
    ...['stop-decision-block', 'stop-code-decision-block', 'stop-gpt55-decision-block', 'stop-decision-block-trusted'].map(blockRun),
    run('app-gates', [{ input: [] }, output(CALLS.deny, `${MARKERS.deny} Bash`), { input: [{ type: 'message', role: 'user', content: MARKERS.stop }] }]),
  ];
}

function gateChecks() {
  const all = gateRuns();
  const passing = analyze.deriveGate(derive(all));
  check(passing.verdict === 'continue' && analyze.GATE_INPUTS.every((key) => passing[key] === true), 'gate continues when every gate input is measured as working');
  check(JSON.stringify(Object.keys(GATE_SOURCES).sort()) === JSON.stringify([...analyze.GATE_INPUTS].sort()), 'every gate input has its source scenarios in this suite');
  for (const [key, names] of Object.entries(GATE_SOURCES)) {
    for (const name of names) {
      const gate = analyze.deriveGate(derive(all.filter((item) => item.name !== name)));
      const others = analyze.GATE_INPUTS.filter((input) => !GATE_SOURCES[input].includes(name));
      check(gate[key] === false && gate.verdict === 'stop' && others.every((input) => gate[input] === true), `gate input ${key} fails closed without ${name}`);
    }
  }
  const sideEffect = derive(all, [FILES.denied]);
  check(sideEffect.deny.codeMode.bashJson.blocked === false && analyze.deriveGate(sideEffect).denyShell === false, 'a deny whose side effect happened is not a block');
  const posted = derive([run('deny-code-bash-json', denied, [hook('PostToolUse', { tool_name: 'Bash' })])]);
  check(posted.deny.codeMode.bashJson.blocked === false, 'a deny followed by PostToolUse is not a block');
  const silent = derive([run('deny-code-bash-json', [{ input: [] }])]);
  check(Boolean(silent.deny.codeMode.bashJson.unverified), 'a denied call without output stays unverified');
  const stops = derive([
    run('stop-decision-block', [{ input: [] }]),
    run('stop-exit2', [{ input: [] }, { input: [] }]),
    blockRun('stop-continue-false'),
  ]);
  check(stops.stop.classic.decisionBlock.blocks === false, 'one model request is not a Stop block');
  check(stops.stop.classic.exit2.blocks === false, 'an extra request without the block reason is not a Stop block');
  check(stops.stop.classic.continueFalse.blocks === true, 'an extra request carrying the block reason is a Stop block');
  const labelled = derive([run('deny-code-bash-json', denied, [
    hook('PreToolUse', { tool_name: 'Bash' }),
    hook('PreToolUse', { tool_name: 'Bash' }, { label: 'bash-anchored', argv: ['PreToolUse', 'bash-anchored'] }),
    hook('PreToolUse', { tool_name: 'apply_patch' }, { label: 'claude-edit', argv: ['PreToolUse', 'claude-edit'] }),
    hook('PostToolUse', { tool_name: 'Bash' }, { label: 'bash-plain', argv: ['PostToolUse', 'bash-plain'] }),
  ])]);
  check(JSON.stringify(labelled.deny.matcherHits) === JSON.stringify({ Bash: ['bash-anchored'], apply_patch: ['claude-edit'] }), 'matcher hits group labelled records by tool name');
  check(labelled.deny.codeMode.bashJson.blocked === true, 'labelled matcher records never count as the catch-all hook');
}

function emptyRunChecks() {
  const empty = derive([]);
  const leaking = analyze.FACT_KEYS.filter((key) => measuredLeaves(empty[key]).length > 0);
  check(leaking.length === 0, `an empty run set measures nothing in any fact group${leaking.length ? `: ${leaking.join(', ')}` : ''}`);
  check(analyze.deriveGate(empty).verdict === 'stop', 'gate stops when nothing was measured');
}

function blockTargetChecks() {
  const parent = { input: [{ type: 'message', role: 'user', content: MARKERS.subagentStop }] };
  const child = sub('t2', 't1', [{ type: 'message', role: 'user', content: MARKERS.subagentStop }]);
  const target = (requests) => derive([run('spawn-code-subagent-stop-block', requests)]).subagentStop.codeMode.blockTarget;
  check(target([parent, child]) === 'both' && target([{ input: [] }, child]) === 'subagent' && target([parent]) === 'parent' && target([{ input: [] }]) === 'none', 'SubagentStop block targets read subagent, parent, both and none');
  const stopsOf = [hook('SubagentStop', { last_assistant_message: 'pre-hold text' }), hook('SubagentStop', { last_assistant_message: 'final text' })];
  const receipt = (input) => derive([run('spawn-code-subagent-stop-block', [{ input }], stopsOf)]).subagentStop.codeMode.parentReceives;
  check(receipt([{ type: 'message', content: 'final text' }]) === 'final' && receipt([{ type: 'message', content: 'pre-hold text, final text' }]) === 'both' && receipt([]) === 'none', 'parentReceives classifies which subagent message reaches the parent');
  const twiceHeld = [hook('SubagentStop', { last_assistant_message: 'first held text' }), hook('SubagentStop', { last_assistant_message: 'second held text' }), hook('SubagentStop', { last_assistant_message: 'final text' })];
  const receiptOfTwice = (input) => derive([run('spawn-code-subagent-stop-block', [{ input }], twiceHeld)]).subagentStop.codeMode.parentReceives;
  check(receiptOfTwice([{ type: 'message', content: 'second held text' }]) === 'pre-hold' && receiptOfTwice([{ type: 'message', content: 'second held text, final text' }]) === 'both' && receiptOfTwice([{ type: 'message', content: 'final text' }]) === 'final', 'parentReceives reads every held attempt, not only the first');
  const hold = derive([run('spawn-code-subagent-stop-hold', [output(CALLS.waitFirst, '{"timed_out":true}'), output(CALLS.waitSecond, '{"timed_out":false}'), { input: [{ type: 'agent_message', content: 'final text' }] }], stopsOf)]).subagentStop.holdOutlastingWait.codeMode;
  check(hold.firstWaitTimedOut === true && hold.secondWaitTimedOut === false && hold.parentReceives === 'final', 'a hold that outlasts the first wait is read from the wait outputs');
}

function controlChecks() {
  const classicTools = [{ type: 'function', name: 'exec_command' }, { type: 'namespace', name: 'multi_agent_v1', tools: [{ type: 'function', name: 'spawn_agent' }] }];
  const codeTools = [{ type: 'namespace', name: 'functions', tools: [{ type: 'custom', name: 'exec' }] }];
  const gpt55Tools = [{ type: 'function', name: 'exec_command' }, { type: 'custom', name: 'apply_patch' }];
  const healthyExec = (surface, tools) => ({ name: `healthy-${surface}`, surface, expect: probe.expectOf({ group: 'exec' }), proc: { code: 0, signal: null, timedOut: false, spawnError: null }, requests: [{ tools }], hooks: [{ event: 'SessionStart' }], hookErrors: [], mockErrors: [] });
  for (const [surface, tools] of [['classic', classicTools], ['code', codeTools], ['gpt55', gpt55Tools]]) check(probe.controlOf(healthyExec(surface, tools)).ok === true, `a healthy ${surface} run passes its control`);
  const offered = { classic: classicTools, code: codeTools, gpt55: gpt55Tools };
  const crossed = Object.keys(offered).flatMap((surface) => Object.keys(offered).filter((other) => other !== surface).map((other) => [surface, other]));
  const wrongSurface = crossed.filter(([surface, other]) => {
    const control = probe.controlOf(healthyExec(surface, offered[other]));
    return control.ok !== false || !control.reason.includes(`did not offer the ${surface} tool surface`);
  });
  check(wrongSurface.length === 0, `a run fails its control when its first request offers another surface's tools${wrongSurface.length ? `: ${wrongSurface.map(([surface, other]) => `${surface} with ${other}`).join(', ')}` : ''}`);
  check(probe.controlOf(healthyExec('gpt55', [...gpt55Tools, { type: 'namespace', name: 'collaboration', tools: [{ type: 'function', name: 'spawn_agent' }] }])).ok === false, 'a gpt55 run fails its control when its first request offers multi-agent tools');
  const healthyApp = { name: 'healthy-app', surface: null, expect: probe.expectOf({ group: 'app' }), error: null, requests: [{}], hooks: [], hookErrors: [], mockErrors: [] };
  check(probe.controlOf(healthyApp).ok === true, 'a healthy app-server run passes its control');
  const base = healthyExec('classic', classicTools);
  const failing = [
    ['setup failed', { ...base, setupError: 'boom' }],
    ['a hook record could not be read', { ...base, hookErrors: ['x.json: Unexpected end of JSON input'] }],
    ['the mock model hit a responder error', { ...base, mockErrors: [{ stage: 'responder', message: 'no agent id' }] }],
    ['could not start', { ...base, proc: { ...base.proc, spawnError: 'ENOENT' } }],
    ['exceeded the time bound', { ...base, proc: { ...base.proc, timedOut: true } }],
    ['ended on signal SIGABRT', { ...base, proc: { ...base.proc, code: null, signal: 'SIGABRT' } }],
    ['exited 101, expected 0', { ...base, proc: { ...base.proc, code: 101 } }],
    ['the mock model received no request', { ...base, requests: [] }],
    ['did not offer the code tool surface', healthyExec('code', classicTools)],
    ['no plugin hook ran', { ...base, hooks: [] }],
    ['the hook trust grant did not take', { ...base, result: { trusted: false } }],
    ['no model request carried the subagent thread metadata', { ...base, expect: { ...base.expect, subagent: true } }],
    ['ended with status failed', { ...healthyApp, error: 'the turn for "x" ended with status failed' }],
    ['the mock model received no request', { ...healthyApp, requests: [] }],
  ];
  for (const [reason, failingRun] of failing) {
    const control = probe.controlOf(failingRun);
    check(control.ok === false && control.reason.includes(reason), `a run fails its control when ${reason}`);
  }
  check(probe.expectOf({ group: 'app', expectModel: false }).model === false && probe.expectOf({ group: 'exec', expectExit: 3 }).exit === 3 && probe.expectOf({ group: 'exec' }).exit === 0, 'expectOf reads expectModel and expectExit, exit defaults to 0');
}

function positiveChecks() {
  const covered = new Set();
  const positive = (group, cond, name) => {
    covered.add(group);
    check(cond, `${group}: ${name}`);
  };
  const lists = run('app-lists', [], [], { result: { hooks: { data: [{ hooks: [{ eventName: 'sessionStart' }, { eventName: 'stop' }], errors: [], warnings: [] }] }, skills: { data: [{ skills: [{ name: 'p:probe-skill', pluginId: 'p@m' }] }] } } });
  const events = derive([lists, run('classic-baseline', [], [hook('SessionStart', { source: 'startup' })])]).events;
  positive('events', JSON.stringify(events.registered) === '["SessionStart","Stop"]' && JSON.stringify(events.fired) === '["SessionStart"]' && JSON.stringify(events.notFired) === '["Stop"]', 'registered, fired and not-fired events come from hooks/list and the hook records');
  const payloads = derive([run('classic-baseline', [], [hook('SessionStart', { source: 'startup', permission_mode: 'default' }), hook('SessionEnd', { reason: 'exit' })])]).hookPayloads;
  positive('hookPayloads', payloads.keys.SessionStart.includes('source') && JSON.stringify(payloads.sessionStartSources) === '["startup"]' && JSON.stringify(payloads.sessionEndReasons) === '["exit"]' && JSON.stringify(payloads.permissionModes) === '["default"]', 'keys, sources, end reasons and permission modes come from the payloads');
  const pluginRoot = '/h/codex-home/plugins/cache/m/p/0.0.1';
  const environment = derive([run('classic-baseline', [{ instructions: CONTEXT.sessionStart, input: [] }], [hook('SessionStart', { session_id: 'tid', cwd: '/p' }, { script: `${pluginRoot}/hooks/record.js`, cwd: '/p', env: { CLAUDE_PLUGIN_ROOT: pluginRoot, CLAUDE_PLUGIN_DATA: '/h/codex-home/plugins/data/p-m', CODEX_HOME: '/h/codex-home', CODEX_PROBE: 'tid' } })])]).hookEnvironment;
  positive('hookEnvironment', environment.variables.CLAUDE_PLUGIN_ROOT === 'plugin-root' && environment.variables.CLAUDE_PLUGIN_DATA === 'plugin-data' && !('CODEX_HOME' in environment.variables) && environment.pluginRootLayout === 'plugins/cache/<marketplace>/<plugin>/<version>' && environment.pluginDataLayout === 'plugins/data/<plugin>-<marketplace>' && environment.hookCwd.execStartedInProject.process === 'project-dir' && JSON.stringify(environment.threadIdVariables) === '["CODEX_PROBE"]' && environment.sessionStartContextReachesModel === true, 'variables, layouts, working directory and context come from the SessionStart record');
  positive('features', derive([run('exec-default-features', [{ input: [] }], [hook('SessionStart', {})])]).features.pluginHooksRunWithoutFeaturesTable === true, 'hooks that ran without a [features] table read as running');
  const started = { events: [{ type: 'thread.started', thread_id: 't1' }] };
  const thread = derive([
    run('classic-baseline', [output(CALLS.env, 'CODEX_THREAD_ID=t1\nCODEX_SESSION_ID=t1\n')], [hook('SessionStart', { session_id: 't1' })], started),
    run('code-baseline', [output(CALLS.env, 'CODEX_THREAD_ID=t1\n')], [], started),
    run('spawn-code', [{ input: [] }, sub('t2', 't1')], [hook('SubagentStart', { session_id: 't1', agent_id: 't2' })], started),
  ]).threadId;
  positive('threadId', thread.hookSessionIdEqualsThread === true && thread.subagentHookSessionId === 'root-thread' && thread.subagentAgentIdIsSubagentThread === true && JSON.stringify(thread.classicShell.threadIdVariables) === '["CODEX_SESSION_ID","CODEX_THREAD_ID"]', 'idClass tells the root thread from a subagent thread');
  const agentFields = { session_id: 't1', agent_id: 't2', agent_type: 'default', turn_id: 'u2' };
  const side = derive([run('spawn-code', [{ input: [] }, subOutput('t2', 't1', CALLS.subTool, 'CODEX_THREAD_ID=t2\nCODEX_SESSION_ID=t1\n')], [
    hook('SubagentStart', agentFields),
    hook('PreToolUse', { ...agentFields, tool_name: 'Bash', tool_input: { command: `printf ${MARKERS.subagentShell}` } }),
    hook('SubagentStop', agentFields),
  ], started)]).subagents.codeMode;
  const ownView = JSON.stringify({ agentId: 'subagent-thread', agentType: 'default', sessionId: 'root-thread', turn: 'subagent-turn' });
  positive('subagents', JSON.stringify(side.shellPreToolUse) === ownView && JSON.stringify(side.subagentStop) === ownView && side.shellThreadVariables.CODEX_THREAD_ID === 'subagent-thread' && side.shellThreadVariables.CODEX_SESSION_ID === 'root-thread', 'tool and SubagentStop records of a subagent carry its own thread, its role and the root session');
  const skills = derive([lists, run('classic-baseline', [{ instructions: 'skills: p:probe-skill' }])]).skills;
  positive('skills', skills.namespaced === true && skills.listedInModelInstructions === true && skills.pluginIdFormat === '<plugin>@<marketplace>' && JSON.stringify(skills.pluginSkillNames) === '["<plugin>:<skill>"]', 'plugin skills are read as namespaced <plugin>:<skill>');
  const roleStart = (type) => hook('SubagentStart', { agent_type: type, agent_id: `a-${type}` });
  const spawnTool = { type: 'namespace', name: 'collaboration', tools: [{ type: 'function', name: 'spawn_agent', parameters: { properties: { agent_type: { description: 'home-role: x\nproject-role: y\ntwin-role: z' } } } }] };
  const roles = derive([
    run('roles-code', [{ tools: [spawnTool], input: [] }, sub('a1', 't1', [{ type: 'message', content: TWIN_ROLE.project }])], ['home-role', 'project-role', 'twin-role'].map(roleStart)),
    run('roles-classic', [{ input: [] }], ['home-role', 'project-role', 'twin-role'].map(roleStart)),
    run('role-sandbox-code', [{ input: [] }], [
      hook('PreToolUse', { tool_name: 'Bash', agent_type: 'home-role', tool_input: { command: MARKERS.subagentShell } }),
      hook('PreToolUse', { tool_name: 'apply_patch', agent_type: 'home-role', tool_input: { command: FILES.subPatch } }),
    ]),
  ], [FILES.subShell, FILES.subPatch]).agentRoles;
  const readOnlyRole = roles.sandbox.parentDangerFullAccess.codeMode.readOnlyRole;
  positive('agentRoles', roles.sources.codexHomeAgentsDirectory === true && roles.sources.projectCodexAgentsDirectory === true && roles.sources.pluginAgentsDirectory === false && roles.sameNameWinner === 'project' && roles.sameOnClassicSurface === true && JSON.stringify(roles.listedInSpawnSchema) === '["home-role","project-role","twin-role"]', 'role sources, the schema listing and the same-name winner come from the spawned roles');
  positive('agentRoles', readOnlyRole.shellWrite === true && readOnlyRole.patchWrite === true && readOnlyRole.patchHooked === true && JSON.stringify(readOnlyRole.toolHookAgentTypes) === '["home-role"]', 'writesOf reads the writes of a read-only role from the project files');
  const fn = (name) => ({ type: 'function', name });
  const surfaces = derive([
    run('classic-baseline', [{ tools: [fn('exec_command')] }]),
    run('code-baseline', [{ tools: [{ type: 'function', name: 'exec', description: '### `apply_patch`\n### `exec_command`' }] }]),
    run('gpt55-baseline', [{ tools: [{ type: 'custom', name: 'apply_patch' }, fn('exec_command')] }]),
    run('app-rui', []),
  ]).toolSurfaces;
  positive('toolSurfaces', JSON.stringify(surfaces.classic) === '["exec_command"]' && JSON.stringify(surfaces.codeModeNested) === '["apply_patch","exec_command"]' && surfaces.applyPatchOffered.classic === false && surfaces.applyPatchOffered.codeMode === true && surfaces.applyPatchOffered.gpt55 === true && surfaces.updatePlanOffered === false, 'offered tools and nested code-mode tools per surface');
  const shellHooks = [hook('PreToolUse', { tool_name: 'Bash', tool_input: { command: 'x' } }), hook('PostToolUse', { tool_name: 'Bash', tool_response: 'out' })];
  const toolHooks = derive([
    run('classic-baseline', [{ input: [] }], shellHooks),
    run('code-baseline', [{ input: [] }], shellHooks),
    run('gpt55-baseline', [{ input: [] }], shellHooks),
    run('code-patch', [{ input: [] }], [hook('PreToolUse', { tool_name: 'apply_patch', tool_input: { command: '*** Begin Patch\n' } })]),
  ]).toolHooks;
  const perSurface = (value) => JSON.stringify({ classic: value, codeMode: value, gpt55: value });
  positive('toolHooks', toolHooks.execCommand.classic === 'Bash' && JSON.stringify(toolHooks.execCommand.inputKeys) === perSurface(['command']) && toolHooks.applyPatch.codeMode === 'apply_patch' && toolHooks.applyPatch.patchTextIn === 'tool_input.command' && JSON.stringify(toolHooks.postToolUseResponseType) === perSurface('string'), 'tool names, input shapes and PostToolUse response types per surface come from the tool hook records');
  const deny = derive(gateRuns()).deny;
  positive('deny', deny.codeMode.bashJson.blocked === true && deny.classic.bashJson.reasonReachesModel === true && deny.subagent.codeMode.applyPatchJson.blocked === true && deny.subagent.codeMode.applyPatchJson.deniedPayloadAgentType === 'default' && deny.subagent.codeMode.spawnJson.blocked === true, 'root and subagent denies read the reason from the denied call output');
  positive('stop', derive([blockRun('stop-continue-false')]).stop.classic.continueFalse.blocks === true, 'an extra request carrying the block reason is a Stop block');
  covered.add('subagentStop');
  const rui = derive([
    run('classic-rui', [{ tools: [{ type: 'function', name: 'request_user_input', parameters: { properties: { questions: { description: 'do not exceed 3 questions', items: { properties: { options: { description: 'Provide 2-3 options' } } } } } } }], input: [] }, { input: [{ type: 'function_call_output', call_id: CALLS.rui, output: 'request_user_input is unavailable in Default mode' }] }]),
    run('code-rui', [{ input: [] }]),
    { ...run('app-rui', [output(CALLS.ruiCodePlan, '{"answers":{"q":{"answers":["A"]}}}')]), serverRequests: [{ method: 'item/tool/requestUserInput', params: { threadId: 'b', questions: [] } }], result: { threads: { classic: 'a', code: 'b' } } },
  ]).requestUserInput;
  positive('requestUserInput', rui.exec.classic === 'unavailable' && Boolean(rui.exec.codeMode.unverified) && rui.appServer.codeMode.planMode === 'server-request' && rui.appServer.classic.planMode === 'none' && rui.appServer.codeMode.answerShape === 'answers.<question id>.answers[]' && rui.maxQuestions === 3 && rui.optionsPerQuestion === '2-3', 'availability, Plan-mode server requests and limits come from the tool schema and the answers');
  const plan = derive([run('app-trust', [], [
    hook('UserPromptSubmit', { prompt: PROMPTS.makePlan, turn_id: 'u1', permission_mode: 'bypassPermissions' }),
    hook('PreToolUse', { tool_name: 'Bash', turn_id: 'u1', permission_mode: 'bypassPermissions', tool_input: { command: `echo ${MARKERS.planTool}` } }),
    hook('UserPromptSubmit', { prompt: TUI_STRINGS.approvalPrompt, turn_id: 'u2', permission_mode: 'bypassPermissions' }),
    hook('UserPromptSubmit', { prompt: PROMPTS.makePlanOnRequest, turn_id: 'u3', permission_mode: 'default' }),
  ], { result: { planItemDetails: [{ type: 'plan', text: `- ${MARKERS.planStep}` }], planMethods: ['item/plan/delta'] } })]).planMode;
  positive('planMode', plan.proposedPlanItemType === 'plan' && plan.planItemCarriesOnlyThePlan === true && plan.approvalPromptReachesUserPromptSubmit === true && JSON.stringify(plan.planTurnPermissionModes) === JSON.stringify({ defaultThread: ['bypassPermissions'], onRequestWorkspaceWriteThread: ['default'] }) && plan.planToolHooked === true && plan.userPromptSubmitCarriesMode === false, 'the plan item, the approval prompt and the plan-turn permission modes come from the trusted app-server run');
  const approval = derive([run('app-trust', [], [], { result: {} }), run('subagent-message-root', [{ input: [] }, subOutput('t2', 't1', CALLS.rootMessage, ''), subOutput('t2', 't1', CALLS.rootFollowup, "Follow-up tasks can't target the root agent"), { input: [{ type: 'agent_message', content: [{ type: 'encrypted_content', encrypted_content: TUI_STRINGS.approvalPrompt }] }] }])]).planMode.subagentApprovalText;
  positive('planMode', approval.sendMessageToRoot.accepted === true && approval.followupTaskToRoot.accepted === false && JSON.stringify(approval.rootReceivesTextAs) === '["agent_message"]' && approval.rootUserPromptSubmitsWithText === 0, 'a subagent message to the root is read from the call replies and the root input');
  const summary = (status) => [{ key: 'p@m:hooks/hooks.json:pre_tool_use:0:0', event: 'preToolUse', trustStatus: status, currentHash: 'sha256:aa' }];
  const trust = derive([
    run('app-untrusted-turn', [{ input: [] }], [], { notices: [], hookNotifications: [], result: { hooks: { data: [{ errors: [] }] } } }),
    run('app-trust', [], [], { hookNotifications: [{ method: 'hook/completed', eventName: 'stop', status: 'completed', source: 'plugin' }], result: { before: summary('untrusted'), after: summary('trusted'), trustConfigLines: ['[hooks.state."p@m:hooks/hooks.json:pre_tool_use:0:0"]', 'trusted_hash = "sha256:aa"'], afterScriptEdit: summary('trusted'), afterSemanticEdit: summary('trusted'), semanticEditRan: true, afterGroupAppend: [...summary('trusted'), { key: 'p@m:hooks/hooks.json:pre_tool_use:7:0', event: 'preToolUse', trustStatus: 'untrusted' }] } }),
  ]).hookTrust;
  positive('hookTrust', trust.untrustedHooksRun === false && trust.untrustedTurnReachedModel === true && JSON.stringify(trust.statusesBeforeTrust) === '["untrusted"]' && JSON.stringify(trust.statusesAfterTrust) === '["trusted"]' && trust.keyPattern === '<plugin>@<marketplace>:<hooks file>:<event_snake_case>:<group index>:<hook index>' && trust.storage === 'config.toml [hooks.state."<key>"] trusted_hash' && trust.semanticScriptEditRunsWithoutRetrust === true && JSON.stringify(trust.groupAppendUntrusted) === '["pre_tool_use:7:0:untrusted"]', 'statuses, key pattern, storage and the edit consequences come from the trust listings');
  const permission = derive([
    run('app-permission', [], [hook('PermissionRequest', { tool_input: { command: 'x' } })], { serverRequests: [{ method: 'item/commandExecution/requestApproval', params: {} }] }),
    run('permission-request', [output(CALLS.escalate, 'rejected: approval policy is Never')]),
  ]).permissionRequest;
  positive('permissionRequest', permission.appServerOnRequest === true && permission.execForcesNeverApproval === true && permission.execPermissionRequestHooks === 0 && JSON.stringify(permission.clientApprovalRequest) === '["item/commandExecution/requestApproval"]', 'the app-server hook, the client request and the exec refusal are read from their runs');
  const compaction = derive([run('compact-auto', [], [hook('PreCompact', { trigger: 'auto' }), hook('PostCompact', { trigger: 'auto' }), hook('SessionStart', { source: 'compact' })])]).compaction;
  positive('compaction', JSON.stringify(compaction.auto) === JSON.stringify({ preCompactTrigger: ['auto'], postCompactFired: true, postCompactTrigger: ['auto'], sessionStartSources: ['compact'] }), 'triggers and the SessionStart source come from the compaction hooks');
  const interrupt = derive([run('app-interrupt-compact', [], [hook('Interrupt', {})], { result: { interruptStatus: { turn: { status: 'interrupted' } } } })]).interrupt;
  positive('interrupt', interrupt.hookFired === true && interrupt.turnStatus === 'interrupted', 'the Interrupt hook and the turn status come from the interrupt run');
  const installation = (version) => `/h/codex-home/plugins/cache/m/p/${version}`;
  const recorder = (version, rootVersion = version) => ({ script: `${installation(version)}/hooks/record.js`, env: { CLAUDE_PLUGIN_ROOT: installation(rootVersion), PLUGIN_ROOT: installation(rootVersion) } });
  const updateHooks = [
    hook('SessionStart', { source: 'startup' }, { at: '15.000', ...recorder('0.0.1') }),
    hook('UserPromptSubmit', {}, { at: '16.000', ...recorder('0.0.1') }),
    hook('UserPromptSubmit', {}, { at: '35.000', ...recorder('0.1.0') }),
    hook('UserPromptSubmit', {}, { at: '36.000', label: MARKERS.updateAddedHook, ...recorder('0.1.0') }),
    hook('SessionStart', { source: 'resume' }, { at: '45.000', ...recorder('0.1.0') }),
    hook('UserPromptSubmit', {}, { at: '46.000', ...recorder('0.1.0', '0.0.1') }),
  ];
  const runs = (status) => [{ method: 'hook/completed', eventName: 'userPromptSubmit', status, source: 'plugin' }];
  const updateResult = (resumed) => ({
    fromVersions: ['0.0.1'],
    toVersion: '0.1.0',
    installedAfterUpdate: ['0.1.0'],
    update: { via: 'app-server plugin/install' },
    listedAfterUpdate: [{ trustStatus: 'modified' }],
    marks: { beforeUpdateStart: 10, beforeUpdateEnd: 20, loadedStart: 21, loadedEnd: 29, retrustedStart: 30, retrustedEnd: 39, resumedStart: 40, resumedEnd: 50 },
    hookRuns: { beforeUpdate: runs('completed'), loadedAfterUpdate: runs('failed'), loadedAfterRetrust: runs('completed') },
    resumed,
  });
  const update = derive([run('app-plugin-update', [], updateHooks, { result: updateResult({ resumed: true, hookRuns: runs('completed') }) })]).pluginUpdate;
  positive('pluginUpdate', update.installedVia === 'app-server plugin/install' && update.oldInstallationRemoved === true && JSON.stringify(update.hookTrustAfterUpdate) === '["modified"]'
    && JSON.stringify(update.loadedThread.beforeUpdate.recorders) === '["old"]' && JSON.stringify(update.loadedThread.beforeUpdate.sessionStartSources) === '["startup"]'
    && JSON.stringify(update.loadedThread.afterUpdate.recorders) === '[]' && JSON.stringify(update.loadedThread.afterUpdate.hookRunStatuses) === '["failed"]'
    && JSON.stringify(update.loadedThread.afterTrust.recorders) === '["new"]' && JSON.stringify(update.loadedThread.afterTrust.sessionStartSources) === '[]'
    && JSON.stringify(update.resumedThread.recorders) === '["new"]' && JSON.stringify(update.resumedThread.sessionStartSources) === '["resume"]'
    && update.loadedThread.beforeUpdate.addedHookRan === false && update.loadedThread.afterTrust.addedHookRan === true && update.resumedThread.addedHookRan === false
    && JSON.stringify(update.loadedThread.afterTrust.pluginRootVariables) === '["own-installation"]' && JSON.stringify(update.resumedThread.pluginRootVariables) === '["other-installation","own-installation"]',
  'the installation that runs in the loaded and in the resumed thread is read from the recorder path inside each phase, the added hook from its label, and the plugin-root variables against the recorder installation');
  const failedResume = derive([run('app-plugin-update', [], updateHooks, { result: updateResult({ resumed: false, error: 'thread is held' }) })]).pluginUpdate;
  check(Boolean(failedResume.resumedThread.unverified) && !JSON.stringify(failedResume).includes('thread is held'), 'a failed resume reads unverified without carrying the error text');
  const missing = analyze.FACT_KEYS.filter((key) => !covered.has(key));
  check(missing.length === 0, `every fact group has a synthetic positive derivation${missing.length ? `: missing ${missing.join(', ')}` : ''}`);
}

function scenarioChecks() {
  let ordered = null;
  try {
    ordered = probe.orderedScenarios();
  } catch (error) {
    ordered = error.message;
  }
  const names = probe.SCENARIOS.map((scenario) => scenario.name);
  check(Array.isArray(ordered), `orderedScenarios accepts the scenario table${Array.isArray(ordered) ? '' : `: ${ordered}`}`);
  if (Array.isArray(ordered)) {
    check(ordered.length === names.length && JSON.stringify(ordered.map((scenario) => scenario.name).sort()) === JSON.stringify([...names].sort()) && new Set(names).size === names.length, 'orderedScenarios is a permutation of SCENARIOS with unique names');
    const firstGrant = ordered.findIndex((scenario) => scenario.grantsHookTrust);
    const untrusted = ordered.map((scenario, index) => [scenario, index]).filter(([scenario]) => scenario.needsUntrustedHooks);
    check(firstGrant > 0 && untrusted.length >= 2 && untrusted.every(([, index]) => index < firstGrant), 'every untrusted-hook scenario runs before the first trust grant');
  }
  check(JSON.stringify([...contract.SCENARIO_NAMES].sort()) === JSON.stringify([...names].sort()), 'contract.SCENARIO_NAMES names every probe scenario exactly once');
  let refused = false;
  try {
    analyze.byName([])['no-such-scenario'];
  } catch {
    refused = true;
  }
  check(refused, 'the analysis refuses to read a scenario the contract does not name');
  let threw = null;
  try {
    analyze.deriveFacts(contract.SCENARIO_NAMES.map((name) => run(name, [{ input: [] }])), ctxOf());
  } catch (error) {
    threw = error.message;
  }
  check(threw === null, `the analysis reads only scenario names the contract holds${threw ? `: ${threw}` : ''}`);
}

function parserChecks() {
  let rejected = 0;
  for (const argv of [['--record', '--check'], ['--timeout', '0'], ['--bogus']]) {
    try {
      probe.parseArgs(argv);
    } catch {
      rejected += 1;
    }
  }
  check(rejected === 3, 'probe argument parser rejects conflicting, invalid and unknown flags');
  const respond = probe.makeResponder({ main: [[{ type: 'message', text: 'main-1' }], [{ type: 'message', text: 'main-2' }]], sub: [[{ type: 'message', text: 'sub-1' }]] });
  const subReply = respond({ client_metadata: { thread_id: 't2', 'x-codex-parent-thread-id': 't1' }, input: [] });
  const mainReply = respond({ client_metadata: { thread_id: 't1' }, input: [] });
  const markerOnly = respond({ client_metadata: { thread_id: 't3' }, input: [{ type: 'message', role: 'user', content: 'PROBE_SUBAGENT_TASK' }] });
  check(subReply[0].text === 'sub-1' && mainReply[0].text === 'main-1' && markerOnly[0].text === 'main-2', 'responder routes subagent requests by their parent-thread metadata only');
  const routed = probe.makeResponder({ main: [[{ type: 'message', text: 'm' }]], sub: [[{ type: 'message', text: 's' }]], grand: [[{ type: 'message', text: 'g' }]] });
  routed({ client_metadata: { thread_id: 'r' }, input: [] });
  const childReply = routed({ client_metadata: { thread_id: 'c', 'x-codex-parent-thread-id': 'r' }, input: [] });
  const grandReply = routed({ client_metadata: { thread_id: 'g', 'x-codex-parent-thread-id': 'c' }, input: [] });
  check(childReply[0].text === 's' && grandReply[0].text === 'g', 'responder routes a grandchild by its parent thread');
  const throws = (fn) => {
    try {
      fn();
      return false;
    } catch {
      return true;
    }
  };
  check(probe.sessionIdFrom('{"session_id":7}') === 7 && probe.sessionIdFrom('Process running with session ID 12') === 12 && throws(() => probe.sessionIdFrom('"session_id":"s-1a2b"')) && throws(() => probe.sessionIdFrom('')), 'sessionIdFrom reads parsed JSON first and throws instead of guessing');
  check(probe.agentIdFrom('{"agent_id":"a1","nickname":"x"}') === 'a1' && probe.agentIdFrom('noise "target":"a2"') === 'a2' && throws(() => probe.agentIdFrom('no id here')), 'agentIdFrom reads parsed JSON first and throws on a miss');
}

function isolationChecks() {
  process.env.PROBE_SENTINEL = 'leak';
  const env = probe.baseEnv({ home: '/s/home', codexHome: '/s/codex-home' });
  delete process.env.PROBE_SENTINEL;
  const expected = ['ALL_PROXY', 'CODEX_HOME', 'GIT_CONFIG_NOSYSTEM', 'HOME', 'HTTPS_PROXY', 'HTTP_PROXY', 'LANG', 'NO_PROXY', 'PATH', 'SHELL', 'TMPDIR', 'all_proxy', 'http_proxy', 'https_proxy', 'no_proxy'];
  check(JSON.stringify(Object.keys(env).sort()) === JSON.stringify(expected.sort()) && env.PATH === (process.env.PATH || '/usr/bin:/bin') && env.TMPDIR === (process.env.TMPDIR || os.tmpdir()), 'baseEnv passes exactly the sandbox key set, and only PATH and TMPDIR come from the caller');
  check(env.HOME === '/s/home' && env.CODEX_HOME === '/s/codex-home', 'baseEnv points HOME and CODEX_HOME into the sandbox');
  check(['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'].every((name) => env[name] === 'http://127.0.0.1:9') && env.NO_PROXY === '127.0.0.1,localhost,::1' && env.no_proxy === '127.0.0.1,localhost,::1', 'baseEnv sends every proxy variable to a closed loopback port and exempts only loopback');
  const bare = { PATH: '/usr/bin:/bin', HOME: WORK };
  const inherited = spawnSync(process.execPath, [path.join(PROBE, 'probe.js')], { env: { ...bare, CODEX_HOME: 'x' }, encoding: 'utf8' });
  check(inherited.status === 2 && /inherited CODEX_HOME/.test(inherited.stderr), 'probe.js refuses an inherited CODEX_HOME before resolving Codex');
  const only = spawnSync(process.execPath, [path.join(PROBE, 'probe.js'), '--record', '--only', 'x'], { env: bare, encoding: 'utf8' });
  check(only.status === 2 && /--record and --check measure every scenario/.test(only.stderr), 'probe.js refuses --record with --only before resolving Codex');
  const fake = path.join(WORK, 'fake-codex');
  const envOut = path.join(WORK, 'fake-codex-env.txt');
  fs.writeFileSync(fake, `#!/bin/sh\nenv > ${JSON.stringify(envOut)}\necho "codex-cli 9.9.9"\n`, { mode: 0o755 });
  process.env.PROBE_SENTINEL = 'leak';
  const resolved = codexBinary.resolveCodex(fake);
  delete process.env.PROBE_SENTINEL;
  const seen = fs.existsSync(envOut) ? fs.readFileSync(envOut, 'utf8') : '';
  check(resolved.version === '9.9.9' && !/PROBE_SENTINEL/.test(seen) && /^HOME=.*zensu-hookprobe-version-/m.test(seen), 'resolveCodex runs --version with a minimal environment and a throwaway HOME');
  const failing = path.join(WORK, 'failing-codex');
  fs.writeFileSync(failing, '#!/bin/sh\necho boom >&2\nexit 3\n', { mode: 0o755 });
  let failure = '';
  try {
    codexBinary.resolveCodex(failing);
  } catch (error) {
    failure = error.message;
  }
  check(/exit status 3/.test(failure) && /boom/.test(failure), 'resolveCodex reports the exit status and the stderr tail of a failing --version');
}

function nativeBinaryChecks() {
  const throws = (fn) => {
    try {
      fn();
      return false;
    } catch {
      return true;
    }
  };
  const tree = (target) => {
    fs.mkdirSync(target, { recursive: true, mode: 0o755 });
    fs.chmodSync(target, 0o755);
    return target;
  };
  const file = (target, content, mode) => {
    tree(path.dirname(target));
    fs.writeFileSync(target, content, { mode });
    fs.chmodSync(target, mode);
    return fs.realpathSync(target);
  };
  const versionScript = (version) => `#!/bin/sh\necho "codex-cli ${version}"\n`;
  const npmPackage = (root, name, version) => {
    file(path.join(root, 'package.json'), JSON.stringify({ name, version }), 0o644);
    return file(path.join(root, 'bin', 'codex.js'), versionScript(version), 0o755);
  };
  const platform = (scope, name, version) => {
    file(path.join(scope, name, 'package.json'), JSON.stringify({ name: '@openai/codex', version: `${version}-test` }), 0o644);
    return file(path.join(scope, name, 'vendor', 'test-triple', 'bin', 'codex'), versionScript(version), 0o755);
  };
  const scope = path.join(fs.mkdtempSync(path.join(WORK, 'npm-')), 'node_modules', '@openai');
  const launcher = npmPackage(path.join(scope, 'codex'), '@openai/codex', '9.9.9');
  const nested = path.join(scope, 'codex', 'node_modules', '@openai');
  platform(nested, 'codex-a-stale', '9.9.8');
  const binary = platform(nested, 'codex-b-platform', '9.9.9');
  const hoisted = platform(scope, 'codex-c-hoisted', '7.7.7');
  const found = (version) => codexBinary.nativeBinary(launcher, version).binary;
  check(found('9.9.9') === binary, 'nativeBinary skips a platform candidate whose --version disagrees and returns the one that matches');
  check(found('7.7.7') === hoisted, 'nativeBinary finds a hoisted platform package beside the Codex package');
  check(found('1.2.3') === null, 'nativeBinary keeps no candidate when every --version disagrees');
  check(throws(() => codexBinary.nativeBinary(launcher)) && throws(() => codexBinary.nativeBinary(launcher, '')), 'nativeBinary refuses to run without the version the binary must report');
  fs.chmodSync(path.dirname(binary), 0o775);
  const groupWritableDirectory = found('9.9.9');
  fs.chmodSync(path.dirname(binary), 0o755);
  fs.chmodSync(binary, 0o757);
  const otherWritableFile = found('9.9.9');
  fs.chmodSync(binary, 0o755);
  check(groupWritableDirectory === null && otherWritableFile === null && found('9.9.9') === binary, 'nativeBinary skips a candidate in a group-writable directory and one that others can write');
  const foreign = fs.mkdtempSync(path.join(WORK, 'foreign-'));
  const foreignLauncher = npmPackage(foreign, 'not-codex', '9.9.9');
  platform(path.join(foreign, 'node_modules', '@openai'), 'codex-planted', '9.9.9');
  const loose = path.join(WORK, 'loose-codex');
  fs.writeFileSync(loose, versionScript('9.9.9'), { mode: 0o755 });
  const foreignResult = codexBinary.nativeBinary(foreignLauncher, '9.9.9');
  const looseResult = codexBinary.nativeBinary(loose, '9.9.9');
  check(foreignResult.binary === null && foreignResult.packageRoot === null && looseResult.binary === null && looseResult.packageRoot === null, 'nativeBinary walks nothing unless the launcher sits in the @openai/codex package');
  const resolved = schemas.resolveNative(launcher);
  check(resolved.codex.version === '9.9.9' && resolved.binary === binary, 'the schema extractor resolves the native binary of the version its launcher reports');
  const bare = npmPackage(path.join(fs.mkdtempSync(path.join(WORK, 'bare-')), 'node_modules', '@openai', 'codex'), '@openai/codex', '9.9.9');
  let refusal = '';
  try {
    schemas.resolveNative(bare);
  } catch (error) {
    refusal = error.message;
  }
  check(/no native codex binary that reports version 9\.9\.9/.test(refusal), 'the schema extractor refuses a launcher without a matching native binary');
}

async function appServerClientChecks() {
  const { AppServerClient } = require(path.join(PROBE, 'app-server-client.js'));
  const env = { PATH: process.env.PATH || '/usr/bin:/bin' };
  const script = (name, body) => {
    const target = path.join(WORK, name);
    fs.writeFileSync(target, `#!/bin/bash\n${body}\n`, { mode: 0o755 });
    return target;
  };
  const before = processes.CHILDREN.size;
  const stubborn = new AppServerClient({ codex: script('stubborn-app-server', "trap '' TERM; echo ready; while true; do sleep 1; done"), env, cwd: WORK });
  const trackedOnStart = processes.CHILDREN.size === before + 1;
  for (let i = 0; i < 200 && !stubborn.unparsed.includes('ready'); i += 1) await new Promise((resolve) => setTimeout(resolve, 25));
  const started = Date.now();
  const stubbornExit = await stubborn.close({ graceMs: 200, termMs: 500 });
  check(trackedOnStart && stubborn.unparsed.includes('ready') && stubbornExit.signal === 'SIGKILL' && !processes.groupAlive(stubborn.child) && processes.CHILDREN.size === before && Date.now() - started < 5000, 'AppServerClient tracks its own group and escalates EOF, SIGTERM and SIGKILL when the server ignores them');
  const crashing = new AppServerClient({ codex: script('crashing-app-server', 'read -r line; echo "fatal: probe crash" >&2; exit 3'), env, cwd: WORK });
  let failure = '';
  try {
    await crashing.initialize();
  } catch (error) {
    failure = error.message;
  }
  const crashExit = await crashing.close();
  let refused = '';
  try {
    await crashing.request('thread/start', {});
  } catch (error) {
    refused = error.message;
  }
  check(/app-server exited \(code 3, signal null\)/.test(failure) && /fatal: probe crash/.test(failure) && crashExit.code === 3 && !crashing.running() && /app-server exited/.test(refused) && processes.CHILDREN.size === before, 'AppServerClient rejects a pending request with the exit code and the stderr tail, and refuses requests after the exit');
}

async function runProcessChecks() {
  const env = { PATH: process.env.PATH || '/usr/bin:/bin' };
  const before = processes.CHILDREN.size;
  const plain = await probe.runProcess('/bin/bash', ['-c', 'sleep 30'], { env, cwd: WORK, timeoutMs: 300 });
  check(plain.timedOut && plain.signal === 'SIGTERM' && plain.ms < 3000 && processes.CHILDREN.size === before, 'runProcess stops a timed-out process group with SIGTERM and untracks it');
  const stubborn = await probe.runProcess('/bin/bash', ['-c', "trap '' TERM; sleep 30"], { env, cwd: WORK, timeoutMs: 1000 });
  check(stubborn.timedOut && stubborn.signal === 'SIGKILL' && stubborn.ms < 10000 && processes.CHILDREN.size === before, 'runProcess escalates a timed-out group that ignores SIGTERM to SIGKILL');
  const marker = path.join(WORK, 'spawned-while-stopping');
  processes.state.stopping = true;
  const refused = await probe.runProcess(process.execPath, ['-e', `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'x')`], { env, cwd: WORK, timeoutMs: 5000 });
  processes.state.stopping = false;
  check(refused.spawnError === 'the probe is stopping' && !fs.existsSync(marker), 'runProcess starts no process while the probe is stopping');
  const source = fs.readFileSync(path.join(PROBE, 'probe.js'), 'utf8');
  check(!/spawnSync|execSync|execFileSync/.test(source), 'probe.js starts every child asynchronously, through runProcess or the app-server client');
}

async function signalChecks() {
  const waitFor = async (cond, ms) => {
    const until = Date.now() + ms;
    while (Date.now() < until) {
      if (cond()) return true;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    return cond();
  };
  const groupGone = (pid) => {
    try {
      process.kill(-pid, 0);
      return false;
    } catch {
      return true;
    }
  };
  const interrupt = async (label, ignoreTerm, signals) => {
    const dir = fs.mkdtempSync(path.join(WORK, `signal-${label}-`));
    const tmp = path.join(dir, 'tmp');
    fs.mkdirSync(tmp);
    const pidFile = path.join(dir, 'codex.pid');
    const fake = path.join(dir, 'codex');
    const body = ['#!/bin/bash', 'if [ "$1" = "--version" ]; then echo "codex-cli 0.0.0"; exit 0; fi'];
    if (ignoreTerm) body.push("trap '' TERM");
    body.push(`echo "$$" > ${JSON.stringify(pidFile)}`, 'sleep 30 & wait', '');
    fs.writeFileSync(fake, body.join('\n'), { mode: 0o755 });
    const child = spawn(process.execPath, [path.join(PROBE, 'probe.js'), '--codex', fake], { env: { PATH: process.env.PATH || '/usr/bin:/bin', TMPDIR: tmp }, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', (chunk) => {
      output += chunk;
    });
    child.stderr.on('data', (chunk) => {
      output += chunk;
    });
    const exited = new Promise((resolve) => child.once('close', (code, signal) => resolve({ code, signal })));
    const started = await waitFor(() => fs.existsSync(pidFile) && fs.readFileSync(pidFile, 'utf8').trim() !== '', 20000);
    const pid = started ? Number(fs.readFileSync(pidFile, 'utf8').trim()) : null;
    const sentAt = Date.now();
    for (const [index, signal] of signals.entries()) {
      if (index) await new Promise((resolve) => setTimeout(resolve, 300));
      child.kill(signal);
    }
    const exit = await Promise.race([exited, new Promise((resolve) => setTimeout(() => resolve({ code: 'hung', signal: null }), 15000))]);
    const elapsed = Date.now() - sentAt;
    const gone = pid ? await waitFor(() => groupGone(pid), 3000) : false;
    if (exit.code === 'hung') child.kill('SIGKILL');
    if (pid && !gone) {
      try {
        process.kill(-pid, 'SIGKILL');
      } catch {}
    }
    const sandboxes = fs.readdirSync(tmp).filter((name) => name.startsWith('zensu-hookprobe-'));
    const tail = output.trim().split('\n').slice(-2).join(' | ');
    return { started, exit, elapsed, gone, sandboxes, tail };
  };
  const once = await interrupt('once', false, ['SIGINT']);
  check(once.started && once.exit.code === 130 && once.gone && once.sandboxes.length === 0, `SIGINT stops the running codex group, removes the sandbox and exits 130${once.started && once.exit.code === 130 && once.gone && once.sandboxes.length === 0 ? '' : `: started ${once.started}, exit ${once.exit.code}, group gone ${once.gone}, sandboxes left ${once.sandboxes.length}, ${once.tail}`}`);
  const twice = await interrupt('twice', true, ['SIGINT', 'SIGINT']);
  check(twice.started && twice.exit.code === 130 && twice.gone && twice.elapsed < 2500, `a second SIGINT kills a group that ignores SIGTERM and exits 130 without waiting out the grace period${twice.started && twice.exit.code === 130 && twice.gone && twice.elapsed < 2500 ? '' : `: started ${twice.started}, exit ${twice.exit.code}, group gone ${twice.gone}, ${twice.elapsed} ms, ${twice.tail}`}`);
}

function partialRunChecks() {
  const isUnverified = (value) => Boolean(value && typeof value === 'object' && typeof value.unverified === 'string');
  const started = { events: [{ type: 'thread.started', thread_id: 't1' }] };
  const thread = derive([
    run('classic-baseline', [output(CALLS.env, 'CODEX_THREAD_ID=t1\nCODEX_SESSION_ID=t1\n')], [hook('SessionStart', { session_id: 't1' })], started),
    run('code-baseline', [output(CALLS.env, 'CODEX_THREAD_ID=t1\n')], [], started),
  ]).threadId;
  check(thread.hookSessionIdEqualsThread === true && isUnverified(thread.subagentHookSessionId) && isUnverified(thread.subagentAgentIdIsSubagentThread), 'threadId subagent leaves read unverified without spawn-code');
  const lists = run('app-lists', [], [], { result: { hooks: { data: [{ hooks: [], errors: [], warnings: [] }] }, skills: { data: [{ skills: [{ name: 'p:probe-skill', pluginId: 'p@m' }] }] } } });
  const skills = derive([lists]).skills;
  check(skills.namespaced === true && isUnverified(skills.listedInModelInstructions), 'skills.listedInModelInstructions reads unverified without classic-baseline');
  const roles = derive([run('roles-code', [{ input: [] }]), run('roles-classic', [{ input: [] }])]).agentRoles;
  check(isUnverified(roles.agentTypeParameterWithoutRoles) && isUnverified(roles.defaultAgentType), 'agentRoles leaves of code-baseline and spawn-code read unverified without those runs');
  const shellHooks = [hook('PreToolUse', { tool_name: 'Bash', tool_input: { command: 'x' } }), hook('PostToolUse', { tool_name: 'Bash', tool_response: 'out' })];
  const toolHooks = derive([run('classic-baseline', [{ input: [] }], shellHooks), run('code-baseline', [{ input: [] }], [shellHooks[0]]), run('code-patch', [{ input: [] }])]).toolHooks;
  check(isUnverified(toolHooks.execCommand.inputKeys.gpt55) && isUnverified(toolHooks.postToolUseResponseType.gpt55) && isUnverified(toolHooks.postToolUseResponseType.codeMode) && toolHooks.postToolUseResponseType.classic === 'string', 'per-surface tool hook leaves read unverified without their run or its PostToolUse record');
}

function reviewerRoleChecks() {
  const shipped = fs.readFileSync(path.join(ROOT, 'plugins', 'zensu', 'agents', 'zensu-code-reviewer.toml'), 'utf8');
  const tables = (text) => text.split('\n').filter((line) => /^\[[^\]]+\]$/.test(line.trim())).map((line) => line.trim());
  const shippedTables = tables(shipped.slice(shipped.lastIndexOf("\n'''") + 4));
  const role = probe.reviewerProfileRole();
  const dropped = probe.reviewerProfileRole({ dropTables: ['agents'] });
  const reshaped = (text) => /^name = "tools-role"$/m.test(text) && text.includes(`developer_instructions = ${JSON.stringify(contract.TOOLS_ROLE.marker)}`) && !text.includes("'''");
  check(shippedTables.includes('[agents]') && reshaped(role) && JSON.stringify(tables(role)) === JSON.stringify(shippedTables) && /^max_depth = /m.test(role), 'reviewerProfileRole renames the shipped reviewer role, replaces its instructions and keeps every table');
  check(reshaped(dropped) && JSON.stringify(tables(dropped)) === JSON.stringify(shippedTables.filter((table) => table !== '[agents]')) && !/max_depth/.test(dropped), 'reviewerProfileRole drops the [agents] table on request');
}

function conditionChecks(resultsByVersion) {
  const note = 'hooks trusted through config/batchWrite before the run';
  const current = probe.conditionsOf({ sandbox: { root: WORK } }, probe.SCENARIOS, { packageRoot: null });
  const trustedRuns = ['exec-trusted', 'deny-classic-bash-json-trusted', 'stop-decision-block-trusted'];
  check(trustedRuns.every((name) => (current.scenarioOverrides[name] || []).includes(note)) && !(current.scenarioOverrides['exec-untrusted'] || []).includes(note), 'the runs whose setup grants hook trust say so in their conditions, and the untrusted run does not');
  const withoutLauncher = (conditions) => ({ ...conditions, launcher: undefined });
  for (const [version, results] of Object.entries(resultsByVersion)) {
    const drift = analyze.diffPaths(withoutLauncher(results.conditions || {}), withoutLauncher(current));
    check(drift.length === 0, `results/${version}.json conditions match the probe's scenario table${drift.length ? `: ${drift.slice(0, 3).join('; ')}` : ''}`);
  }
}

async function cleanupChecks() {
  const start = (script) => processes.track(spawn('/bin/bash', ['-c', script], { detached: true, stdio: 'ignore' }));
  const plain = start('sleep 30 & wait');
  const stubborn = start("trap '' TERM; sleep 30 & wait");
  await new Promise((resolve) => setTimeout(resolve, 300));
  const stopped = await processes.stopChildren({ graceMs: 1000 });
  const closed = await processes.settledWithin(Promise.all([plain.closed, stubborn.closed]), 3000);
  check(stopped === 2 && closed && !processes.groupAlive(plain.child) && !processes.groupAlive(stubborn.child), 'stopChildren stops whole process groups and escalates to SIGKILL');
  processes.untrack(plain);
  processes.untrack(stubborn);
}

function recorderChecks() {
  const recorder = path.join(PROBE, 'fixture', 'plugins', 'hookprobe', 'hooks', 'record.js');
  const fresh = (label) => fs.mkdtempSync(path.join(WORK, `${label}-`));
  const runRecorder = (args, payload, mode, dir = fresh('rec')) => spawnSync(process.execPath, [recorder, ...args], {
    input: JSON.stringify(payload),
    env: { PATH: process.env.PATH, PROBE_DIR: dir, PROBE_MODE: JSON.stringify(mode) },
    encoding: 'utf8',
  });
  const emitted = [];
  const deny = runRecorder(['PreToolUse'], { tool_name: 'Bash', tool_input: { command: 'touch x' } }, { deny: { tool: 'Bash', via: 'json', marker: 'M' } });
  const denyOut = parseJson(deny.stdout);
  emitted.push(['PreToolUse', denyOut]);
  check(deny.status === 0 && denyOut && denyOut.hookSpecificOutput.permissionDecision === 'deny' && denyOut.hookSpecificOutput.permissionDecisionReason === 'M Bash', 'recorder emits a JSON deny with the marker it was given');
  const oneDir = fresh('one');
  runRecorder(['PreToolUse'], { tool_name: 'Bash' }, {}, oneDir);
  const recordFiles = fs.readdirSync(path.join(oneDir, 'hooks'));
  check(recordFiles.length === 1 && recordFiles[0].endsWith('.json'), 'recorder writes one record per invocation and leaves no temporary file');
  const exit2 = runRecorder(['PreToolUse'], { tool_name: 'apply_patch', tool_input: { command: 'p' } }, { deny: { tool: ['apply_patch'], via: 'exit2', marker: 'M' } });
  check(exit2.status === 2 && /M apply_patch/.test(exit2.stderr), 'recorder denies through exit 2 with the reason on stderr');
  const pass = runRecorder(['PreToolUse'], { tool_name: 'Bash', tool_input: { command: 'x' } }, { deny: { tool: 'apply_patch', marker: 'M' } });
  check(pass.status === 0 && pass.stdout === '', 'recorder lets other tools through');
  const scoped = { deny: { tool: 'Bash', via: 'json', marker: 'M', scope: 'subagent' } };
  const rootCall = runRecorder(['PreToolUse'], { tool_name: 'Bash' }, scoped);
  const subCall = parseJson(runRecorder(['PreToolUse'], { tool_name: 'Bash', agent_id: 't2' }, scoped).stdout);
  check(rootCall.stdout === '' && subCall && subCall.hookSpecificOutput.permissionDecision === 'deny', 'a subagent-scoped deny lets the root thread through and denies a subagent');
  const labelDir = fresh('label');
  const labelled = runRecorder(['PreToolUse', 'bash-anchored'], { tool_name: 'Bash', tool_input: { command: 'x' } }, { deny: { tool: 'Bash', via: 'exit2', marker: 'M' } }, labelDir);
  const labelRecord = JSON.parse(fs.readFileSync(path.join(labelDir, 'hooks', fs.readdirSync(path.join(labelDir, 'hooks'))[0]), 'utf8'));
  check(labelled.status === 0 && labelled.stdout === '' && labelRecord.label === 'bash-anchored', 'a matcher-labelled recorder records its label and never denies');
  const stopDir = fresh('stop');
  const blocks = [1, 2, 3].map(() => runRecorder(['Stop'], { stop_hook_active: false }, { stop: { shape: 'decision-block', marker: 'M' } }, stopDir).stdout);
  emitted.push(['Stop', parseJson(blocks[0])]);
  check(/"decision":"block"/.test(blocks[0]) && /"decision":"block"/.test(blocks[1]) && blocks[2] === '', 'recorder blocks Stop twice and then allows it');
  const stopExit = runRecorder(['Stop'], {}, { stop: { shape: 'exit2', marker: 'M' } });
  check(stopExit.status === 2 && /M stop invocation 1: keep working\./.test(stopExit.stderr), 'recorder blocks Stop through exit 2 with the reason on stderr');
  const continueFalse = parseJson(runRecorder(['Stop'], {}, { stop: { shape: 'continue-false', marker: 'M' } }).stdout);
  const systemMessage = parseJson(runRecorder(['Stop'], {}, { stop: { shape: 'system-message', marker: 'M' } }).stdout);
  emitted.push(['Stop', continueFalse], ['Stop', systemMessage]);
  check(continueFalse && continueFalse.continue === false && /^M stop invocation 1/.test(continueFalse.stopReason) && systemMessage && systemMessage.continue === true && /^M stop invocation 1/.test(systemMessage.systemMessage), 'recorder emits the continue-false and system-message Stop shapes');
  const holdDir = fresh('hold');
  const holds = [1, 2].map(() => runRecorder(['SubagentStop'], { stop_hook_active: false }, { subagentStop: { shape: 'decision-block', marker: 'M', times: 1 } }, holdDir).stdout);
  emitted.push(['SubagentStop', parseJson(holds[0])]);
  check(/"decision":"block"/.test(holds[0]) && holds[1] === '', 'recorder holds SubagentStop for the requested number of invocations');
  const sessionContext = parseJson(runRecorder(['SessionStart'], { source: 'startup' }, { context: { sessionStart: 'CTX' } }).stdout);
  const promptContext = parseJson(runRecorder(['UserPromptSubmit'], { prompt: 'p' }, { context: { userPromptSubmit: 'PCTX' } }).stdout);
  emitted.push(['SessionStart', sessionContext], ['UserPromptSubmit', promptContext]);
  check(sessionContext && sessionContext.hookSpecificOutput.additionalContext === 'CTX' && promptContext && promptContext.hookSpecificOutput.additionalContext === 'PCTX', 'recorder injects SessionStart and UserPromptSubmit context on request');
  const resultsDir = path.join(PROBE, 'results');
  const versions = fs.existsSync(resultsDir) ? fs.readdirSync(resultsDir).filter((name) => /^\d+\.\d+\.\d+.*\.json$/.test(name)).map((name) => name.replace(/\.json$/, '')) : [];
  const schemaProblems = [];
  for (const version of versions) {
    for (const [event, object] of emitted) {
      const file = path.join(PROBE, 'schemas', version, `${event.replace(/([a-z])([A-Z])/g, '$1-$2').toLowerCase()}.command.output.json`);
      if (!object || !fs.existsSync(file)) {
        schemaProblems.push(`${version} ${event}: ${object ? 'no schema' : 'no output'}`);
        continue;
      }
      const schema = JSON.parse(fs.readFileSync(file, 'utf8'));
      const properties = schema.properties || {};
      for (const key of Object.keys(object)) if (!properties[key]) schemaProblems.push(`${version} ${event}: ${key}`);
      if (object.hookSpecificOutput && properties.hookSpecificOutput) {
        const ref = (properties.hookSpecificOutput.allOf || []).map((entry) => entry.$ref).find(Boolean) || properties.hookSpecificOutput.$ref;
        const definition = ref ? (schema.definitions || {})[ref.split('/').pop()] : properties.hookSpecificOutput;
        for (const key of Object.keys(object.hookSpecificOutput)) if (!definition || !(definition.properties || {})[key]) schemaProblems.push(`${version} ${event}: hookSpecificOutput.${key}`);
      }
    }
  }
  check(versions.length > 0 && schemaProblems.length === 0, `every key the recorder emits is declared in the output schema of every recorded version${schemaProblems.length ? `: ${schemaProblems.join(', ')}` : ''}`);
}

function citationChecks(text, resultsByVersion) {
  const start = text.indexOf('### Answers and decisions');
  const end = text.indexOf('\n### ', start + 1);
  const rows = start === -1 ? [] : text.slice(start, end === -1 ? undefined : end).split('\n').filter((line) => line.startsWith('| ') && !line.startsWith('| Question') && !/^\|\s*-/.test(line));
  check(rows.length >= 16, `docs/codex-port.md lists its question rows (${rows.length})`);
  const uncited = rows.filter((line) => !/<!-- facts(@[0-9.]+)?: /.test(line));
  check(uncited.length === 0, `every question row cites the facts it rests on${uncited.length ? `: ${uncited.map((line) => line.slice(0, 60)).join(' | ')}` : ''}`);
  const citations = [...text.matchAll(/<!-- facts(?:@([0-9][0-9.]*)?)?: (.*?) -->/g)];
  const problems = [];
  let resolved = 0;
  for (const [, version, body] of citations) {
    for (const entry of body.split(';').map((part) => part.trim()).filter(Boolean)) {
      const eq = entry.indexOf('=');
      if (eq < 1) {
        problems.push(`malformed citation ${entry}`);
        continue;
      }
      const key = entry.slice(0, eq).trim();
      const expected = parseJson(entry.slice(eq + 1).trim());
      if (expected === null && entry.slice(eq + 1).trim() !== 'null') {
        problems.push(`unparsable value in ${entry}`);
        continue;
      }
      if (version && !resultsByVersion[version]) {
        problems.push(`no results for ${version} (${key})`);
        continue;
      }
      for (const [recorded, results] of version ? [[version, resultsByVersion[version]]] : Object.entries(resultsByVersion)) {
        const actual = key.split('.').reduce((value, part) => (value && typeof value === 'object' ? value[part] : undefined), results.facts);
        if (JSON.stringify(actual) === JSON.stringify(expected)) resolved += 1;
        else problems.push(`${recorded} ${key}: cited ${JSON.stringify(expected)}, recorded ${JSON.stringify(actual)}`);
      }
    }
  }
  check(citations.length > 0 && problems.length === 0, `every facts citation resolves in its results files (${resolved} resolved${problems.length ? `; ${problems.slice(0, 6).join('; ')}` : ''})`);
}

function postResponses(port) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: '/v1/responses', method: 'POST' }, (res) => {
      let body = '';
      res.on('data', (chunk) => {
        body += chunk;
      });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.end(JSON.stringify({ input: [] }));
  });
}

async function mockChecks() {
  const seen = [];
  const mock = await startMockModel({
    respond: () => [
      { type: 'function_call', name: 'exec_command', arguments: { cmd: 'echo hi' }, namespace: 'functions', callId: 'call_fixed' },
      { type: 'custom_tool_call', name: 'exec', input: 'text("hi")' },
      { type: 'message', text: 'done' },
    ],
    onRequest: (request) => seen.push(request),
  });
  const post = await postResponses(mock.port);
  const get = await new Promise((resolve) => http.get({ host: '127.0.0.1', port: mock.port, path: '/v1/models' }, (res) => {
    res.resume();
    res.on('end', () => resolve(res.statusCode));
  }));
  await mock.close();
  const events = post.body.split('\n').filter((line) => line.startsWith('data: ')).map((line) => JSON.parse(line.slice(6)));
  const completed = events.find((event) => event.type === 'response.completed');
  const items = completed ? completed.response.output : [];
  check(post.status === 200 && items.length === 3, 'mock model streams a completed response with every scripted item');
  check(items[0] && items[0].type === 'function_call' && items[0].arguments === '{"cmd":"echo hi"}' && items[0].namespace === 'functions' && items[0].call_id === 'call_fixed', 'mock function_call carries JSON arguments, namespace and the scripted call_id');
  check(items[1] && items[1].type === 'custom_tool_call' && items[1].input === 'text("hi")' && Boolean(items[1].call_id), 'mock custom_tool_call carries raw input and a call_id');
  check(get === 404 && seen.some((request) => request.served === false) && seen.some((request) => request.served === true), 'mock model serves only POST /responses and reports both');
  const errors = [];
  const failing = await startMockModel({ respond: () => { throw new Error('scripted failure'); }, onError: (error) => errors.push(error) });
  const failed = await postResponses(failing.port);
  await failing.close();
  const badSpec = await startMockModel({ respond: () => [{ type: 'bogus' }], onError: (error) => errors.push(error) });
  await postResponses(badSpec.port);
  await badSpec.close();
  check(failed.status === 200 && errors.length === 2 && errors[0].stage === 'responder' && errors[0].message === 'scripted failure' && errors[1].stage === 'spec', 'mock model keeps its fallback stream and reports responder and spec errors out of band');
}

async function main() {
  const resultsDir = path.join(PROBE, 'results');
  const resultFiles = fs.existsSync(resultsDir) ? fs.readdirSync(resultsDir).filter((name) => name.endsWith('.json')).sort() : [];
  check(resultFiles.length >= 2, `at least two recorded Codex versions (${resultFiles.length})`);
  const verdicts = new Set();
  const resultsByVersion = {};
  for (const file of resultFiles) {
    const results = JSON.parse(fs.readFileSync(path.join(resultsDir, file), 'utf8'));
    resultsByVersion[results.codexVersion] = results;
    const problems = analyze.validateResults(results);
    check(problems.length === 0, `results/${file} validates${problems.length ? `: ${problems.join('; ')}` : ''}`);
    check(`${results.codexVersion}.json` === file, `results/${file} names its own version`);
    check(JSON.stringify(results.gate) === JSON.stringify(analyze.deriveGate(results.facts || {})), `results/${file} gate agrees with its facts`);
    verdicts.add(results.gate && results.gate.verdict);
    const schemaDir = path.join(PROBE, 'schemas', results.codexVersion);
    check(fs.existsSync(schemaDir) && fs.readdirSync(schemaDir).some((name) => name.endsWith('.json')), `schemas/${results.codexVersion}/ holds the extracted hook schemas`);
  }
  const schemaRoot = path.join(PROBE, 'schemas');
  for (const version of fs.existsSync(schemaRoot) ? fs.readdirSync(schemaRoot).sort() : []) {
    const schemaDir = path.join(schemaRoot, version);
    const schemaFiles = fs.readdirSync(schemaDir).filter((name) => name.endsWith('.json'));
    const titlesMatch = schemaFiles.length > 0 && schemaFiles.every((name) => JSON.parse(fs.readFileSync(path.join(schemaDir, name), 'utf8')).title === name.replace(/\.json$/, ''));
    check(titlesMatch, `schemas/${version}/ file names equal their schema titles`);
  }

  const doc = path.join(ROOT, 'docs', 'codex-port.md');
  const text = fs.existsSync(doc) ? fs.readFileSync(doc, 'utf8') : '';
  check(text.length > 0, 'docs/codex-port.md exists');
  for (const file of resultFiles) check(text.includes(`results/${file}`), `docs/codex-port.md cites results/${file}`);
  const gateLines = text.split('\n').filter((line) => line.startsWith('Gate verdict:'));
  check(gateLines.length === 1, `docs/codex-port.md has exactly one gate verdict line (${gateLines.length})`);
  const docVerdict = gateLines.length === 1 ? (/^Gate verdict: (continue|stop)\b/.exec(gateLines[0]) || [])[1] : null;
  check(verdicts.size === 1 && docVerdict === [...verdicts][0], 'docs/codex-port.md verdict matches every recorded gate');
  citationChecks(text, resultsByVersion);

  const synthetic = Buffer.concat([
    Buffer.from('\u0000junkbytes'),
    Buffer.from('stop.command.input{"title":"stop.command.input","type":"object"}'),
    Buffer.from('\u0001Errorpost-tool-use.command.output{"title":"post-tool-use.command.output","properties":{"a":{"description":"brace } and quote \\" inside"}}}'),
    Buffer.from('\u0002tail'),
  ]);
  const extracted = schemas.extractSchemas(synthetic);
  check(extracted.size === 2 && extracted.has('stop.command.input') && extracted.has('post-tool-use.command.output'), 'schema extractor splits concatenated schemas on their markers');
  check(extracted.get('post-tool-use.command.output').properties.a.description === 'brace } and quote " inside', 'schema extractor respects braces and quotes inside strings');
  let threw = false;
  try {
    schemas.extractSchemas(Buffer.from('stop.command.input{"title":"stop.command.output"}'));
  } catch {
    threw = true;
  }
  check(threw, 'schema extractor refuses a title that disagrees with its marker');
  const drift = schemas.compareSchemas(new Map([['stop.command.input', '{}\n']]), extracted);
  check(drift.some((line) => line.startsWith('changed: stop.command.input')) && drift.some((line) => line.startsWith('new in binary: post-tool-use')), 'schema comparison reports changed and new schemas');

  await mockChecks();
  recorderChecks();

  const hooksFile = JSON.parse(fs.readFileSync(path.join(PROBE, 'fixture', 'plugins', 'hookprobe', 'hooks', 'hooks.json'), 'utf8'));
  const matcherGroups = hooksFile.hooks.PreToolUse.filter((group) => group.matcher !== undefined).map((group) => ({ label: group.hooks[0].command.split(' ').pop(), matcher: group.matcher }));
  check(JSON.stringify(matcherGroups) === JSON.stringify(contract.MATCHERS), 'fixture matcher groups equal the contract matcher list');
  check(hooksFile.hooks.PreToolUse[0].matcher === undefined && hooksFile.hooks.PreToolUse[0].hooks[0].command.endsWith(' PreToolUse'), 'the catch-all PreToolUse group comes first and carries no label');

  const env = analyze.envLines('A=1\nCODEX_THREAD_ID=abc\nnot a line\n');
  check(env.A === '1' && env.CODEX_THREAD_ID === 'abc' && Object.keys(env).length === 2, 'envLines parses KEY=VALUE lines only');
  const refs = { pluginRoot: '/r', pluginData: '/d', project: '/p', codexHome: '/h' };
  check(analyze.classifyValue('/r', refs) === 'plugin-root' && analyze.classifyValue('1', refs) === 'literal:1' && analyze.classifyValue('/elsewhere/x', refs) === 'other', 'classifyValue never records a raw path');
  const tools = analyze.toolsOfBody({
    tools: [{ type: 'function', name: 'a' }, { type: 'namespace', name: 'ns', tools: [{ type: 'function', name: 'b' }] }],
    input: [{ type: 'additional_tools', tools: [{ type: 'namespace', name: 'functions', tools: [{ type: 'custom', name: 'exec' }] }] }],
  });
  check(JSON.stringify(tools) === JSON.stringify(['a', 'functions.exec', 'ns.b']), 'toolsOfBody flattens namespaces and additional_tools');
  check(analyze.outputOfCall({ input: [{ type: 'function_call_output', call_id: 'x', output: 'out' }] }, 'x') === 'out' && analyze.outputOfCall({ input: [] }, 'x') === null, 'outputOfCall finds the output of one call id');
  check(analyze.diffPaths({ a: [1, 2] }, { a: [1, 3] }).length === 1 && analyze.diffPaths({ a: 1 }, { a: 1 }).length === 0, 'diffPaths reports only differing leaves');
  check(analyze.diffPaths(analyze.comparable({ conditions: { launcher: 'npm package' } }), analyze.comparable({ conditions: { launcher: 'native binary' } })).length === 0, 'the launcher condition never counts as drift');
  const gateOf = Object.fromEntries([...analyze.GATE_INPUTS.map((key) => [key, true]), ['verdict', 'continue']]);
  check(analyze.validateResults({ schemaVersion: analyze.SCHEMA_VERSION, codexVersion: '1.2.3', measuredOn: '2026-01-01', conditions: {}, facts: {}, gate: gateOf }).some((problem) => problem.startsWith('facts.events missing')), 'validateResults requires every fact group');
  check(analyze.validateResults({ schemaVersion: analyze.SCHEMA_VERSION, codexVersion: '1.2.3', measuredOn: '2026-01-01', conditions: { p: '/Users/someone/x' }, facts: {}, gate: { verdict: 'continue' } }).includes('results contain an absolute path'), 'validateResults rejects absolute paths');

  gateChecks();
  emptyRunChecks();
  blockTargetChecks();
  controlChecks();
  positiveChecks();
  scenarioChecks();
  parserChecks();
  isolationChecks();
  await cleanupChecks();
  nativeBinaryChecks();
  await appServerClientChecks();
  await runProcessChecks();
  await signalChecks();
  partialRunChecks();
  reviewerRoleChecks();
  conditionChecks(resultsByVersion);

  const inventory = JSON.parse(fs.readFileSync(path.join(ROOT, 'tests', 'profiles', 'promptfoo-local-only.v1.json'), 'utf8'));
  check(inventory.ciStructureTests.includes('test-host-hook-contract.sh'), 'this suite is classified as a CI structure test');

  process.stdout.write(`${lines.join('\n')}\n`);
}

main().catch((error) => {
  process.stdout.write(`${lines.join('\n')}\nbad unexpected error: ${error.stack || error.message}\n`);
});
NODE
)"
NODE_RC=$?
[ "$NODE_RC" -eq 0 ] || bad "node checks exited $NODE_RC"
printf '%s\n' "$RESULT" | grep -q '^ok ' || bad "node checks reported nothing"

while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "bad "*) bad "${line#bad }" ;;
  esac
done <<< "$RESULT"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
