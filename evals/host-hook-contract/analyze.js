'use strict';

const path = require('node:path');
const { TUI_STRINGS, CONTEXT, MARKERS, FILES, PROMPTS, CALLS, ROLES, TWIN_ROLE, TOOLS_ROLE, MATCHERS, SCENARIO_NAMES, isSubagentBody } = require('./contract');

const SCHEMA_VERSION = 3;
const FACT_KEYS = [
  'events',
  'hookPayloads',
  'hookEnvironment',
  'features',
  'threadId',
  'subagents',
  'skills',
  'agentRoles',
  'toolSurfaces',
  'toolHooks',
  'deny',
  'stop',
  'subagentStop',
  'requestUserInput',
  'planMode',
  'hookTrust',
  'permissionRequest',
  'compaction',
  'interrupt',
  'pluginUpdate',
  'worktreeMove',
];
const GATE_VERDICTS = ['continue', 'stop'];
const GATE_INPUTS = ['denyShell', 'denyApplyPatch', 'denySubagent', 'stopBlocks', 'trustedGates'];
const ENV_NAME = /^(CLAUDE|CODEX|PLUGIN|ZENSU)_/;
const LAUNCHER_VARIABLE = /^CODEX_MANAGED_/;
const DISCOVERY_ROLES = [...Object.keys(ROLES), TWIN_ROLE.name];
const ROLE_MARKERS = [...Object.values(ROLES), TWIN_ROLE.home, TWIN_ROLE.project, TOOLS_ROLE.marker];

function uniqueSorted(values) {
  return [...new Set(values.filter((value) => value !== undefined && value !== null))].sort();
}

function byName(runs) {
  const index = Object.fromEntries(runs.map((run) => [run.name, run]));
  return new Proxy(index, {
    get(target, key) {
      if (typeof key === 'string' && !SCENARIO_NAMES.includes(key)) throw new Error(`the analysis reads an unknown scenario: ${key}`);
      return target[key];
    },
  });
}

function unverified(reason) {
  return { unverified: reason };
}

function fromRun(run, name, derive) {
  return run ? derive(run) : unverified(`${name} scenario missing`);
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function labelOf(hook) {
  return hook.label || (Array.isArray(hook.argv) && hook.argv[1]) || null;
}

function hooksOf(run, event) {
  return run && Array.isArray(run.hooks) ? run.hooks.filter((hook) => hook.event === event && !labelOf(hook)) : [];
}

function payloadOf(run, event) {
  const hook = hooksOf(run, event)[0];
  return hook ? hook.payload : null;
}

function contentText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((part) => (part && (part.text || part.output || '')) || '').join('\n');
  if (content && typeof content === 'object') return content.text || JSON.stringify(content);
  return '';
}

function inputOf(body) {
  return Array.isArray(body && body.input) ? body.input : [];
}

function outputOfCall(body, callId) {
  const item = inputOf(body).find((entry) => (entry.type === 'function_call_output' || entry.type === 'custom_tool_call_output') && entry.call_id === callId);
  return item ? contentText(item.output) : null;
}

function outputFor(run, callId) {
  for (const body of (run && run.requests) || []) {
    const text = outputOfCall(body, callId);
    if (text !== null) return text;
  }
  return null;
}

function firstRequestWith(run, text) {
  return ((run && run.requests) || []).find((body) => JSON.stringify(inputOf(body)).includes(text)) || null;
}

function flattenTools(tools, prefix = '') {
  const names = [];
  for (const tool of tools || []) {
    if (tool.type === 'namespace') names.push(...flattenTools(tool.tools, `${tool.name}.`));
    else names.push(`${prefix}${tool.name || tool.type}`);
  }
  return names;
}

function toolsOfBody(body) {
  const names = flattenTools(body && body.tools);
  for (const item of inputOf(body)) {
    if (item.type === 'additional_tools') names.push(...flattenTools(item.tools));
  }
  return uniqueSorted(names);
}

function findTool(body, name) {
  let found = null;
  const scan = (tools) => {
    for (const tool of tools || []) {
      if (tool.type === 'namespace') scan(tool.tools);
      else if (tool.name === name && !found) found = tool;
    }
  };
  scan(body && body.tools);
  for (const item of inputOf(body)) if (item.type === 'additional_tools') scan(item.tools);
  return found;
}

