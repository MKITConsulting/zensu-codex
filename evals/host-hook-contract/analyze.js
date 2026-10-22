'use strict';

const path = require('node:path');
const { TUI_STRINGS, CONTEXT, MARKERS, FILES, PROMPTS, CALLS, ROLES, TWIN_ROLE, TOOLS_ROLE, MATCHERS, isSubagentBody } = require('./contract');

const SCHEMA_VERSION = 2;
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
];
const GATE_VERDICTS = ['continue', 'stop'];
const ENV_NAME = /^(CLAUDE|CODEX|PLUGIN|ZENSU)_/;
const LAUNCHER_VARIABLE = /^CODEX_MANAGED_/;
const DISCOVERY_ROLES = [...Object.keys(ROLES), TWIN_ROLE.name];
const ROLE_MARKERS = [...Object.values(ROLES), TWIN_ROLE.home, TWIN_ROLE.project, TOOLS_ROLE.marker];

function uniqueSorted(values) {
  return [...new Set(values.filter((value) => value !== undefined && value !== null))].sort();
}

function byName(runs) {
  return Object.fromEntries(runs.map((run) => [run.name, run]));
}

function unverified(reason) {
  return { unverified: reason };
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

function deriveHookEnvironment(r, ctx) {
  const run = r['classic-baseline'];
  const start = hooksOf(run, 'SessionStart')[0];
  if (!start) return unverified('classic-baseline recorded no SessionStart hook');
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
    hookCwd: start.cwd === run.project ? 'project-dir' : 'other',
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
    subagentHookSessionId: subStart ? idClass(subStart.session_id, spawn) : 'not-observed',
    subagentAgentIdIsSubagentThread: Boolean(subStart && idClass(subStart.agent_id, spawn) === 'subagent-thread'),
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
  const entry = lists && lists.result && lists.result.hooks ? lists.result.hooks.data[0] : null;
  const declared = entry ? entry.hooks.map((hook) => hook.eventName.charAt(0).toUpperCase() + hook.eventName.slice(1)) : [];
  const fired = uniqueSorted(runs.flatMap((run) => (run.hooks || []).map((hook) => hook.event)));
  return {
    registered: uniqueSorted(declared),
    registrationErrors: entry ? entry.errors.length : null,
    registrationWarnings: entry ? entry.warnings.length : null,
    fired,
    notFired: uniqueSorted(declared).filter((event) => !fired.includes(event)),
  };
}

function deriveHookPayloads(runs) {
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
  const instructions = JSON.stringify((r['classic-baseline'] && r['classic-baseline'].requests[0]) || {});
  return {
    pluginSkillNames: listed.map((name) => name.split(`${ctx.plugin.name}:`).join('<plugin>:').replace(/probe-skill$/, '<skill>')),
    namespaced: listed.includes(`${ctx.plugin.name}:probe-skill`),
    listedInModelInstructions: instructions.includes(`${ctx.plugin.name}:probe-skill`),
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

function toolProfileOf(r) {
  const tools = r['role-tools-code'];
  const base = r['spawn-code'];
  if (!tools || !base) return unverified('tool profile scenarios missing');
  const firstSubagentRequest = (run) => ((run && run.requests) || []).find(isSubagentBody) || null;
  const view = (body) => (body ? { tools: toolsOfBody(body), nested: nestedExecTools(body) } : unverified('no subagent request'));
  return {
    spawned: startedRoles(tools).includes(TOOLS_ROLE.name),
    instructionsApplied: roleMarkers(tools).includes(TOOLS_ROLE.marker),
    defaultAgent: view(firstSubagentRequest(base)),
    toolsRole: view(firstSubagentRequest(tools)),
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
    agentTypeParameterWithoutRoles: Boolean(spawnSchema(r['code-baseline']).agent_type),
    developerInstructionsApplied: roleMarkers(code),
    subagentStartAgentType: startedRoles(code),
    defaultAgentType: startedRoles(r['spawn-code']),
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
    toolProfile: toolProfileOf(r),
  };
}

function deriveToolSurfaces(r) {
  const classic = r['classic-baseline'];
  const code = r['code-baseline'];
  const rui = r['app-rui'];
  if (!classic || !code) return unverified('baseline scenarios missing');
  const classicPlan = firstRequestWith(rui, PROMPTS.ruiPlan);
  const codePlan = firstRequestWith(rui, PROMPTS.ruiCodePlan);
  const allTools = [classic, code, rui].flatMap((run) => ((run && run.requests) || []).flatMap((body) => [...toolsOfBody(body), ...nestedExecTools(body)]));
  return {
    classic: toolsOfBody(classic.requests[0]),
    codeMode: toolsOfBody(code.requests[0]),
    codeModeNested: nestedExecTools(code.requests[0]),
    classicPlanMode: classicPlan ? toolsOfBody(classicPlan) : unverified('no request for the classic Plan-mode turn'),
    codeModePlanMode: codePlan ? { tools: toolsOfBody(codePlan), nested: nestedExecTools(codePlan) } : unverified('no request for the code-mode Plan-mode turn'),
    updatePlanOffered: allTools.some((name) => /(^|\.)update_plan$/.test(name)),
    applyPatchOffered: { classic: toolsOfBody(classic.requests[0]).some((name) => /apply_patch/.test(name)), codeMode: nestedExecTools(code.requests[0]).includes('apply_patch') },
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
  return {
    execCommand: {
      classic: preToolNames(classic)[0] || null,
      codeMode: preToolNames(code)[0] || null,
      inputKeys: inputKeys(classic, 'Bash'),
      ttyInputKeys: { classic: inputKeys(r['classic-stdin'], 'Bash'), codeMode: inputKeys(r['code-stdin'], 'Bash') },
    },
    applyPatch: {
      codeMode: preToolNames(patch)[0] || null,
      inputKeys: inputKeys(patch, 'apply_patch'),
      patchTextIn: hooksOf(patch, 'PreToolUse').some((hook) => hook.payload.tool_input && hook.payload.tool_input.command && hook.payload.tool_input.command.includes('*** Begin Patch')) ? 'tool_input.command' : 'other',
      multiFileEvents: multi ? hooksOf(multi, 'PreToolUse').length : null,
      multiFileApplied: multi ? FILES.multi.every((name) => fileContains(multi.project, name, 'PROBE_', fsModule)) : null,
    },
    writeStdin: deriveWriteStdin(r, fsModule),
    codeModeOuterExecHooked: [code, patch].some((run) => preToolNames(run).includes('exec')),
    spawnAgent: {
      classic: spawnHookNames(r['spawn-classic']),
      codeMode: spawnHookNames(r['spawn-code']),
    },
    requestUserInput: preToolNames(r['classic-rui'])[0] || null,
    postToolUseResponseType: typeof (payloadOf(classic, 'PostToolUse') || {}).tool_response,
    permissionRequestInputKeys: permission && permission.tool_input ? Object.keys(permission.tool_input).sort() : null,
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
    reasonWrapper: wrapper ? `<hook_prompt hook_run_id="${wrapper[1]}:<event-index>:<hooks-file>">` : null,
  };
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
  };
}

function deriveSubagentStop(r) {
  return {
    classic: subagentStopView(r['spawn-classic-subagent-stop-block']),
    codeMode: subagentStopView(r['spawn-code-subagent-stop-block']),
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
  const planRequests = app.serverRequests.filter((request) => request.method === 'item/tool/requestUserInput');
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

function derivePlanMode(r, strings) {
  const trust = r['app-trust'];
  const lists = r['app-lists'];
  const modes = lists && lists.result && lists.result.modes && lists.result.modes.data
    ? uniqueSorted(lists.result.modes.data.map((mode) => mode.mode))
    : null;
  if (!trust || !trust.result) return unverified('app-trust scenario missing');
  const planItem = (trust.result.planItemDetails || []).find((item) => item.type === 'plan');
  const rootPrompts = hooksOf(trust, 'UserPromptSubmit').filter((hook) => hook.payload.agent_id === undefined);
  const planPrompt = rootPrompts.find((hook) => hook.payload.prompt === PROMPTS.makePlan);
  const planTurnId = planPrompt ? planPrompt.payload.turn_id : null;
  return {
    collaborationModes: modes,
    proposedPlanItemType: planItem ? planItem.type : null,
    planItemCarriesOnlyThePlan: Boolean(planItem && planItem.text.includes(MARKERS.planStep) && !planItem.text.includes(MARKERS.planIntro)),
    planDeltaNotification: (trust.result.planMethods || []).includes('item/plan/delta'),
    approvalPromptReachesUserPromptSubmit: rootPrompts.some((hook) => hook.payload.prompt === TUI_STRINGS.approvalPrompt),
    userPromptSubmitCarriesMode: hooksOf(trust, 'UserPromptSubmit').some((hook) => Object.keys(hook.payload).some((key) => key !== 'permission_mode' && /(^|_)mode$/.test(key))),
    planTurnPermissionModes: planTurnId
      ? uniqueSorted((trust.hooks || []).filter((hook) => !labelOf(hook) && hook.payload && hook.payload.turn_id === planTurnId).map((hook) => hook.payload.permission_mode))
      : unverified('no UserPromptSubmit record for the plan turn'),
    planToolHooked: Boolean(subagentRecord(trust, 'PreToolUse', 'Bash', MARKERS.planTool)),
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
    untrustedTurnHookListErrors: untrusted.result && untrusted.result.hooks ? untrusted.result.hooks.data[0].errors.length : null,
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
    clientApprovalRequest: app ? uniqueSorted(app.serverRequests.map((request) => request.method)) : unverified('app-permission scenario missing'),
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
  };
}

function deriveGate(facts) {
  const blocked = (value) => Boolean(value && value.blocked === true);
  const blocks = (value) => Boolean(value && value.blocks === true);
  const deny = facts.deny || {};
  const stop = facts.stop || {};
  const denyShell = blocked(deny.classic && deny.classic.bashJson) && blocked(deny.codeMode && deny.codeMode.bashJson);
  const denyApplyPatch = blocked(deny.codeMode && deny.codeMode.applyPatchJson);
  const stopBlocks = blocks(stop.classic && stop.classic.decisionBlock) && blocks(stop.codeMode && stop.codeMode.decisionBlock);
  return { denyShell, denyApplyPatch, stopBlocks, verdict: denyShell && denyApplyPatch && stopBlocks ? 'continue' : 'stop' };
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
  else for (const key of ['denyShell', 'denyApplyPatch', 'stopBlocks']) if (typeof results.gate[key] !== 'boolean') errors.push(`gate.${key} must be a boolean`);
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
  deriveFacts,
  deriveGate,
  validateResults,
  comparable,
  diffPaths,
  collectUnverified,
  toolsOfBody,
  outputOfCall,
  envLines,
  classifyValue,
};