function nestedExecTools(body) {
  const exec = findTool(body, 'exec');
  if (!exec || typeof exec.description !== 'string') return [];
  return uniqueSorted([...exec.description.matchAll(/^### `([^`]+)`/gm)].map((match) => match[1]));
}

function envLines(text) {
  const out = {};
  for (const line of String(text).split('\n')) {
    const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (match) out[match[1]] = match[2];
  }
  return out;
}

function threadStarted(run) {
  const event = ((run && run.events) || []).find((item) => item.type === 'thread.started');
  return event ? event.thread_id : null;
}

function layoutOf(relative, ctx) {
  return relative.split(path.sep).map((part) => {
    if (part === ctx.plugin.version) return '<version>';
    if (part === `${ctx.plugin.name}-${ctx.plugin.marketplace}`) return '<plugin>-<marketplace>';
    if (part === ctx.plugin.marketplace) return '<marketplace>';
    if (part === ctx.plugin.name) return '<plugin>';
    return part;
  }).join('/');
}

function classifyValue(value, refs) {
  if (value === refs.pluginRoot) return 'plugin-root';
  if (value === refs.pluginData) return 'plugin-data';
  if (value === refs.project) return 'project-dir';
  if (value === refs.codexHome) return 'codex-home';
  if (/^[A-Za-z0-9._-]{1,12}$/.test(value)) return `literal:${value}`;
  return 'other';
}

function fileExists(project, name, fsModule) {
  return fsModule.existsSync(path.join(project, name));
}

function fileContains(project, name, needle, fsModule) {
  try {
    return fsModule.readFileSync(path.join(project, name), 'utf8').includes(needle);
  } catch {
    return false;
  }
}

function subagentThreads(run) {
  return uniqueSorted(((run && run.requests) || []).filter(isSubagentBody).map((body) => body.client_metadata.thread_id));
}

function idClass(value, run) {
  if (value === undefined || value === null || value === '') return 'absent';
  if (value === threadStarted(run)) return 'root-thread';
  if (subagentThreads(run).includes(value)) return 'subagent-thread';
  return 'other';
}

function cwdView(run, ctx) {
  if (!run) return unverified('scenario missing');
  const start = hooksOf(run, 'SessionStart')[0];
  if (!start) return unverified(`${run.name} recorded no SessionStart hook`);
  const launch = path.dirname(ctx.codexHome);
  const where = (value) => {
    if (value === run.project) return 'project-dir';
    if (value === launch) return 'launch-dir';
    return 'other';
  };
  return { process: where(start.cwd), payload: where(start.payload.cwd) };
}

function deriveHookEnvironment(r, ctx) {
  const run = r['classic-baseline'];
  const start = hooksOf(run, 'SessionStart')[0];
  if (!start) return unverified('classic-baseline recorded no SessionStart hook');
  if (typeof start.script !== 'string' || !start.env) return unverified('the classic-baseline SessionStart record carries no script path or environment');
  const pluginRoot = path.dirname(path.dirname(start.script));
  const pluginData = start.env.CLAUDE_PLUGIN_DATA || start.env.PLUGIN_DATA || null;
  const refs = { pluginRoot, pluginData, project: run.project, codexHome: ctx.codexHome };
  const variables = {};
  for (const name of Object.keys(start.env).sort()) {
    if (ENV_NAME.test(name) && name !== 'CODEX_HOME' && !LAUNCHER_VARIABLE.test(name)) variables[name] = classifyValue(start.env[name], refs);
  }
  return {
    variables,
    pluginRootLayout: layoutOf(path.relative(ctx.codexHome, pluginRoot), ctx),
    pluginDataLayout: pluginData ? layoutOf(path.relative(ctx.codexHome, pluginData), ctx) : null,
    hookCwd: {
      execStartedInProject: cwdView(run, ctx),
      execStartedElsewhere: cwdView(r['exec-cwd-outside'], ctx),
      appServer: cwdView(r['app-trust'], ctx),
    },
    claudeProjectDir: Object.prototype.hasOwnProperty.call(start.env, 'CLAUDE_PROJECT_DIR'),
    threadIdVariables: Object.keys(start.env).filter((name) => start.env[name] === start.payload.session_id).sort(),
    sessionStartContextReachesModel: JSON.stringify(run.requests[0] || {}).includes(CONTEXT.sessionStart),
    userPromptSubmitContextReachesModel: JSON.stringify(run.requests[0] || {}).includes(CONTEXT.userPromptSubmit),
  };
}

function deriveFeatures(r) {
  const run = r['exec-default-features'];
  if (!run) return unverified('exec-default-features scenario missing');
  if (!run.requests.length) return unverified('exec-default-features reached no model request');
  return { pluginHooksRunWithoutFeaturesTable: (run.hooks || []).length > 0 };
}

function shellView(run, callId) {
  const text = outputFor(run, callId);
  if (text === null) return unverified('the shell call produced no output');
  const env = envLines(text.replace(/\\n/g, '\n'));
  const thread = threadStarted(run);
  return {
    codexVariables: Object.keys(env).filter((name) => /^CODEX_/.test(name) && !LAUNCHER_VARIABLE.test(name)).sort(),
    threadIdVariables: Object.keys(env).filter((name) => thread && env[name] === thread).sort(),
  };
}

function deriveThreadId(r) {
  const classic = r['classic-baseline'];
  const code = r['code-baseline'];
  const spawn = r['spawn-code'];
  if (!classic || !code) return unverified('baseline scenarios missing');
  const thread = threadStarted(classic);
  const start = payloadOf(classic, 'SessionStart');
  const subStart = payloadOf(spawn, 'SubagentStart');
  return {
    classicShell: shellView(classic, CALLS.env),
    codeModeShell: shellView(code, CALLS.env),
    hookSessionIdEqualsThread: Boolean(start && start.session_id === thread),
    subagentHookSessionId: fromRun(spawn, 'spawn-code', (run) => (subStart ? idClass(subStart.session_id, run) : 'not-observed')),
    subagentAgentIdIsSubagentThread: fromRun(spawn, 'spawn-code', (run) => Boolean(subStart && idClass(subStart.agent_id, run) === 'subagent-thread')),
  };
}

function subagentRecord(run, event, toolName, needle) {
  return hooksOf(run, event).find((hook) => hook.payload.tool_name === toolName && JSON.stringify(hook.payload.tool_input || {}).includes(needle)) || null;
}

function turnsOf(run) {
  return {
    root: uniqueSorted(hooksOf(run, 'UserPromptSubmit').filter((hook) => hook.payload.agent_id === undefined).map((hook) => hook.payload.turn_id)),
    subagent: uniqueSorted(hooksOf(run, 'SubagentStart').map((hook) => hook.payload.turn_id)),
  };
}

function toolRecordView(record, run) {
  if (!record) return unverified('no hook record for the subagent call');
  const turns = turnsOf(run);
  const payload = record.payload;
  let turn = 'other';
  if (turns.subagent.includes(payload.turn_id)) turn = 'subagent-turn';
  else if (turns.root.includes(payload.turn_id)) turn = 'root-turn';
  return {
    agentId: idClass(payload.agent_id, run),
    agentType: payload.agent_type === undefined ? 'absent' : payload.agent_type,
    sessionId: idClass(payload.session_id, run),
    turn,
  };
}

function subagentSide(run, surface) {
  if (!run) return unverified('spawn scenario missing');
  const output = outputFor(run, CALLS.subTool);
  const env = output === null ? null : envLines(output.replace(/\\n/g, '\n'));
  const prompts = hooksOf(run, 'UserPromptSubmit').filter((hook) => hook.payload.agent_id !== undefined);
  const turns = turnsOf(run);
  return {
    subagentStart: toolRecordView(hooksOf(run, 'SubagentStart')[0] || null, run),
    subagentStop: toolRecordView(hooksOf(run, 'SubagentStop')[0] || null, run),
    shellPreToolUse: toolRecordView(subagentRecord(run, 'PreToolUse', 'Bash', MARKERS.subagentShell), run),
    shellPostToolUse: toolRecordView(subagentRecord(run, 'PostToolUse', 'Bash', MARKERS.subagentShell), run),
    patchPreToolUse: surface === 'code' ? toolRecordView(subagentRecord(run, 'PreToolUse', 'apply_patch', FILES.subPatch), run) : null,
    shellThreadVariables: env
      ? { CODEX_THREAD_ID: idClass(env.CODEX_THREAD_ID, run), CODEX_SESSION_ID: idClass(env.CODEX_SESSION_ID, run) }
      : unverified('the subagent shell call produced no output'),
    userPromptSubmit: prompts.length
      ? {
        fired: true,
        agentId: idClass(prompts[0].payload.agent_id, run),
        agentType: prompts[0].payload.agent_type === undefined ? 'absent' : prompts[0].payload.agent_type,
        sessionId: idClass(prompts[0].payload.session_id, run),
        promptIsSpawnMessage: prompts.every((hook) => hook.payload.prompt === TUI_STRINGS.approvalPrompt),
      }
      : { fired: false },
    hookCounts: {
      sessionStart: hooksOf(run, 'SessionStart').length,
      stop: hooksOf(run, 'Stop').length,
      stopInSubagentTurn: hooksOf(run, 'Stop').filter((hook) => turns.subagent.includes(hook.payload.turn_id)).length,
      subagentStart: hooksOf(run, 'SubagentStart').length,
      subagentStop: hooksOf(run, 'SubagentStop').length,
    },
  };
}

function deriveSubagents(r) {
  return {
    classic: subagentSide(r['spawn-classic'], 'classic'),
    codeMode: subagentSide(r['spawn-code'], 'code'),
  };
}

function deriveEvents(runs, r) {
  const lists = r['app-lists'];
  const entry = lists && lists.result && lists.result.hooks && Array.isArray(lists.result.hooks.data) ? lists.result.hooks.data[0] : null;
  const fired = uniqueSorted(runs.flatMap((run) => (run.hooks || []).map((hook) => hook.event)));
  if (!entry) return unverified('app-lists did not return the hook registrations');
  if (!fired.length) return unverified('no hook ran in any scenario');
  const declared = uniqueSorted(entry.hooks.map((hook) => hook.eventName.charAt(0).toUpperCase() + hook.eventName.slice(1)));
  return {
    registered: declared,
    registrationErrors: entry.errors.length,
    registrationWarnings: entry.warnings.length,
    fired,
    notFired: declared.filter((event) => !fired.includes(event)),
  };
}

function deriveHookPayloads(runs) {
  if (!runs.some((run) => (run.hooks || []).length)) return unverified('no hook ran in any scenario');
  const keys = {};
  for (const run of runs) {
    for (const hook of run.hooks || []) {
      const payload = hook.payload && typeof hook.payload === 'object' ? hook.payload : {};
      keys[hook.event] = uniqueSorted([...(keys[hook.event] || []), ...Object.keys(payload)]);
    }
  }
  const sorted = {};
  for (const event of Object.keys(keys).sort()) sorted[event] = keys[event];
  const sources = uniqueSorted(runs.flatMap((run) => hooksOf(run, 'SessionStart').map((hook) => hook.payload.source)));
  const endReasons = uniqueSorted(runs.flatMap((run) => hooksOf(run, 'SessionEnd').map((hook) => hook.payload.reason)));
  const permissionModes = uniqueSorted(runs.flatMap((run) => (run.hooks || []).map((hook) => hook.payload && hook.payload.permission_mode)));
  return { keys: sorted, sessionStartSources: sources, sessionEndReasons: endReasons, permissionModes };
}

function deriveSkills(r, ctx) {
  const lists = r['app-lists'];
  if (!lists || !lists.result || !lists.result.skills) return unverified('app-lists did not return skills');
  const skills = lists.result.skills.data[0].skills.filter((skill) => skill.pluginId === ctx.plugin.id);
  const listed = skills.map((skill) => skill.name);
  return {
    pluginSkillNames: listed.map((name) => name.split(`${ctx.plugin.name}:`).join('<plugin>:').replace(/probe-skill$/, '<skill>')),
    namespaced: listed.includes(`${ctx.plugin.name}:probe-skill`),
    listedInModelInstructions: fromRun(r['classic-baseline'], 'classic-baseline', (run) => JSON.stringify(run.requests[0] || {}).includes(`${ctx.plugin.name}:probe-skill`)),
    pluginIdFormat: skills.length && skills[0].pluginId === `${ctx.plugin.name}@${ctx.plugin.marketplace}` ? '<plugin>@<marketplace>' : 'other',
  };
}

function startedRoles(run) {
  return uniqueSorted(hooksOf(run, 'SubagentStart').map((hook) => hook.payload.agent_type));
}

function roleMarkers(run) {
  return uniqueSorted(((run && run.requests) || []).filter(isSubagentBody).flatMap((body) => {
    const text = JSON.stringify(inputOf(body));
    return ROLE_MARKERS.filter((marker) => text.includes(marker));
  }));
}

function twinWinner(run) {
  const markers = roleMarkers(run);
  const home = markers.includes(TWIN_ROLE.home);
  const project = markers.includes(TWIN_ROLE.project);
  if (home && project) return 'both';
  if (home) return 'codex-home';
  if (project) return 'project';
  return 'none';
}

function spawnSchema(run) {
  const spawn = findTool(run && run.requests && run.requests[0], 'spawn_agent');
  return spawn && spawn.parameters && spawn.parameters.properties ? spawn.parameters.properties : {};
}

function listedRoles(run) {
  const property = spawnSchema(run).agent_type;
  const text = property ? property.description || '' : '';
  return DISCOVERY_ROLES.filter((role) => text.includes(`${role}:`));
}

function rejectedRole(run, role) {
  return ((run && run.requests) || []).filter((body) => !isSubagentBody(body)).some((body) => outputsOfBody(body).some((text) => text.includes(`unknown agent_type '${role}'`)));
}

function outputsOfBody(body) {
  return inputOf(body)
    .filter((item) => item.type === 'function_call_output' || item.type === 'custom_tool_call_output')
    .map((item) => contentText(item.output));
}

function writesOf(run, surface, fsModule) {
  if (!run) return unverified('scenario missing');
  const shell = subagentRecord(run, 'PreToolUse', 'Bash', MARKERS.subagentShell);
  if (!shell) return unverified('the subagent never ran its shell command');
  const patch = surface === 'code' ? subagentRecord(run, 'PreToolUse', 'apply_patch', FILES.subPatch) : null;
  return {
    shellWrite: fileExists(run.project, FILES.subShell, fsModule),
    patchWrite: surface === 'code' ? fileExists(run.project, FILES.subPatch, fsModule) : null,
    patchHooked: surface === 'code' ? Boolean(patch) : null,
    toolHookAgentTypes: uniqueSorted([shell, patch].filter(Boolean).map((hook) => (hook.payload.agent_type === undefined ? 'absent' : hook.payload.agent_type))),
  };
}

function readOnlyParent(run, fsModule) {
  if (!run) return unverified('scenario missing');
  if (outputFor(run, CALLS.parentWrite) === null) return unverified('the read-only parent write produced no output');
  return !fileExists(run.project, FILES.parentWrite, fsModule);
}

function requestOfThread(run, threadId) {
  return ((run && run.requests) || []).find((body) => body.client_metadata && body.client_metadata.thread_id === threadId) || null;
}

function roleAgentId(run) {
  const start = hooksOf(run, 'SubagentStart').find((hook) => hook.payload.agent_type === TOOLS_ROLE.name);
  return start ? start.payload.agent_id : null;
}

function threadInPath(value) {
  const match = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i.exec(String(value || ''));
  return match ? match[1] : null;
}

function transcriptOwner(value, ids) {
  const id = threadInPath(value);
  if (!id) return 'absent';
  if (id === ids.own) return 'own';
  if (id === ids.spawner) return 'spawner';
  if (id === ids.root) return 'root';
  return 'other';
}

function profileCalls(run, fsModule) {
  const output = subagentOutput(run, CALLS.profileTools);
  if (output === null) return unverified('the reviewer-profile tool calls produced no output');
  return {
    patchWrite: fileExists(run.project, FILES.profilePatch, fsModule),
    shellWrite: fileExists(run.project, FILES.profileShell, fsModule),
    shellToolMissing: /exec_command is not a function/.test(output),
  };
}

function nestingOf(run, fsModule) {
  if (!run) return unverified('scenario missing');
  const childId = roleAgentId(run);
  if (!childId) return unverified('the reviewer-profile role never started');
  const spawnHook = hooksOf(run, 'PreToolUse').find((hook) => hook.payload.agent_id === childId && /spawn_agent$/.test(hook.payload.tool_name || ''));
  const grand = hooksOf(run, 'SubagentStart').find((hook) => hook.payload.agent_id !== childId);
  const view = {
    roleSpawnPreToolUse: spawnHook ? { toolName: spawnHook.payload.tool_name, agentType: agentTypeOf(spawnHook.payload) } : 'not-observed',
    grandchildStarted: Boolean(grand),
  };
  if (!grand) return view;
  const ids = { own: grand.payload.agent_id, spawner: childId, root: threadStarted(run) };
  const grandPatch = hooksOf(run, 'PreToolUse').find((hook) => hook.payload.agent_id === ids.own && hook.payload.tool_name === 'apply_patch');
  const grandStop = hooksOf(run, 'SubagentStop').find((hook) => hook.payload.agent_id === ids.own);
  return {
    ...view,
    grandchildAgentType: agentTypeOf(grand.payload),
    grandchildPatchPreToolUse: grandPatch ? agentTypeOf(grandPatch.payload) : 'not-observed',
    grandchildWrite: fileExists(run.project, FILES.grandWrite, fsModule),
    transcriptPathNames: {
      subagentStart: transcriptOwner(grand.payload.transcript_path, ids),
      preToolUse: grandPatch ? transcriptOwner(grandPatch.payload.transcript_path, ids) : 'not-observed',
      subagentStop: grandStop ? transcriptOwner(grandStop.payload.transcript_path, ids) : 'not-observed',
      subagentStopAgentTranscript: grandStop ? transcriptOwner(grandStop.payload.agent_transcript_path, ids) : 'not-observed',
    },
  };
}

function toolProfileOf(r, fsModule) {
  const tools = r['role-tools-code'];
  const base = r['spawn-code'];
  if (!tools || !base) return unverified('tool profile scenarios missing');
  const firstSubagentRequest = (run) => ((run && run.requests) || []).find(isSubagentBody) || null;
  const view = (body) => (body ? { tools: toolsOfBody(body), nested: nestedExecTools(body) } : unverified('no subagent request'));
  const roleId = roleAgentId(tools);
  return {
    spawned: startedRoles(tools).includes(TOOLS_ROLE.name),
    instructionsApplied: roleMarkers(tools).includes(TOOLS_ROLE.marker),
    defaultAgent: view(firstSubagentRequest(base)),
    toolsRole: view(roleId ? requestOfThread(tools, roleId) : null),
    toolCalls: profileCalls(tools, fsModule),
    nesting: {
      shippedProfile: nestingOf(tools, fsModule),
      withoutAgentsTable: nestingOf(r['role-delegate-code'], fsModule),
    },
  };
}

function deriveAgentRoles(r, fsModule) {
  const code = r['roles-code'];
  const classic = r['roles-classic'];
  const untrusted = r['roles-untrusted-project'];
  if (!code || !classic) return unverified('role scenarios missing');
  return {
    sources: {
      pluginAgentsDirectory: !rejectedRole(code, 'probe-role') && startedRoles(code).includes('probe-role'),
      codexHomeAgentsDirectory: startedRoles(code).includes('home-role'),
      projectCodexAgentsDirectory: startedRoles(code).includes('project-role'),
      configAgentsTable: startedRoles(code).includes('config-role'),
    },
    sameOnClassicSurface: JSON.stringify(startedRoles(code)) === JSON.stringify(startedRoles(classic)),
    listedInSpawnSchema: listedRoles(code),
    agentTypeParameterWithRoles: Boolean(spawnSchema(code).agent_type),
    agentTypeParameterWithoutRoles: fromRun(r['code-baseline'], 'code-baseline', (run) => Boolean(spawnSchema(run).agent_type)),
    developerInstructionsApplied: roleMarkers(code),
    subagentStartAgentType: startedRoles(code),
    defaultAgentType: fromRun(r['spawn-code'], 'spawn-code', startedRoles),
    sameNameWinner: twinWinner(code),
    untrustedProject: untrusted
      ? {
        listsProjectRole: listedRoles(untrusted).includes('project-role'),
        spawnsProjectRole: startedRoles(untrusted).includes('project-role'),
        projectInstructionsApplied: roleMarkers(untrusted).includes(ROLES['project-role']),
        sameNameWinner: twinWinner(untrusted),
      }
      : unverified('roles-untrusted-project scenario missing'),
    sandbox: {
      parentDangerFullAccess: {
        classic: { defaultAgent: writesOf(r['spawn-classic'], 'classic', fsModule), readOnlyRole: writesOf(r['role-sandbox-classic'], 'classic', fsModule) },
        codeMode: { defaultAgent: writesOf(r['spawn-code'], 'code', fsModule), readOnlyRole: writesOf(r['role-sandbox-code'], 'code', fsModule) },
      },
      readOnlyParentBlocksProjectWrite: readOnlyParent(r['sandbox-readonly-parent'], fsModule),
      parentWorkspaceWrite: {
        codeMode: { defaultAgent: writesOf(r['spawn-code-workspace'], 'code', fsModule), readOnlyRole: writesOf(r['role-sandbox-code-workspace'], 'code', fsModule) },
      },
    },
    toolProfile: toolProfileOf(r, fsModule),
  };
}

function deriveToolSurfaces(r) {
  const classic = r['classic-baseline'];
  const code = r['code-baseline'];
  const gpt55 = r['gpt55-baseline'];
  const rui = r['app-rui'];
  if (!classic || !code || !gpt55) return unverified('baseline scenarios missing');
  if (!classic.requests.length || !code.requests.length || !gpt55.requests.length) return unverified('a baseline scenario reached no model request');
  const classicPlan = firstRequestWith(rui, PROMPTS.ruiPlan);
  const codePlan = firstRequestWith(rui, PROMPTS.ruiCodePlan);
  const allTools = [classic, code, gpt55, rui].flatMap((run) => ((run && run.requests) || []).flatMap((body) => [...toolsOfBody(body), ...nestedExecTools(body)]));
  return {
    classic: toolsOfBody(classic.requests[0]),
    codeMode: toolsOfBody(code.requests[0]),
    codeModeNested: nestedExecTools(code.requests[0]),
    gpt55: toolsOfBody(gpt55.requests[0]),
    classicPlanMode: classicPlan ? toolsOfBody(classicPlan) : unverified('no request for the classic Plan-mode turn'),
    codeModePlanMode: codePlan ? { tools: toolsOfBody(codePlan), nested: nestedExecTools(codePlan) } : unverified('no request for the code-mode Plan-mode turn'),
    updatePlanOffered: rui ? allTools.some((name) => /(^|\.)update_plan$/.test(name)) : unverified('app-rui scenario missing'),
    applyPatchOffered: {
      classic: toolsOfBody(classic.requests[0]).some((name) => /apply_patch/.test(name)),
      codeMode: nestedExecTools(code.requests[0]).includes('apply_patch'),
      gpt55: toolsOfBody(gpt55.requests[0]).some((name) => /apply_patch/.test(name)),
    },
  };
}

function preToolNames(run) {
  return hooksOf(run, 'PreToolUse').map((hook) => hook.payload.tool_name);
}

function inputKeys(run, toolName) {
  const hook = hooksOf(run, 'PreToolUse').find((item) => item.payload.tool_name === toolName);
  return hook && hook.payload.tool_input && typeof hook.payload.tool_input === 'object' ? Object.keys(hook.payload.tool_input).sort() : null;
}

function countsByTool(run, event) {
  const counts = {};
  for (const hook of hooksOf(run, event)) counts[hook.payload.tool_name] = (counts[hook.payload.tool_name] || 0) + 1;
  return Object.fromEntries(Object.entries(counts).sort(([a], [b]) => a.localeCompare(b)));
}

function deriveWriteStdin(r, fsModule) {
  const classic = r['classic-stdin'];
  const code = r['code-stdin'];
  if (!classic || !code) return unverified('stdin scenarios missing');
  const view = (run) => ({
    worked: fileContains(run.project, FILES.stdin, MARKERS.stdin, fsModule),
    preToolUse: countsByTool(run, 'PreToolUse'),
    postToolUse: countsByTool(run, 'PostToolUse'),
  });
  return { classic: view(classic), codeMode: view(code) };
}

function spawnHookNames(run) {
  return uniqueSorted(hooksOf(run, 'PreToolUse')
    .filter((hook) => hook.payload.agent_id === undefined && /agent/.test(hook.payload.tool_name || ''))
    .map((hook) => hook.payload.tool_name));
}

function deriveToolHooks(r, fsModule) {
  const classic = r['classic-baseline'];
  const code = r['code-baseline'];
  const patch = r['code-patch'];
  const multi = r['code-patch-multi'];
  if (!classic || !code || !patch) return unverified('tool scenarios missing');
  const permission = payloadOf(r['app-permission'], 'PermissionRequest');
  const gpt55 = r['gpt55-baseline'];
  const gpt55Patch = r['gpt55-patch'];
  const patchTextIn = (run) => (hooksOf(run, 'PreToolUse').some((hook) => hook.payload.tool_input && hook.payload.tool_input.command && hook.payload.tool_input.command.includes('*** Begin Patch')) ? 'tool_input.command' : 'other');
  const responseType = (run) => (payloadOf(run, 'PostToolUse') ? typeof payloadOf(run, 'PostToolUse').tool_response : unverified(`${run.name} recorded no PostToolUse hook`));
  return {
    execCommand: {
      classic: preToolNames(classic)[0] || null,
      codeMode: preToolNames(code)[0] || null,
      gpt55: gpt55 ? preToolNames(gpt55)[0] || null : unverified('gpt55-baseline scenario missing'),
      inputKeys: {
        classic: inputKeys(classic, 'Bash'),
        codeMode: inputKeys(code, 'Bash'),
        gpt55: fromRun(gpt55, 'gpt55-baseline', (run) => inputKeys(run, 'Bash')),
      },
      ttyInputKeys: {
        classic: fromRun(r['classic-stdin'], 'classic-stdin', (run) => inputKeys(run, 'Bash')),
        codeMode: fromRun(r['code-stdin'], 'code-stdin', (run) => inputKeys(run, 'Bash')),
      },
    },
    applyPatch: {
      codeMode: preToolNames(patch)[0] || null,
      inputKeys: inputKeys(patch, 'apply_patch'),
      patchTextIn: patchTextIn(patch),
      multiFileEvents: multi ? hooksOf(multi, 'PreToolUse').length : unverified('code-patch-multi scenario missing'),
      multiFileApplied: multi ? FILES.multi.every((name, index) => fileContains(multi.project, name, MARKERS.multiLines[index], fsModule)) : unverified('code-patch-multi scenario missing'),
      gpt55: gpt55Patch
        ? { toolName: preToolNames(gpt55Patch)[0] || null, inputKeys: inputKeys(gpt55Patch, 'apply_patch'), patchTextIn: patchTextIn(gpt55Patch), applied: fileContains(gpt55Patch.project, FILES.patched, MARKERS.patchLine, fsModule) }
        : unverified('gpt55-patch scenario missing'),
    },
    writeStdin: deriveWriteStdin(r, fsModule),
    codeModeOuterExecHooked: [code, patch].some((run) => preToolNames(run).includes('exec')),
    spawnAgent: {
      classic: fromRun(r['spawn-classic'], 'spawn-classic', spawnHookNames),
      codeMode: fromRun(r['spawn-code'], 'spawn-code', spawnHookNames),
    },
    requestUserInput: fromRun(r['classic-rui'], 'classic-rui', (run) => preToolNames(run)[0] || null),
    postToolUseResponseType: {
      classic: responseType(classic),
      codeMode: responseType(code),
      gpt55: fromRun(gpt55, 'gpt55-baseline', responseType),
    },
    permissionRequestInputKeys: fromRun(r['app-permission'], 'app-permission', () => (permission && permission.tool_input ? Object.keys(permission.tool_input).sort() : null)),
  };
}

function denyResult(run, fileName, fsModule) {
  if (!run) return unverified('scenario missing');
  const output = outputFor(run, CALLS.deny);
  if (output === null) return unverified('the denied call produced no output');
  const reasonReachesModel = output.includes(MARKERS.deny);
  const sideEffect = fileExists(run.project, fileName, fsModule);
  return { blocked: reasonReachesModel && !sideEffect && hooksOf(run, 'PostToolUse').length === 0, reasonReachesModel };
}

function subagentOutput(run, callId) {
  for (const body of ((run && run.requests) || []).filter(isSubagentBody)) {
    const text = outputOfCall(body, callId);
    if (text !== null) return text;
  }
  return null;
}

function agentTypeOf(payload) {
  return payload.agent_type === undefined ? 'absent' : payload.agent_type;
}

function subagentDenyResult(run, fileName, toolName, fsModule) {
  if (!run) return unverified('scenario missing');
  const output = subagentOutput(run, CALLS.subDeny);
  if (output === null) return unverified('the denied subagent call produced no output');
  const denied = hooksOf(run, 'PreToolUse').filter((hook) => hook.payload.tool_name === toolName && hook.payload.agent_id !== undefined);
  const posted = hooksOf(run, 'PostToolUse').some((hook) => hook.payload.tool_name === toolName && hook.payload.agent_id !== undefined);
  const reasonReachesSubagent = output.includes(MARKERS.deny);
  return {
    blocked: denied.length > 0 && reasonReachesSubagent && !fileExists(run.project, fileName, fsModule) && !posted,
    reasonReachesSubagent,
    deniedPayloadAgentType: denied.length ? agentTypeOf(denied[0].payload) : 'not-observed',
  };
}

function spawnDenyResult(run) {
  if (!run) return unverified('scenario missing');
  const output = outputFor(run, CALLS.deny);
  if (output === null) return unverified('the denied spawn produced no output');
  const reasonReachesModel = output.includes(MARKERS.deny);
  const started = hooksOf(run, 'SubagentStart').length > 0 || run.requests.some(isSubagentBody);
  return { blocked: reasonReachesModel && !started, reasonReachesModel };
}

function subagentSpawnDenyResult(run) {
  if (!run) return unverified('scenario missing');
  const output = subagentOutput(run, CALLS.subDeny);
  if (output === null) return unverified('the denied subagent spawn produced no output');
  const reasonReachesSubagent = output.includes(MARKERS.deny);
  const agents = uniqueSorted(hooksOf(run, 'SubagentStart').map((hook) => hook.payload.agent_id));
  return { blocked: reasonReachesSubagent && agents.length === 1, reasonReachesSubagent };
}

function deriveMatcherHits(runs) {
  const hits = {};
  for (const run of runs) {
    for (const hook of run.hooks || []) {
      const name = hook.event === 'PreToolUse' && hook.payload ? hook.payload.tool_name : null;
      if (!name) continue;
      if (!hits[name]) hits[name] = new Set();
      const label = labelOf(hook);
      if (MATCHERS.some((entry) => entry.label === label)) hits[name].add(label);
    }
  }
  if (!Object.keys(hits).length) return unverified('no PreToolUse record');
  return Object.fromEntries(Object.keys(hits).sort().map((name) => [name, [...hits[name]].sort()]));
}

function deriveDeny(runs, r, fsModule) {
  return {
    classic: {
      bashJson: denyResult(r['deny-classic-bash-json'], FILES.denied, fsModule),
      bashExit2: denyResult(r['deny-classic-bash-exit2'], FILES.denied, fsModule),
    },
    codeMode: {
      bashJson: denyResult(r['deny-code-bash-json'], FILES.denied, fsModule),
      bashExit2: denyResult(r['deny-code-bash-exit2'], FILES.denied, fsModule),
      applyPatchJson: denyResult(r['deny-code-patch-json'], FILES.patched, fsModule),
      applyPatchExit2: denyResult(r['deny-code-patch-exit2'], FILES.patched, fsModule),
      applyPatchByClaudeEditNames: denyResult(r['deny-code-patch-edit-json'], FILES.patched, fsModule),
    },
    gpt55: {
      bashJson: denyResult(r['deny-gpt55-bash-json'], FILES.denied, fsModule),
      applyPatchJson: denyResult(r['deny-gpt55-patch-json'], FILES.patched, fsModule),
    },
    subagent: {
      classic: {
        bashJson: subagentDenyResult(r['deny-sub-classic-bash-json'], FILES.subDenied, 'Bash', fsModule),
        bashExit2: subagentDenyResult(r['deny-sub-classic-bash-exit2'], FILES.subDenied, 'Bash', fsModule),
      },
      codeMode: {
        bashJson: subagentDenyResult(r['deny-sub-code-bash-json'], FILES.subDenied, 'Bash', fsModule),
        bashExit2: subagentDenyResult(r['deny-sub-code-bash-exit2'], FILES.subDenied, 'Bash', fsModule),
        applyPatchJson: subagentDenyResult(r['deny-sub-code-patch-json'], FILES.subDeniedPatch, 'apply_patch', fsModule),
        applyPatchExit2: subagentDenyResult(r['deny-sub-code-patch-exit2'], FILES.subDeniedPatch, 'apply_patch', fsModule),
        spawnJson: subagentSpawnDenyResult(r['deny-sub-code-spawn-json']),
      },
    },
    spawn: {
      classic: spawnDenyResult(r['deny-classic-spawn-json']),
      codeMode: spawnDenyResult(r['deny-code-spawn-json']),
    },
    trustedWithoutBypass: {
      execClassicBashJson: denyResult(r['deny-classic-bash-json-trusted'], FILES.denied, fsModule),
      appServerBashJson: denyResult(r['app-gates'], FILES.denied, fsModule),
    },
    matcherHits: deriveMatcherHits(runs),
  };
}

function stopShape(run) {
  if (!run) return unverified('scenario missing');
  const marked = run.requests.filter((body) => JSON.stringify(body).includes(MARKERS.stop)).length;
  return {
    modelRequests: run.requests.length,
    blocks: run.requests.length > 1 && marked > 0,
    reasonDeliveries: marked,
    stopHookActive: hooksOf(run, 'Stop').map((hook) => hook.payload.stop_hook_active),
  };
}

function deriveStop(r) {
  const shapes = (prefix) => ({
    decisionBlock: stopShape(r[`${prefix}decision-block`]),
    exit2: stopShape(r[`${prefix}exit2`]),
    continueFalse: stopShape(r[`${prefix}continue-false`]),
    systemMessage: stopShape(r[`${prefix}system-message`]),
  });
  const block = r['stop-decision-block'];
  const last = block && block.requests[block.requests.length - 1];
  const wrapper = last ? /<hook_prompt hook_run_id=\\?"([a-z-]+):(\d+):[^"\\]*\\?">/.exec(JSON.stringify(last)) : null;
  return {
    classic: shapes('stop-'),
    codeMode: shapes('stop-code-'),
    gpt55: { decisionBlock: stopShape(r['stop-gpt55-decision-block']) },
    trustedWithoutBypass: {
      execClassicDecisionBlock: stopShape(r['stop-decision-block-trusted']),
      appServerDecisionBlock: stopShape(r['app-gates']),
    },
    reasonWrapper: wrapper ? `<hook_prompt hook_run_id="${wrapper[1]}:<event-index>:<hooks-file>">` : unverified('stop-decision-block delivered no wrapped block reason'),
  };
}

function parentReceipt(run) {
  const stops = hooksOf(run, 'SubagentStop');
  if (!stops.length) return unverified('no SubagentStop record');
  const final = stops[stops.length - 1].payload.last_assistant_message;
  const held = stops.slice(0, -1).map((stop) => stop.payload.last_assistant_message).filter((text) => text !== final);
  const rootText = JSON.stringify(run.requests.filter((body) => !isSubagentBody(body)).map(inputOf));
  const has = (text) => typeof text === 'string' && text !== '' && rootText.includes(text);
  const gotFinal = has(final);
  const gotPreHold = held.some(has);
  if (gotFinal && gotPreHold) return 'both';
  if (gotFinal) return 'final';
  if (gotPreHold) return 'pre-hold';
  return 'none';
}

function waitTimedOut(run, callId) {
  const text = outputFor(run, callId);
  if (text === null) return unverified('the wait produced no output');
  const parsed = parseJson(text);
  return parsed && typeof parsed.timed_out === 'boolean' ? parsed.timed_out : unverified('the wait output carries no timed_out field');
}

function subagentStopView(run) {
  if (!run) return unverified('scenario missing');
  const marked = run.requests.filter((body) => JSON.stringify(body).includes(MARKERS.subagentStop));
  const toSubagent = marked.filter(isSubagentBody).length;
  const toParent = marked.length - toSubagent;
  let target = 'none';
  if (toSubagent && toParent) target = 'both';
  else if (toSubagent) target = 'subagent';
  else if (toParent) target = 'parent';
  return {
    blockTarget: target,
    subagentStopInvocations: hooksOf(run, 'SubagentStop').length,
    stopHookActive: hooksOf(run, 'SubagentStop').map((hook) => hook.payload.stop_hook_active),
    parentReceives: parentReceipt(run),
  };
}

function holdView(run) {
  if (!run) return unverified('scenario missing');
  return {
    subagentStopInvocations: hooksOf(run, 'SubagentStop').length,
    firstWaitTimedOut: waitTimedOut(run, CALLS.waitFirst),
    secondWaitTimedOut: waitTimedOut(run, CALLS.waitSecond),
    parentReceives: parentReceipt(run),
  };
}

function deriveSubagentStop(r) {
  return {
    classic: subagentStopView(r['spawn-classic-subagent-stop-block']),
    codeMode: subagentStopView(r['spawn-code-subagent-stop-block']),
    holdOutlastingWait: {
      classic: holdView(r['spawn-classic-subagent-stop-hold']),
      codeMode: holdView(r['spawn-code-subagent-stop-hold']),
    },
  };
}

function modeAnswer(text) {
  if (text === null) return unverified('the request_user_input call produced no output');
  if (/unavailable in Default mode/.test(text)) return 'unavailable';
  const parsed = parseJson(text);
  return parsed && parsed.answers ? 'answered' : 'other';
}

function deriveRequestUserInput(r) {
  const classic = r['classic-rui'];
  const code = r['code-rui'];
  const app = r['app-rui'];
  if (!classic || !code || !app || !app.result || !app.result.threads) return unverified('request_user_input scenarios missing');
  const tool = findTool(classic.requests[0], 'request_user_input');
  const questions = tool && tool.parameters.properties.questions;
  const options = questions && questions.items && questions.items.properties.options;
  const range = options ? /Provide (\d+)-(\d+)/.exec(options.description || '') : null;
  const max = questions ? /do not exceed (\d+)/.exec(questions.description || '') : null;
  const planRequests = (app.serverRequests || []).filter((request) => request.method === 'item/tool/requestUserInput');
  const planMode = (threadId) => (planRequests.some((request) => request.params && request.params.threadId === threadId) ? 'server-request' : 'none');
  const answerShape = (callId) => {
    const parsed = parseJson(outputFor(app, callId) || '');
    return parsed && parsed.answers ? 'answers.<question id>.answers[]' : null;
  };
  return {
    offeredInDefaultMode: { classic: Boolean(tool), codeMode: Boolean(findTool(code.requests[0], 'request_user_input')) },
    exec: { classic: modeAnswer(outputFor(classic, CALLS.rui)), codeMode: modeAnswer(outputFor(code, CALLS.rui)) },
    appServer: {
      classic: { defaultMode: modeAnswer(outputFor(app, CALLS.ruiDefault)), planMode: planMode(app.result.threads.classic), answerShape: answerShape(CALLS.ruiPlan) },
      codeMode: { defaultMode: modeAnswer(outputFor(app, CALLS.ruiCodeDefault)), planMode: planMode(app.result.threads.code), answerShape: answerShape(CALLS.ruiCodePlan) },
    },
    serverRequestMethod: planRequests.length ? planRequests[0].method : null,
    serverRequestFields: planRequests.length ? Object.keys(planRequests[0].params).sort() : null,
    maxQuestions: max ? Number(max[1]) : null,
    optionsPerQuestion: range ? `${range[1]}-${range[2]}` : null,
  };
}

function callReply(run, callId) {
  const text = subagentOutput(run, callId);
  if (text === null) return unverified('the call produced no output');
  return text === '' ? { accepted: true } : { accepted: false, reply: text.slice(0, 160) };
}

function subagentApprovalView(run) {
  if (!run) return unverified('scenario missing');
  const approval = TUI_STRINGS.approvalPrompt;
  const rootBodies = run.requests.filter((body) => !isSubagentBody(body));
  const carriers = uniqueSorted(rootBodies.flatMap((body) => inputOf(body)
    .filter((item) => JSON.stringify(item).includes(approval))
    .map((item) => (item.role ? `${item.type}:${item.role}` : item.type))));
  return {
    sendMessageToRoot: callReply(run, CALLS.rootMessage),
    sendMessageToRelativeParent: callReply(run, CALLS.rootMessageRelative),
    followupTaskToRoot: callReply(run, CALLS.rootFollowup),
    rootReceivesTextAs: carriers,
    rootUserPromptSubmitsWithText: hooksOf(run, 'UserPromptSubmit').filter((hook) => hook.payload.agent_id === undefined && hook.payload.prompt === approval).length,
  };
}

function derivePlanMode(r, strings) {
  const trust = r['app-trust'];
  const lists = r['app-lists'];
  const modes = lists && lists.result && lists.result.modes && lists.result.modes.data
    ? uniqueSorted(lists.result.modes.data.map((mode) => mode.mode))
    : unverified('app-lists did not return collaboration modes');
  if (!trust || !trust.result) return unverified('app-trust scenario missing');
  const planItem = (trust.result.planItemDetails || []).find((item) => item.type === 'plan');
  const rootPrompts = hooksOf(trust, 'UserPromptSubmit').filter((hook) => hook.payload.agent_id === undefined);
  const planTurnModes = (prompt) => {
    const hook = rootPrompts.find((item) => item.payload.prompt === prompt);
    return hook
      ? uniqueSorted((trust.hooks || []).filter((item) => !labelOf(item) && item.payload && item.payload.turn_id === hook.payload.turn_id).map((item) => item.payload.permission_mode))
      : unverified(`no UserPromptSubmit record for the plan turn "${prompt}"`);
  };
  return {
    collaborationModes: modes,
    proposedPlanItemType: planItem ? planItem.type : null,
    planItemCarriesOnlyThePlan: Boolean(planItem && planItem.text.includes(MARKERS.planStep) && !planItem.text.includes(MARKERS.planIntro)),
    planDeltaNotification: (trust.result.planMethods || []).includes('item/plan/delta'),
    approvalPromptReachesUserPromptSubmit: rootPrompts.some((hook) => hook.payload.prompt === TUI_STRINGS.approvalPrompt),
    userPromptSubmitCarriesMode: hooksOf(trust, 'UserPromptSubmit').some((hook) => Object.keys(hook.payload).some((key) => key !== 'permission_mode' && /(^|_)mode$/.test(key))),
    planTurnPermissionModes: {
      defaultThread: planTurnModes(PROMPTS.makePlan),
      onRequestWorkspaceWriteThread: planTurnModes(PROMPTS.makePlanOnRequest),
    },
    planToolHooked: Boolean(subagentRecord(trust, 'PreToolUse', 'Bash', MARKERS.planTool)),
    subagentApprovalText: subagentApprovalView(r['subagent-message-root']),
    tuiApprovalStrings: strings,
  };
}

function execTrustView(run) {
  if (!run) return unverified('scenario missing');
  return {
    pluginHooksRan: (run.hooks || []).length > 0,
    reachedModel: run.requests.length > 0,
    eventsMentionHooks: (run.events || []).some((event) => /hook/i.test(JSON.stringify(event))),
    stderrMentionsHooks: /hook/i.test((run.proc && run.proc.stderr) || ''),
  };
}

function deriveHookTrust(r, ctx) {
  const untrusted = r['app-untrusted-turn'];
  const trust = r['app-trust'];
  if (!untrusted || !trust || !trust.result) return unverified('trust scenarios missing');
  const statuses = (list) => uniqueSorted((list || []).map((hook) => hook.trustStatus));
  const invalidated = (list) => uniqueSorted((list || []).filter((hook) => hook.trustStatus !== 'trusted').map((hook) => `${hook.event}:${hook.trustStatus}`));
  const keys = (trust.result.before || []).map((hook) => hook.key);
  const keyPattern = keys.length && keys.every((key) => key.startsWith(`${ctx.plugin.id}:hooks/hooks.json:`) && /:[a-z_]+:\d+:\d+$/.test(key))
    ? '<plugin>@<marketplace>:<hooks file>:<event_snake_case>:<group index>:<hook index>'
    : 'other';
  return {
    untrustedHooksRun: (untrusted.hooks || []).length > 0,
    untrustedTurnReachedModel: (untrusted.requests || []).length > 0,
    untrustedTurnHookNotices: uniqueSorted((untrusted.notices || []).filter((notice) => /hook/i.test(JSON.stringify(notice.params || {}))).map((notice) => notice.method)),
    untrustedTurnHookRunNotifications: (untrusted.hookNotifications || []).length,
    untrustedTurnHookListErrors: untrusted.result && untrusted.result.hooks ? untrusted.result.hooks.data[0].errors.length : unverified('app-untrusted-turn returned no hook listing'),
    trustedTurnHookRunEvents: uniqueSorted((trust.hookNotifications || []).filter((n) => n.method === 'hook/completed').map((n) => n.eventName)),
    trustedTurnHookRunStatuses: uniqueSorted((trust.hookNotifications || []).map((n) => `${n.method}:${n.status}`)),
    trustedTurnHookRunSources: uniqueSorted((trust.hookNotifications || []).map((n) => n.source)),
    statusesBeforeTrust: statuses(trust.result.before),
    statusesAfterTrust: statuses(trust.result.after),
    keyPattern,
    hashPrefix: uniqueSorted((trust.result.before || []).map((hook) => String(hook.currentHash).split(':')[0])),
    storage: (trust.result.trustConfigLines || []).some((line) => line.startsWith('[hooks.state."')) && (trust.result.trustConfigLines || []).some((line) => /^trusted_hash = "sha256:/.test(line))
      ? 'config.toml [hooks.state."<key>"] trusted_hash'
      : 'other',
    afterVersionBump: statuses(trust.result.afterVersionBump),
    afterScriptEdit: statuses(trust.result.afterScriptEdit),
    afterCommandEdit: statuses(trust.result.afterCommandEdit),
    commandEditInvalidates: invalidated(trust.result.afterCommandEdit),
    afterGroupInsert: statuses(trust.result.afterGroupInsert),
    groupInsertInvalidates: invalidated(trust.result.afterGroupInsert),
    afterRestore: statuses(trust.result.afterRestore),
    afterSemanticScriptEdit: statuses(trust.result.afterSemanticEdit),
    semanticScriptEditRunsWithoutRetrust: trust.result.semanticEditRan === undefined ? unverified('app-trust did not run the semantic edit turn') : trust.result.semanticEditRan,
    afterGroupAppend: statuses(trust.result.afterGroupAppend),
    groupAppendUntrusted: uniqueSorted((trust.result.afterGroupAppend || []).filter((hook) => hook.trustStatus !== 'trusted').map((hook) => `${hook.key.split(':').slice(-3).join(':')}:${hook.trustStatus}`)),
    execWithoutBypass: {
      beforeTrust: execTrustView(r['exec-untrusted']),
      afterTrust: execTrustView(r['exec-trusted']),
    },
  };
}

function neverApproval(text) {
  if (text === null) return unverified('the escalation call produced no output');
  return /approval policy is Never/.test(text);
}

function derivePermissionRequest(r) {
  const app = r['app-permission'];
  const exec = r['permission-request'];
  return {
    appServerOnRequest: app ? hooksOf(app, 'PermissionRequest').length > 0 : unverified('app-permission scenario missing'),
    execForcesNeverApproval: exec ? neverApproval(outputFor(exec, CALLS.escalate)) : unverified('permission-request scenario missing'),
    execPermissionRequestHooks: exec ? hooksOf(exec, 'PermissionRequest').length : unverified('permission-request scenario missing'),
    clientApprovalRequest: app ? uniqueSorted((app.serverRequests || []).map((request) => request.method)) : unverified('app-permission scenario missing'),
  };
}

function compactionView(run) {
  if (!run) return unverified('scenario missing');
  return {
    preCompactTrigger: uniqueSorted(hooksOf(run, 'PreCompact').map((hook) => hook.payload.trigger)),
    postCompactFired: hooksOf(run, 'PostCompact').length > 0,
    postCompactTrigger: uniqueSorted(hooksOf(run, 'PostCompact').map((hook) => hook.payload.trigger)),
    sessionStartSources: uniqueSorted(hooksOf(run, 'SessionStart').map((hook) => hook.payload.source)),
  };
}

function deriveCompaction(r) {
  return { auto: compactionView(r['compact-auto']), manual: compactionView(r['app-interrupt-compact']) };
}

function deriveInterrupt(r) {
  const run = r['app-interrupt-compact'];
  if (!run || !run.result) return unverified('scenario missing');
  return {
    hookFired: hooksOf(run, 'Interrupt').length > 0,
    turnStatus: run.result.interruptStatus && run.result.interruptStatus.turn ? run.result.interruptStatus.turn.status : null,
  };
}

function recorderVersion(hook) {
  const match = /[\\/]plugins[\\/]cache[\\/][^\\/]+[\\/][^\\/]+[\\/]([^\\/]+)[\\/]hooks[\\/]record\.js$/.exec(String(hook.script || ''));
  return match ? match[1] : null;
}

function pluginRootVariable(hook) {
  if (typeof hook.script !== 'string' || !hook.env) return 'unrecorded';
  const own = path.dirname(path.dirname(hook.script));
  const values = ['CLAUDE_PLUGIN_ROOT', 'PLUGIN_ROOT'].map((name) => hook.env[name]).filter((value) => value !== undefined);
  if (values.length === 0) return 'absent';
  return values.every((value) => value === own) ? 'own-installation' : 'other-installation';
}

function updatePhase(run, start, end, versions, hookRuns) {
  if (!Number.isFinite(start) || !Number.isFinite(end)) return unverified('the phase was not reached');
  const inPhase = (run.hooks || []).filter((hook) => Number(hook.at) >= start && Number(hook.at) <= end);
  const records = inPhase.filter((hook) => !labelOf(hook));
  const installation = (hook) => {
    const version = recorderVersion(hook);
    if (version === versions.to) return 'new';
    if (versions.from.includes(version)) return 'old';
    return 'other';
  };
  return {
    recorders: uniqueSorted(records.map(installation)),
    events: uniqueSorted(records.map((hook) => hook.event)),
    sessionStartSources: uniqueSorted(records.filter((hook) => hook.event === 'SessionStart').map((hook) => hook.payload && hook.payload.source)),
    hookRunStatuses: uniqueSorted((hookRuns || []).filter((n) => n.method === 'hook/completed').map((n) => n.status)),
    addedHookRan: inPhase.some((hook) => labelOf(hook) === MARKERS.updateAddedHook),
    pluginRootVariables: uniqueSorted(records.map(pluginRootVariable)),
  };
}

function derivePluginUpdate(r) {
  const run = r['app-plugin-update'];
  if (!run || !run.result || !run.result.marks || !run.result.hookRuns) return unverified('app-plugin-update scenario missing');
  const result = run.result;
  const marks = result.marks;
  const versions = { from: result.fromVersions || [], to: result.toVersion };
  const installed = result.installedAfterUpdate || [];
  const resumed = result.resumed || {};
  return {
    installedVia: result.update && result.update.via ? result.update.via : unverified('the update reported no install route'),
    oldInstallationRemoved: installed.includes(versions.to) && versions.from.every((version) => !installed.includes(version)),
    hookTrustAfterUpdate: uniqueSorted((result.listedAfterUpdate || []).map((hook) => hook.trustStatus)),
    loadedThread: {
      beforeUpdate: updatePhase(run, marks.beforeUpdateStart, marks.beforeUpdateEnd, versions, result.hookRuns.beforeUpdate),
      afterUpdate: updatePhase(run, marks.loadedStart, marks.loadedEnd, versions, result.hookRuns.loadedAfterUpdate),
      afterTrust: updatePhase(run, marks.retrustedStart, marks.retrustedEnd, versions, result.hookRuns.loadedAfterRetrust),
    },
    resumedThread: resumed.resumed === true
      ? updatePhase(run, marks.resumedStart, marks.resumedEnd, versions, resumed.hookRuns)
      : unverified('a fresh app server could not resume the thread'),
  };
}

function placeOf(value, places) {
  if (typeof value !== 'string' || value === '') return 'absent';
  const resolved = path.resolve(value);
  if (resolved === path.resolve(places.project)) return 'project';
  if (resolved === path.resolve(places.worktree)) return 'worktree';
  return 'other';
}

function recordsBetween(run, start, end) {
  return (run.hooks || []).filter((hook) => !labelOf(hook) && Number(hook.at) >= start && Number(hook.at) <= end);
}

function movePhase(run, start, end, places, hookRuns, callId) {
  if (!Number.isFinite(start) || !Number.isFinite(end)) return unverified('the phase was not reached');
  const records = recordsBetween(run, start, end);
  const byEvent = {};
  for (const hook of records) byEvent[hook.event] = [...(byEvent[hook.event] || []), placeOf(hook.payload && hook.payload.cwd, places)];
  const shell = new RegExp(`${MARKERS.movePwd}=([^\\n]*)`).exec(outputFor(run, callId) || '');
  return {
    events: uniqueSorted(records.map((hook) => hook.event)),
    sessionStartSources: uniqueSorted(records.filter((hook) => hook.event === 'SessionStart').map((hook) => hook.payload && hook.payload.source)),
    payloadCwd: Object.fromEntries(Object.keys(byEvent).sort().map((event) => [event, uniqueSorted(byEvent[event])])),
    hookProcessCwd: uniqueSorted(records.map((hook) => placeOf(hook.cwd, places))),
    shellCwd: shell ? placeOf(shell[1].trim(), places) : unverified('the shell call reported no working directory'),
    hookRunStatuses: uniqueSorted((hookRuns || []).filter((n) => n.method === 'hook/completed').map((n) => n.status)),
  };
}

function deriveWorktreeMove(r) {
  const run = r['app-worktree-move'];
  if (!run || !run.result || !run.result.marks || !run.result.hookRuns || typeof run.result.worktree !== 'string' || typeof run.project !== 'string') {
    return unverified('app-worktree-move scenario missing');
  }
  const result = run.result;
  const marks = result.marks;
  const places = { project: run.project, worktree: result.worktree };
  const resumed = result.resumed || {};
  const sessions = uniqueSorted((run.hooks || []).filter((hook) => !labelOf(hook)).map((hook) => hook.payload && hook.payload.session_id));
  const movedPrompts = recordsBetween(run, marks.movedStart, marks.movedEnd).filter((hook) => hook.event === 'UserPromptSubmit');
  return {
    secondWorktreeSharesGitCommonDir: result.sameCommonDir === true,
    sessionIdUnchanged: sessions.length === 1,
    movedTurnPromptVerbatim: movedPrompts.length > 0 && movedPrompts.every((hook) => hook.payload && hook.payload.prompt === PROMPTS.moveMoved),
    loadedThread: {
      beforeMove: movePhase(run, marks.beforeStart, marks.beforeEnd, places, result.hookRuns.before, CALLS.moveBefore),
      movedTurn: movePhase(run, marks.movedStart, marks.movedEnd, places, result.hookRuns.moved, CALLS.moveMoved),
      laterTurn: movePhase(run, marks.laterStart, marks.laterEnd, places, result.hookRuns.later, CALLS.moveLater),
    },
    resumedThread: resumed.resumed === true
      ? { responseCwd: placeOf(resumed.cwd, places), ...movePhase(run, marks.resumedStart, marks.resumedEnd, places, resumed.hookRuns, CALLS.moveResumed) }
      : unverified('a fresh app server could not resume the thread'),
  };
}

function deriveFacts(runs, ctx) {
  const r = byName(runs);
  const fsModule = ctx.fs;
  return {
    events: deriveEvents(runs, r),
    hookPayloads: deriveHookPayloads(runs),
    hookEnvironment: deriveHookEnvironment(r, ctx),
    features: deriveFeatures(r),
    threadId: deriveThreadId(r),
    subagents: deriveSubagents(r),
    skills: deriveSkills(r, ctx),
    agentRoles: deriveAgentRoles(r, fsModule),
    toolSurfaces: deriveToolSurfaces(r),
    toolHooks: deriveToolHooks(r, fsModule),
    deny: deriveDeny(runs, r, fsModule),
    stop: deriveStop(r),
    subagentStop: deriveSubagentStop(r),
    requestUserInput: deriveRequestUserInput(r),
    planMode: derivePlanMode(r, ctx.tuiStrings),
    hookTrust: deriveHookTrust(r, ctx),
    permissionRequest: derivePermissionRequest(r),
    compaction: deriveCompaction(r),
    interrupt: deriveInterrupt(r),
    pluginUpdate: derivePluginUpdate(r),
    worktreeMove: deriveWorktreeMove(r),
  };
}

function deriveGate(facts) {
  const blocked = (value) => Boolean(value && value.blocked === true);
  const blocks = (value) => Boolean(value && value.blocks === true);
  const deny = facts.deny || {};
  const sub = deny.subagent || {};
  const stop = facts.stop || {};
  const trusted = deny.trustedWithoutBypass || {};
  const trustedStop = stop.trustedWithoutBypass || {};
  const gate = {
    denyShell: blocked(deny.classic && deny.classic.bashJson) && blocked(deny.codeMode && deny.codeMode.bashJson) && blocked(deny.gpt55 && deny.gpt55.bashJson),
    denyApplyPatch: blocked(deny.codeMode && deny.codeMode.applyPatchJson) && blocked(deny.gpt55 && deny.gpt55.applyPatchJson),
    denySubagent: blocked(sub.classic && sub.classic.bashJson) && blocked(sub.codeMode && sub.codeMode.bashJson) && blocked(sub.codeMode && sub.codeMode.applyPatchJson) && blocked(sub.codeMode && sub.codeMode.spawnJson),
    stopBlocks: blocks(stop.classic && stop.classic.decisionBlock) && blocks(stop.codeMode && stop.codeMode.decisionBlock) && blocks(stop.gpt55 && stop.gpt55.decisionBlock),
    trustedGates: blocked(trusted.execClassicBashJson) && blocked(trusted.appServerBashJson) && blocks(trustedStop.execClassicDecisionBlock) && blocks(trustedStop.appServerDecisionBlock),
  };
  return { ...gate, verdict: GATE_INPUTS.every((key) => gate[key]) ? 'continue' : 'stop' };
}

function collectUnverified(value, prefix = '') {
  if (!value || typeof value !== 'object') return [];
  if (Object.prototype.hasOwnProperty.call(value, 'unverified') && Object.keys(value).length === 1) return [`${prefix}: ${value.unverified}`];
  return Object.entries(value).flatMap(([key, child]) => collectUnverified(child, prefix ? `${prefix}.${key}` : key));
}

function validateResults(results) {
  const errors = [];
  if (!results || typeof results !== 'object') return ['results is not an object'];
  if (results.schemaVersion !== SCHEMA_VERSION) errors.push(`schemaVersion must be ${SCHEMA_VERSION}`);
  if (typeof results.codexVersion !== 'string' || !/^\d+\.\d+\.\d+/.test(results.codexVersion)) errors.push('codexVersion must be a version string');
  if (typeof results.measuredOn !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(results.measuredOn)) errors.push('measuredOn must be YYYY-MM-DD');
  if (!results.conditions || typeof results.conditions !== 'object') errors.push('conditions missing');
  if (!results.facts || typeof results.facts !== 'object') {
    errors.push('facts missing');
  } else {
    for (const key of FACT_KEYS) if (!Object.prototype.hasOwnProperty.call(results.facts, key)) errors.push(`facts.${key} missing`);
    for (const item of collectUnverified(results.facts)) if (!/\S/.test(item.split(': ')[1] || '')) errors.push(`unverified without a reason: ${item}`);
  }
  if (!results.gate || !GATE_VERDICTS.includes(results.gate.verdict)) errors.push('gate.verdict must be continue or stop');
  else for (const key of GATE_INPUTS) if (typeof results.gate[key] !== 'boolean') errors.push(`gate.${key} must be a boolean`);
  const text = JSON.stringify(results);
  if (/\/(Users|home|private\/var|var\/folders|tmp)\//.test(text)) errors.push('results contain an absolute path');
  if (/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.test(text)) errors.push('results contain a UUID');
  return errors;
}

function comparable(results) {
  const copy = JSON.parse(JSON.stringify(results));
  delete copy.measuredOn;
  if (copy.conditions) delete copy.conditions.launcher;
  return copy;
}

function diffPaths(expected, actual, prefix = '') {
  if (JSON.stringify(expected) === JSON.stringify(actual)) return [];
  if (!expected || !actual || typeof expected !== 'object' || typeof actual !== 'object' || Array.isArray(expected) !== Array.isArray(actual)) {
    return [`${prefix || '<root>'}: recorded ${JSON.stringify(expected)} measured ${JSON.stringify(actual)}`];
  }
  const keys = uniqueSorted([...Object.keys(expected), ...Object.keys(actual)]);
  return keys.flatMap((key) => diffPaths(expected[key], actual[key], prefix ? `${prefix}.${key}` : key));
}

module.exports = {
  SCHEMA_VERSION,
  FACT_KEYS,
  GATE_INPUTS,
  byName,
  deriveFacts,
  deriveGate,
  validateResults,
  comparable,
  diffPaths,
  collectUnverified,
  toolsOfBody,
  findTool,
  outputOfCall,
  envLines,
  classifyValue,
};
