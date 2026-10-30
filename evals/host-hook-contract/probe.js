'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { startMockModel } = require('./mock-model');
const { AppServerClient } = require('./app-server-client');
const { resolveCodex, nativeBinary, binaryStrings } = require('./codex-binary');
const processes = require('./processes');
const analyze = require('./analyze');
const contract = require('./contract');

const { TUI_STRINGS, CONTEXT, MARKERS, FILES, PROMPTS, CALLS, ROLES, TWIN_ROLE, TOOLS_ROLE } = contract;
const HERE = __dirname;
const FIXTURE = path.join(HERE, 'fixture');
const MODELS = { classic: 'probe-model', code: 'gpt-6-sol', gpt55: 'gpt-5.5' };
const SURFACES = {
  classic: (tools) => !tools.includes('functions.exec') && tools.includes('exec_command') && !tools.includes('apply_patch'),
  code: (tools) => tools.includes('functions.exec'),
  gpt55: (tools) => !tools.includes('functions.exec') && tools.includes('exec_command') && tools.includes('apply_patch') && !tools.some((name) => name.startsWith('multi_agent_v1.') || name.startsWith('collaboration.')),
};
const PLUGIN = { name: 'hookprobe', marketplace: 'probe-market', id: 'hookprobe@probe-market' };
const DEFAULTS = { approvalPolicy: 'never', sandboxMode: 'danger-full-access', features: { hooks: true, plugins: true } };
const PERMISSION_THREAD = { approvalPolicy: 'on-request', sandbox: 'workspace-write' };
const NOTICE_METHODS = ['configWarning', 'deprecationNotice', 'error', 'guardianWarning', 'warning'];
const RESULTS_DIR = path.join(HERE, 'results');
const DEAD_PROXY = 'http://127.0.0.1:9';
const LOOPBACK_HOSTS = '127.0.0.1,localhost,::1';
const APP_ORDER = ['app-lists', 'app-untrusted-turn', 'app-rui', 'app-trust', 'app-interrupt-compact', 'app-permission', 'app-gates'];
const ENV_CMD = 'env | LC_ALL=C sort; printf "PROBE_PWD=%s\\n" "$PWD"';
const STDIN_CMD = `head -n 1 > ${FILES.stdin}`;
const SUB_CMD = `touch ${FILES.subShell}; printf "${MARKERS.subagentShell}\\n"; env | LC_ALL=C sort`;
const PATCH = `*** Begin Patch\n*** Add File: ${FILES.patched}\n+${MARKERS.patchLine}\n*** End Patch\n`;
const MULTI_PATCH = `*** Begin Patch\n*** Add File: ${FILES.multi[0]}\n+${MARKERS.multiLines[0]}\n*** Add File: ${FILES.multi[1]}\n+${MARKERS.multiLines[1]}\n*** End Patch\n`;
const SUB_PATCH = `*** Begin Patch\n*** Add File: ${FILES.subPatch}\n+PROBE_SUB_PATCH_LINE\n*** End Patch\n`;
const PROPOSED_PLAN = `${MARKERS.planIntro}.\n\n<proposed_plan>\n# Probe plan\n\n- ${MARKERS.planStep}\n</proposed_plan>\n`;

function parseArgs(argv) {
  const opts = { codex: null, record: false, check: false, only: null, keep: false, timeoutSec: 180, print: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = () => {
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) throw new Error(`${arg} needs a value`);
      i += 1;
      return next;
    };
    if (arg === '--codex') opts.codex = value();
    else if (arg === '--record') opts.record = true;
    else if (arg === '--check') opts.check = true;
    else if (arg === '--only') opts.only = value().split(',').filter(Boolean);
    else if (arg === '--keep') opts.keep = true;
    else if (arg === '--timeout') opts.timeoutSec = Number(value());
    else if (arg === '--print') opts.print = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (opts.record && opts.check) throw new Error('--record and --check are mutually exclusive');
  if (!Number.isFinite(opts.timeoutSec) || opts.timeoutSec <= 0) throw new Error('--timeout needs a positive number of seconds');
  return opts;
}

function makeSandbox() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-hookprobe-')));
  const sandbox = {
    root,
    home: path.join(root, 'home'),
    codexHome: path.join(root, 'codex-home'),
    projects: path.join(root, 'projects'),
    out: path.join(root, 'out'),
    fixture: path.join(root, 'fixture'),
  };
  for (const dir of [sandbox.home, sandbox.codexHome, sandbox.projects, sandbox.out]) fs.mkdirSync(dir, { recursive: true });
  fs.cpSync(FIXTURE, sandbox.fixture, { recursive: true });
  return sandbox;
}

function baseEnv(sandbox) {
  const offline = {};
  for (const name of ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY']) {
    offline[name] = DEAD_PROXY;
    offline[name.toLowerCase()] = DEAD_PROXY;
  }
  return {
    PATH: process.env.PATH || '/usr/bin:/bin',
    HOME: sandbox.home,
    CODEX_HOME: sandbox.codexHome,
    TMPDIR: process.env.TMPDIR || os.tmpdir(),
    SHELL: '/bin/bash',
    LANG: 'en_US.UTF-8',
    ...offline,
    NO_PROXY: LOOPBACK_HOSTS,
    no_proxy: LOOPBACK_HOSTS,
    GIT_CONFIG_NOSYSTEM: '1',
  };
}

function tomlString(value) {
  return JSON.stringify(value);
}

function configFile(ctx) {
  return path.join(ctx.sandbox.codexHome, 'config.toml');
}

function writeConfig(ctx) {
  const lines = [
    `model = ${tomlString(MODELS.classic)}`,
    'model_provider = "probe"',
    `approval_policy = ${tomlString(DEFAULTS.approvalPolicy)}`,
    `sandbox_mode = ${tomlString(DEFAULTS.sandboxMode)}`,
    '',
    '[model_providers.probe]',
    'name = "Probe"',
    `base_url = ${tomlString(`http://127.0.0.1:${ctx.port}/v1`)}`,
    'wire_api = "responses"',
    'requires_openai_auth = false',
    '',
    '[features]',
    ...Object.entries(DEFAULTS.features).map(([name, enabled]) => `${name} = ${enabled}`),
    '',
  ];
  for (const project of ctx.projectDirs) lines.push(`[projects.${tomlString(project)}]`, 'trust_level = "trusted"', '');
  fs.writeFileSync(configFile(ctx), `${lines.join('\n')}\n`);
}

function withoutTable(text, table) {
  let skipping = false;
  return text.split('\n').filter((line) => {
    if (/^\s*\[/.test(line)) skipping = line.trim() === `[${table}]`;
    return !skipping;
  }).join('\n');
}

function dropFeatures(ctx) {
  ctx.savedConfig = fs.readFileSync(configFile(ctx), 'utf8');
  fs.writeFileSync(configFile(ctx), withoutTable(ctx.savedConfig, 'features'));
}

function restoreConfig(ctx) {
  if (ctx.savedConfig === undefined) return;
  fs.writeFileSync(configFile(ctx), ctx.savedConfig);
  delete ctx.savedConfig;
}

async function runCodex(ctx, args) {
  const result = await runProcess(ctx.codex, args, { env: ctx.env, cwd: ctx.sandbox.root, timeoutMs: 120000 });
  return { status: result.code, stdout: result.stdout, stderr: result.spawnError || result.stderr };
}

async function installPlugin(ctx) {
  const marketplace = await runCodex(ctx, ['plugin', 'marketplace', 'add', ctx.sandbox.fixture]);
  const plugin = await runCodex(ctx, ['plugin', 'add', PLUGIN.id]);
  return { marketplace, plugin };
}

function runProcess(command, args, { env, cwd, timeoutMs }) {
  if (processes.state.stopping) return Promise.resolve({ code: null, signal: null, timedOut: false, spawnError: 'the probe is stopping', stdout: '', stderr: '', ms: 0 });
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn(command, args, { env, cwd, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    const entry = processes.track(child);
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let spawnError = null;
    let settled = false;
    const timer = setTimeout(() => {
      timedOut = true;
      processes.signalGroup(child, 'SIGTERM');
      setTimeout(() => processes.signalGroup(child, 'SIGKILL'), 3000).unref();
    }, timeoutMs);
    const finish = (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      processes.reapGroup(child).then(() => {
        processes.untrack(entry);
        resolve({ code, signal, timedOut, spawnError, stdout, stderr, ms: Date.now() - started });
      });
    };
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('error', (error) => {
      spawnError = error.message;
      finish(null, null);
    });
    child.on('close', finish);
  });
}

function parseJsonl(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      out.push(JSON.parse(trimmed));
    } catch {
      out.push({ unparsed: trimmed.slice(0, 200) });
    }
  }
  return out;
}

function readHooks(dir) {
  const hooksDir = path.join(dir, 'hooks');
  const read = { hooks: [], errors: [] };
  if (!fs.existsSync(hooksDir)) return read;
  for (const name of fs.readdirSync(hooksDir).filter((entry) => entry.endsWith('.json'))) {
    try {
      read.hooks.push(JSON.parse(fs.readFileSync(path.join(hooksDir, name), 'utf8')));
    } catch (error) {
      read.errors.push(`${name}: ${error.message}`);
    }
  }
  read.hooks.sort((a, b) => Number(a.at) - Number(b.at));
  return read;
}

function message(text) {
  return { type: 'message', text };
}

function call(name, args, namespace, callId) {
  return { type: 'function_call', name, arguments: args, namespace, callId };
}

function codeExec(source, callId) {
  return { type: 'custom_tool_call', name: 'exec', input: source, namespace: 'functions', callId };
}

function offeredShell(body) {
  for (const name of ['exec_command', 'shell_command', 'shell']) {
    const tool = analyze.findTool(body, name);
    if (tool) return tool;
  }
  throw new Error(`no shell tool is offered: ${analyze.toolsOfBody(body).join(', ')}`);
}

function shellStep(cmd, callId) {
  return (body) => {
    const tool = offeredShell(body);
    const properties = (tool.parameters && tool.parameters.properties) || {};
    let args = { command: cmd };
    if (properties.cmd) args = { cmd };
    else if (properties.command && properties.command.type === 'array') args = { command: ['bash', '-lc', cmd] };
    return [call(tool.name, args, undefined, callId)];
  };
}

function guardedCode(expression) {
  return `let r;\ntry {\n  r = await ${expression};\n} catch (error) {\n  r = String(error);\n}\ntext(JSON.stringify(r));`;
}

function threadOf(body) {
  const meta = (body && body.client_metadata) || {};
  return { id: meta.thread_id || (body && body.prompt_cache_key) || 'main', sub: contract.isSubagentBody(body), parent: meta['x-codex-parent-thread-id'] || null };
}

function makeResponder(script) {
  const counters = new Map();
  let root = null;
  return (body) => {
    const { id, sub, parent } = threadOf(body);
    if (!sub && root === null) root = id;
    let role = 'main';
    if (sub) role = script.grand && root !== null && parent !== null && parent !== root ? 'grand' : 'sub';
    const key = role === 'main' ? 'main' : `${role}:${id}`;
    const index = counters.get(key) || 0;
    counters.set(key, index + 1);
    const steps = script[role] || [];
    const step = steps[index];
    if (!step) return [message(sub ? 'probe subagent: done.' : 'probe main: done.')];
    return typeof step === 'function' ? step(body, { index, sub }) : step;
  };
}

function parsedJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function sessionIdFrom(text) {
  const parsed = parsedJson(text);
  if (parsed && Number.isInteger(parsed.session_id)) return parsed.session_id;
  const json = /"session_id"\s*:\s*(\d+)\b/.exec(text);
  if (json) return Number(json[1]);
  const prose = /\bsession[ _-]?id\b\D{0,12}?(\d+)\b/i.exec(text);
  if (prose) return Number(prose[1]);
  throw new Error(`no exec session id in the tool output: ${String(text).slice(0, 120)}`);
}

function noticesOf(client) {
  return client ? client.notifications.filter((n) => NOTICE_METHODS.includes(n.method)).map((n) => ({ method: n.method, params: n.params })) : [];
}

function hookNotificationsOf(client) {
  return client
    ? client.notifications
      .filter((n) => /^hook\//.test(n.method) && n.params && n.params.run)
      .map((n) => ({ method: n.method, eventName: n.params.run.eventName, status: n.params.run.status, source: n.params.run.source }))
    : [];
}

function itemTypes(notifications) {
  return notifications
    .filter((n) => n.method === 'item/completed' && n.params && n.params.item)
    .map((n) => n.params.item.type);
}

function stdinStep(body) {
  const sid = sessionIdFrom(analyze.outputOfCall(body, CALLS.stdinStart) || '');
  return [call('write_stdin', { session_id: sid, chars: `${MARKERS.stdin}\n`, yield_time_ms: 2000 }, undefined, CALLS.stdinWrite)];
}

const CODE_STDIN = `const a = await tools.exec_command({ cmd: ${JSON.stringify(STDIN_CMD)}, tty: true, yield_time_ms: 500 });
const b = await tools.write_stdin({ session_id: a.session_id, chars: ${JSON.stringify(`${MARKERS.stdin}\n`)}, yield_time_ms: 2000 });
text(JSON.stringify({ a, b }));`;
const CODE_PATCH = `const r = await tools.apply_patch(${JSON.stringify(PATCH)});
text(JSON.stringify(r));`;
const CODE_SUB_TOOLS = `const shell = await tools.exec_command({ cmd: ${JSON.stringify(SUB_CMD)}, yield_time_ms: 3000 });
let patch;
try {
  patch = await tools.apply_patch(${JSON.stringify(SUB_PATCH)});
} catch (error) {
  patch = String(error);
}
text(JSON.stringify({ shell: shell.output, patch }));`;
const RUI_ARGS = {
  questions: [{
    id: 'probe_choice',
    header: 'Probe',
    question: 'Which probe answer?',
    options: [
      { label: 'Alpha (Recommended)', description: 'First probe option.' },
      { label: 'Beta', description: 'Second probe option.' },
    ],
  }],
};
const SHIPPED_REVIEWER_ROLE = path.join(HERE, '..', '..', 'plugins', 'zensu', 'agents', 'zensu-code-reviewer.toml');

function reviewerProfileRole({ dropTables = [] } = {}) {
  const shipped = fs.readFileSync(SHIPPED_REVIEWER_ROLE, 'utf8');
  const named = shipped.replace(/^name = ".*"$/m, `name = ${tomlString(TOOLS_ROLE.name)}`);
  const instructed = named.replace(/^developer_instructions = '''\n[\s\S]*?\n'''$/m, `developer_instructions = ${tomlString(TOOLS_ROLE.marker)}`);
  if (named === shipped || instructed === named) throw new Error('the shipped reviewer role no longer has the name and developer_instructions shape the probe rewrites');
  return dropTables.reduce((text, table) => withoutTable(text, table), instructed);
}

function agentIdFrom(text) {
  const parsed = parsedJson(text);
  const direct = parsed && typeof parsed === 'object' ? parsed.agent_id || parsed.id : null;
  if (typeof direct === 'string' && direct) return direct;
  const match = /"(?:agent_id|id|target)"\s*:\s*"([^"]+)"/.exec(text);
  if (match) return match[1];
  throw new Error(`no agent id in the spawn output: ${String(text).slice(0, 120)}`);
}

const SUB_STEPS = [[message('probe subagent turn 1.')], [message('probe subagent turn 2.')], [message('probe subagent turn 3.')], [message('probe subagent turn 4.')]];
const PROFILE_PATCH = `*** Begin Patch\n*** Add File: ${FILES.profilePatch}\n+PROBE_PROFILE_PATCH\n*** End Patch\n`;
const CODE_PROFILE_TOOLS = `const out = {};
try {
  out.patch = await tools.apply_patch(${JSON.stringify(PROFILE_PATCH)});
} catch (error) {
  out.patch = String(error);
}
try {
  out.shell = await tools.exec_command({ cmd: ${JSON.stringify(`touch ${FILES.profileShell}`)}, yield_time_ms: 3000 });
} catch (error) {
  out.shell = String(error);
}
text(JSON.stringify(out));`;
const PROFILE_SUB = [
  [codeExec(CODE_PROFILE_TOOLS, CALLS.profileTools)],
  [call('spawn_agent', { task_name: 'probe_grandchild', message: 'probe grandchild: write and finish.', fork_turns: 'none' }, 'collaboration', CALLS.profileSpawn)],
  [call('wait_agent', { timeout_ms: 10000 }, 'collaboration')],
  [message('probe subagent: done.')],
  [message('probe subagent: done again.')],
];
const GRAND_PATCH = `*** Begin Patch\n*** Add File: ${FILES.grandWrite}\n+PROBE_GRAND_WRITE\n*** End Patch\n`;
const PROFILE_GRAND = [
  [codeExec(guardedCode(`tools.apply_patch(${JSON.stringify(GRAND_PATCH)})`))],
  [message('probe grandchild: done.')],
  [message('probe grandchild: done again.')],
];

function subToolSteps(surface) {
  const step = surface === 'code'
    ? [codeExec(CODE_SUB_TOOLS, CALLS.subTool)]
    : [call('exec_command', { cmd: SUB_CMD, yield_time_ms: 3000 }, undefined, CALLS.subTool)];
  return [step, [message('probe subagent: done.')], [message('probe subagent: done again.')]];
}

function roleToml(name, marker) {
  return `name = ${tomlString(name)}\ndescription = ${tomlString(`Probe role ${name}.`)}\nsandbox_mode = "read-only"\ndeveloper_instructions = ${tomlString(marker)}\n`;
}

function writeFile(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}

function homeRole(ctx, name, content) {
  writeFile(path.join(ctx.sandbox.codexHome, 'agents', `${name}.toml`), content);
}

function discoverySetup(ctx, project) {
  homeRole(ctx, 'home-role', roleToml('home-role', ROLES['home-role']));
  homeRole(ctx, TWIN_ROLE.name, roleToml(TWIN_ROLE.name, TWIN_ROLE.home));
  writeFile(path.join(project, '.codex', 'agents', 'project-role.toml'), roleToml('project-role', ROLES['project-role']));
  writeFile(path.join(project, '.codex', 'agents', `${TWIN_ROLE.name}.toml`), roleToml(TWIN_ROLE.name, TWIN_ROLE.project));
  writeFile(path.join(ctx.sandbox.root, 'roles', 'config-role.toml'), `developer_instructions = ${tomlString(ROLES['config-role'])}\n`);
}

function sandboxRoleSetup(ctx) {
  homeRole(ctx, 'home-role', roleToml('home-role', ROLES['home-role']));
}

function toolsRoleSetup(ctx) {
  homeRole(ctx, TOOLS_ROLE.name, reviewerProfileRole());
}

function delegateRoleSetup(ctx) {
  homeRole(ctx, TOOLS_ROLE.name, reviewerProfileRole({ dropTables: ['agents'] }));
}

function roleTeardown(ctx) {
  fs.rmSync(path.join(ctx.sandbox.codexHome, 'agents'), { recursive: true, force: true });
}

function roleConfig(ctx) {
  return [
    'agents.config-role.description="Probe role config-role."',
    `agents.config-role.config_file=${tomlString(path.join(ctx.sandbox.root, 'roles', 'config-role.toml'))}`,
  ];
}

function spawnCallFor(surface, role) {
  const agentType = role ? { agent_type: role } : {};
  return surface === 'code'
    ? call('spawn_agent', { task_name: 'probe_task', message: TUI_STRINGS.approvalPrompt, fork_turns: 'none', ...agentType }, 'collaboration', CALLS.spawn)
    : call('spawn_agent', { message: TUI_STRINGS.approvalPrompt, ...agentType }, 'multi_agent_v1', CALLS.spawn);
}

function waitStepFor(surface, timeoutMs, callId) {
  return surface === 'code'
    ? [call('wait_agent', { timeout_ms: timeoutMs }, 'collaboration', callId)]
    : (body) => [call('wait_agent', { targets: [agentIdFrom(analyze.outputOfCall(body, CALLS.spawn) || '')], timeout_ms: timeoutMs }, 'multi_agent_v1', callId)];
}

function spawnScenario(name, surface, { role, sub, grand, mode, setup, config, waitMs = 30000, expectSubagent = true } = {}) {
  return {
    name,
    group: 'spawn',
    surface,
    mode,
    config,
    expectSubagent,
    setup,
    teardown: setup ? roleTeardown : undefined,
    script: { main: [[spawnCallFor(surface, role)], waitStepFor(surface, waitMs, CALLS.wait), [message('probe main: done.')]], sub: sub || subToolSteps(surface), grand },
  };
}

function holdScenario(name, surface) {
  const sleep = surface === 'code'
    ? [codeExec(`const r = await tools.exec_command({ cmd: "sleep 12", yield_time_ms: 20000 });\ntext(r.output);`)]
    : [call('exec_command', { cmd: 'sleep 12', yield_time_ms: 20000 })];
  return {
    name,
    group: 'spawn',
    surface,
    expectSubagent: true,
    mode: { subagentStop: { shape: 'decision-block', marker: MARKERS.subagentStop, times: 1 } },
    script: {
      main: [[spawnCallFor(surface)], waitStepFor(surface, 10000, CALLS.waitFirst), waitStepFor(surface, 60000, CALLS.waitSecond), [message('probe main: done.')]],
      sub: [[message(`probe subagent ${MARKERS.subagentPreHold}.`)], sleep, [message(`probe subagent ${MARKERS.subagentFinal}.`)], [message('probe subagent: done again.')]],
    },
  };
}

function roleSpawnScenario(name, surface, roles, extra = {}) {
  const spawnCall = (role) => (surface === 'code'
    ? call('spawn_agent', { task_name: role.replace(/-/g, '_'), message: `probe role ${role}: reply and finish.`, fork_turns: 'none', agent_type: role }, 'collaboration')
    : call('spawn_agent', { message: `probe role ${role}: reply and finish.`, agent_type: role }, 'multi_agent_v1'));
  return {
    name,
    group: 'roles',
    surface,
    expectSubagent: true,
    setup: discoverySetup,
    teardown: roleTeardown,
    config: roleConfig,
    script: { main: [...roles.map((role) => [spawnCall(role)]), [message('probe main: done.')]], sub: SUB_STEPS },
    ...extra,
  };
}

function denyScenario(name, surface, tool, via, step) {
  return { name, group: 'deny', surface, mode: { deny: { tool, via, marker: MARKERS.deny } }, script: { main: [step, [message('probe main: done.')]] } };
}

function spawnDenyScenario(name, surface) {
  const spawnCall = surface === 'code'
    ? call('spawn_agent', { task_name: 'probe_denied', message: 'probe denied spawn.', fork_turns: 'none' }, 'collaboration', CALLS.deny)
    : call('spawn_agent', { message: 'probe denied spawn.' }, 'multi_agent_v1', CALLS.deny);
  const tool = surface === 'code' ? 'collaborationspawn_agent' : 'spawn_agent';
  return { name, group: 'deny', surface, mode: { deny: { tool, via: 'json', marker: MARKERS.deny } }, script: { main: [[spawnCall], [message('probe main: done.')]] } };
}

function subagentDenyScenario(name, surface, tool, via, step) {
  return {
    ...spawnScenario(name, surface, {
      sub: [step, [message('probe subagent: done.')], [message('probe subagent: done again.')]],
      mode: { deny: { tool, via, marker: MARKERS.deny, scope: 'subagent' } },
    }),
    group: 'deny',
  };
}

function stopScenario(shape, surface) {
  const prefix = { classic: 'stop-', code: 'stop-code-', gpt55: 'stop-gpt55-' }[surface];
  return {
    name: `${prefix}${shape}`,
    group: 'stop',
    surface,
    mode: { stop: { shape, marker: MARKERS.stop } },
    script: { main: [[message('probe stop turn 1.')], [message('probe stop turn 2.')], [message('probe stop turn 3.')], [message('probe stop turn 4.')]] },
  };
}

const CLASSIC_DENY = [call('exec_command', { cmd: `touch ${FILES.denied}` }, undefined, CALLS.deny)];
const CODE_DENY = [codeExec(`const r = await tools.exec_command({ cmd: ${JSON.stringify(`touch ${FILES.denied}`)} });\ntext(JSON.stringify(r));`, CALLS.deny)];
const CODE_PATCH_DENY = [codeExec(CODE_PATCH, CALLS.deny)];
const GPT55_PATCH = { type: 'custom_tool_call', name: 'apply_patch', input: PATCH };
const SUB_DENIED_PATCH = `*** Begin Patch\n*** Add File: ${FILES.subDeniedPatch}\n+PROBE_SUB_DENIED_PATCH\n*** End Patch\n`;
const SUB_CLASSIC_DENY = [call('exec_command', { cmd: `touch ${FILES.subDenied}` }, undefined, CALLS.subDeny)];
const SUB_CODE_DENY = [codeExec(guardedCode(`tools.exec_command({ cmd: ${JSON.stringify(`touch ${FILES.subDenied}`)} })`), CALLS.subDeny)];
const SUB_CODE_PATCH_DENY = [codeExec(guardedCode(`tools.apply_patch(${JSON.stringify(SUB_DENIED_PATCH)})`), CALLS.subDeny)];
const SUB_CODE_SPAWN_DENY = [call('spawn_agent', { task_name: 'probe_denied_grandchild', message: 'probe denied grandchild.', fork_turns: 'none' }, 'collaboration', CALLS.subDeny)];
const DISCOVERY_ROLES = [...Object.keys(ROLES), TWIN_ROLE.name];
const WORKSPACE_PARENT = ['sandbox_mode="workspace-write"'];

const SCENARIOS = [
  {
    name: 'classic-baseline',
    group: 'exec',
    surface: 'classic',
    mode: { context: CONTEXT },
    script: { main: [[call('exec_command', { cmd: ENV_CMD, yield_time_ms: 3000 }, undefined, CALLS.env)], [message('probe main: done.')]] },
  },
  {
    name: 'code-baseline',
    group: 'exec',
    surface: 'code',
    mode: { context: CONTEXT },
    script: { main: [[codeExec(`const r = await tools.exec_command({ cmd: ${JSON.stringify(ENV_CMD)}, yield_time_ms: 3000 });\ntext(r.output);`, CALLS.env)], [message('probe main: done.')]] },
  },
  {
    name: 'gpt55-baseline',
    group: 'exec',
    surface: 'gpt55',
    mode: { context: CONTEXT },
    script: { main: [shellStep(ENV_CMD, CALLS.env), [message('probe main: done.')]] },
  },
  {
    name: 'classic-stdin',
    group: 'exec',
    surface: 'classic',
    script: { main: [[call('exec_command', { cmd: STDIN_CMD, tty: true, yield_time_ms: 500 }, undefined, CALLS.stdinStart)], stdinStep, [message('probe main: done.')]] },
  },
  {
    name: 'code-stdin',
    group: 'exec',
    surface: 'code',
    script: { main: [[codeExec(CODE_STDIN, CALLS.stdinStart)], [message('probe main: done.')]] },
  },
  {
    name: 'code-patch',
    group: 'exec',
    surface: 'code',
    script: { main: [[codeExec(CODE_PATCH)], [message('probe main: done.')]] },
  },
  {
    name: 'code-patch-multi',
    group: 'exec',
    surface: 'code',
    script: { main: [[codeExec(`const r = await tools.apply_patch(${JSON.stringify(MULTI_PATCH)});\ntext(JSON.stringify(r));`)], [message('probe main: done.')]] },
  },
  {
    name: 'gpt55-patch',
    group: 'exec',
    surface: 'gpt55',
    script: { main: [[GPT55_PATCH], [message('probe main: done.')]] },
  },
  {
    name: 'classic-rui',
    group: 'exec',
    surface: 'classic',
    script: { main: [[call('request_user_input', RUI_ARGS, undefined, CALLS.rui)], [message('probe main: done.')]] },
  },
  {
    name: 'code-rui',
    group: 'exec',
    surface: 'code',
    script: { main: [[call('request_user_input', RUI_ARGS, 'functions', CALLS.rui)], [message('probe main: done.')]] },
  },
  denyScenario('deny-classic-bash-json', 'classic', 'Bash', 'json', CLASSIC_DENY),
  denyScenario('deny-classic-bash-exit2', 'classic', 'Bash', 'exit2', CLASSIC_DENY),
  denyScenario('deny-code-bash-json', 'code', 'Bash', 'json', CODE_DENY),
  denyScenario('deny-code-bash-exit2', 'code', 'Bash', 'exit2', CODE_DENY),
  denyScenario('deny-code-patch-json', 'code', 'apply_patch', 'json', CODE_PATCH_DENY),
  denyScenario('deny-code-patch-exit2', 'code', 'apply_patch', 'exit2', CODE_PATCH_DENY),
  denyScenario('deny-code-patch-edit-json', 'code', ['Edit', 'Write', 'MultiEdit'], 'json', CODE_PATCH_DENY),
  denyScenario('deny-gpt55-bash-json', 'gpt55', 'Bash', 'json', shellStep(`touch ${FILES.denied}`, CALLS.deny)),
  denyScenario('deny-gpt55-patch-json', 'gpt55', 'apply_patch', 'json', [{ ...GPT55_PATCH, callId: CALLS.deny }]),
  subagentDenyScenario('deny-sub-classic-bash-json', 'classic', 'Bash', 'json', SUB_CLASSIC_DENY),
  subagentDenyScenario('deny-sub-classic-bash-exit2', 'classic', 'Bash', 'exit2', SUB_CLASSIC_DENY),
  subagentDenyScenario('deny-sub-code-bash-json', 'code', 'Bash', 'json', SUB_CODE_DENY),
  subagentDenyScenario('deny-sub-code-bash-exit2', 'code', 'Bash', 'exit2', SUB_CODE_DENY),
  subagentDenyScenario('deny-sub-code-patch-json', 'code', 'apply_patch', 'json', SUB_CODE_PATCH_DENY),
  subagentDenyScenario('deny-sub-code-patch-exit2', 'code', 'apply_patch', 'exit2', SUB_CODE_PATCH_DENY),
  subagentDenyScenario('deny-sub-code-spawn-json', 'code', 'collaborationspawn_agent', 'json', SUB_CODE_SPAWN_DENY),
  spawnDenyScenario('deny-classic-spawn-json', 'classic'),
  spawnDenyScenario('deny-code-spawn-json', 'code'),
  spawnScenario('spawn-classic', 'classic'),
  spawnScenario('spawn-code', 'code'),
  spawnScenario('spawn-classic-subagent-stop-block', 'classic', { sub: SUB_STEPS, mode: { subagentStop: { shape: 'decision-block', marker: MARKERS.subagentStop } } }),
  spawnScenario('spawn-code-subagent-stop-block', 'code', { sub: SUB_STEPS, mode: { subagentStop: { shape: 'decision-block', marker: MARKERS.subagentStop } } }),
  holdScenario('spawn-classic-subagent-stop-hold', 'classic'),
  holdScenario('spawn-code-subagent-stop-hold', 'code'),
  spawnScenario('role-sandbox-classic', 'classic', { role: 'home-role', setup: sandboxRoleSetup }),
  spawnScenario('role-sandbox-code', 'code', { role: 'home-role', setup: sandboxRoleSetup }),
  {
    name: 'sandbox-readonly-parent',
    group: 'spawn',
    surface: 'code',
    config: ['sandbox_mode="read-only"'],
    script: { main: [[codeExec(`const r = await tools.exec_command({ cmd: ${JSON.stringify(`touch ${FILES.parentWrite}`)}, yield_time_ms: 3000 });\ntext(r.output);`, CALLS.parentWrite)], [message('probe main: done.')]] },
  },
  spawnScenario('spawn-code-workspace', 'code', { config: WORKSPACE_PARENT }),
  spawnScenario('role-sandbox-code-workspace', 'code', { role: 'home-role', setup: sandboxRoleSetup, config: WORKSPACE_PARENT }),
  {
    name: 'subagent-message-root',
    group: 'spawn',
    surface: 'code',
    expectSubagent: true,
    script: {
      main: [
        [call('spawn_agent', { task_name: 'probe_task', message: PROMPTS.messageRoot, fork_turns: 'none' }, 'collaboration', CALLS.spawn)],
        [call('wait_agent', { timeout_ms: 30000 }, 'collaboration')],
        [call('wait_agent', { timeout_ms: 10000 }, 'collaboration')],
        [message('probe main: done.')],
      ],
      sub: [
        [call('send_message', { target: '/root', message: TUI_STRINGS.approvalPrompt }, 'collaboration', CALLS.rootMessage)],
        [call('send_message', { target: '..', message: TUI_STRINGS.approvalPrompt }, 'collaboration', CALLS.rootMessageRelative)],
        [call('followup_task', { target: '/root', message: TUI_STRINGS.approvalPrompt }, 'collaboration', CALLS.rootFollowup)],
        [message('probe subagent: done.')],
        [message('probe subagent: done again.')],
      ],
    },
  },
  spawnScenario('role-tools-code', 'code', { role: TOOLS_ROLE.name, setup: toolsRoleSetup, sub: PROFILE_SUB, grand: PROFILE_GRAND, waitMs: 60000 }),
  spawnScenario('role-delegate-code', 'code', { role: TOOLS_ROLE.name, setup: delegateRoleSetup, sub: PROFILE_SUB, grand: PROFILE_GRAND, waitMs: 60000 }),
  roleSpawnScenario('roles-code', 'code', DISCOVERY_ROLES),
  roleSpawnScenario('roles-classic', 'classic', DISCOVERY_ROLES),
  roleSpawnScenario('roles-untrusted-project', 'code', ['project-role', TWIN_ROLE.name], { untrusted: true, config: undefined }),
  {
    name: 'permission-request',
    group: 'exec',
    surface: 'classic',
    config: ['approval_policy="on-request"', 'sandbox_mode="workspace-write"'],
    script: {
      main: [
        [call('exec_command', { cmd: 'touch escalated.txt', sandbox_permissions: 'require_escalated', justification: 'Probe escalation request.' }, undefined, CALLS.escalate)],
        [message('probe main: done.')],
      ],
    },
  },
  {
    name: 'compact-auto',
    group: 'exec',
    surface: 'classic',
    config: ['model_auto_compact_token_limit=1'],
    script: { main: [[call('exec_command', { cmd: 'echo PROBE_BEFORE_COMPACT' })], [message('probe summary.')], [message('probe main: done.')], [message('probe main: done again.')]] },
  },
  {
    name: 'exec-untrusted',
    group: 'trust',
    surface: 'classic',
    bypassTrust: false,
    needsUntrustedHooks: true,
    expectHooks: false,
    expectModel: false,
    script: { main: [[call('exec_command', { cmd: `echo ${MARKERS.trustedTool}` })], [message('probe main: done.')]] },
  },
  {
    name: 'exec-default-features',
    group: 'trust',
    surface: 'classic',
    expectHooks: false,
    notes: ['config.toml without the [features] table'],
    setup: dropFeatures,
    teardown: restoreConfig,
    script: { main: [[message('probe main: done.')]] },
  },
  {
    name: 'exec-cwd-outside',
    group: 'exec',
    surface: 'classic',
    startIn: 'sandbox',
    notes: ['codex exec started from the sandbox root with -C <project>'],
    script: { main: [[message('probe main: done.')]] },
  },
  stopScenario('decision-block', 'classic'),
  stopScenario('exit2', 'classic'),
  stopScenario('continue-false', 'classic'),
  stopScenario('system-message', 'classic'),
  stopScenario('decision-block', 'code'),
  stopScenario('exit2', 'code'),
  stopScenario('continue-false', 'code'),
  stopScenario('system-message', 'code'),
  stopScenario('decision-block', 'gpt55'),
  {
    name: 'app-lists',
    group: 'app',
    expectModel: false,
    drive: async (client, { project }) => {
      const skills = await client.request('skills/list', { cwds: [project], forceReload: true });
      const hooks = await client.request('hooks/list', { cwds: [project] });
      const plugins = await client.request('plugin/installed', { cwds: [project] });
      let modes = null;
      try {
        modes = await client.request('collaborationMode/list', {});
      } catch (error) {
        modes = { error: error.message };
      }
      return { skills, hooks, plugins, modes };
    },
  },
  {
    name: 'app-untrusted-turn',
    group: 'app',
    needsUntrustedHooks: true,
    mode: { context: CONTEXT },
    script: { main: [[message('probe main: done.')]] },
    drive: async (client, { ctx, project }) => {
      const threadId = await startThread(client, project, MODELS.classic);
      await runTurn(client, ctx, { threadId, text: 'probe untrusted turn' });
      const hooks = await client.request('hooks/list', { cwds: [project] });
      return { hooks };
    },
  },
  {
    name: 'app-rui',
    group: 'app',
    notes: ['second thread on the code-mode model'],
    script: {
      main: [
        [call('request_user_input', RUI_ARGS, undefined, CALLS.ruiDefault)],
        [message('probe default done.')],
        [call('request_user_input', RUI_ARGS, undefined, CALLS.ruiPlan)],
        [message('probe plan done.')],
        [call('request_user_input', RUI_ARGS, 'functions', CALLS.ruiCodeDefault)],
        [message('probe code default done.')],
        [call('request_user_input', RUI_ARGS, 'functions', CALLS.ruiCodePlan)],
        [message('probe code plan done.')],
      ],
    },
    drive: async (client, { ctx, project }) => {
      const classic = await startThread(client, project, MODELS.classic);
      await runTurn(client, ctx, { threadId: classic, text: PROMPTS.ruiDefault, mode: 'default', model: MODELS.classic });
      await runTurn(client, ctx, { threadId: classic, text: PROMPTS.ruiPlan, mode: 'plan', model: MODELS.classic });
      const code = await startThread(client, project, MODELS.code);
      await runTurn(client, ctx, { threadId: code, text: PROMPTS.ruiCodeDefault, mode: 'default', model: MODELS.code });
      await runTurn(client, ctx, { threadId: code, text: PROMPTS.ruiCodePlan, mode: 'plan', model: MODELS.code });
      return { threads: { classic, code } };
    },
  },
  {
    name: 'app-trust',
    group: 'app',
    grantsHookTrust: true,
    expectHooks: true,
    notes: [`second Plan-mode turn on a thread with approvalPolicy=${PERMISSION_THREAD.approvalPolicy} and sandbox=${PERMISSION_THREAD.sandbox}`],
    mode: { context: CONTEXT },
    script: {
      main: [
        [call('exec_command', { cmd: `echo ${MARKERS.trustedTool}` })],
        [message('probe trusted turn done.')],
        [call('exec_command', { cmd: `echo ${MARKERS.planTool}` }, undefined, CALLS.planTool)],
        [message(PROPOSED_PLAN)],
        [message('probe implementation done.')],
        [call('exec_command', { cmd: `echo ${MARKERS.planTool}` }, undefined, CALLS.planToolOnRequest)],
        [message(PROPOSED_PLAN)],
        [message('probe semantic edit turn done.')],
      ],
    },
    drive: async (client, { ctx, project, dir }) => {
      const env = { ...ctx.env, PROBE_DIR: dir, PROBE_MODE: JSON.stringify({ context: CONTEXT }) };
      const before = await client.request('hooks/list', { cwds: [project] });
      const write = await client.request('config/batchWrite', { edits: trustEdits(trustSummary(before)), reloadUserConfig: true });
      const after = await client.request('hooks/list', { cwds: [project] });
      const threadId = await startThread(client, project, MODELS.classic);
      await runTurn(client, ctx, { threadId, text: PROMPTS.trustedTurn });
      const planTurn = await runTurn(client, ctx, { threadId, text: PROMPTS.makePlan, mode: 'plan', model: MODELS.classic });
      const approval = await runTurn(client, ctx, { threadId, text: TUI_STRINGS.approvalPrompt, mode: 'default', model: MODELS.classic });
      const onRequestThread = await startThread(client, project, MODELS.classic, PERMISSION_THREAD);
      await runTurn(client, ctx, { threadId: onRequestThread, text: PROMPTS.makePlanOnRequest, mode: 'plan', model: MODELS.classic });
      const configText = fs.readFileSync(configFile(ctx), 'utf8');
      await bumpFixture(ctx, '0.0.2');
      const afterVersionBump = await listHooksFresh(ctx, env, project);
      await bumpFixture(ctx, '0.0.3', (root) => fs.appendFileSync(path.join(root, 'hooks', 'record.js'), '\n'));
      const afterScriptEdit = await listHooksFresh(ctx, env, project);
      await bumpFixture(ctx, '0.0.4', (root) => editHooks(root, (hooks) => {
        hooks.Stop[0].hooks[0].command = `${hooks.Stop[0].hooks[0].command} edited`;
      }));
      const afterCommandEdit = await listHooksFresh(ctx, env, project);
      await restoreFixture(ctx, '0.0.5', (root) => editHooks(root, (hooks) => {
        hooks.PreToolUse.unshift({ hooks: [{ type: 'command', command: 'node "${CLAUDE_PLUGIN_ROOT}/hooks/record.js" PreToolUse inserted' }] });
      }));
      const afterGroupInsert = await listHooksFresh(ctx, env, project);
      await restoreFixture(ctx, '0.0.6');
      const afterRestore = await listHooksFresh(ctx, env, project);
      await bumpFixture(ctx, '0.0.7', semanticScriptEdit);
      const afterSemanticEdit = await listHooksFresh(ctx, env, project);
      await withAppServer(ctx, { env }, async (fresh) => {
        const freshThread = await startThread(fresh, project, MODELS.classic);
        await runTurn(fresh, ctx, { threadId: freshThread, text: PROMPTS.semanticEditTurn });
      });
      const semanticEditRan = fs.existsSync(path.join(dir, FILES.semanticEdit));
      await bumpFixture(ctx, '0.0.8', (root) => editHooks(root, (hooks) => {
        hooks.PreToolUse.push({ hooks: [{ type: 'command', command: 'node "${CLAUDE_PLUGIN_ROOT}/hooks/record.js" PreToolUse appended' }] });
      }));
      const afterGroupAppend = await listHooksFresh(ctx, env, project);
      await restoreFixture(ctx, '0.0.9');
      return {
        trusted: allTrusted(trustSummary(after)),
        before: trustSummary(before),
        write,
        after: trustSummary(after),
        trustConfigLines: configText.split('\n').filter((line) => /hooks\.state|trusted_hash/.test(line)).slice(0, 6),
        planItems: itemTypes(planTurn.notifications),
        planItemDetails: planTurn.notifications.filter((n) => n.method === 'item/completed').map((n) => n.params.item),
        planMethods: [...new Set(planTurn.notifications.map((n) => n.method))].sort(),
        approvalItems: itemTypes(approval.notifications),
        afterVersionBump: trustSummary(afterVersionBump),
        afterScriptEdit: trustSummary(afterScriptEdit),
        afterCommandEdit: trustSummary(afterCommandEdit),
        afterGroupInsert: trustSummary(afterGroupInsert),
        afterRestore: trustSummary(afterRestore),
        afterSemanticEdit: trustSummary(afterSemanticEdit),
        semanticEditRan,
        afterGroupAppend: trustSummary(afterGroupAppend),
      };
    },
  },
  {
    name: 'app-interrupt-compact',
    group: 'app',
    grantsHookTrust: true,
    expectHooks: true,
    script: { main: [[call('exec_command', { cmd: 'sleep 20', yield_time_ms: 30000 })], [message('probe interrupted turn.')], [message('probe compact summary.')], [message('probe main: done.')]] },
    drive: async (client, { ctx, project }) => {
      const trusted = await trustAll(client, project);
      const threadId = await startThread(client, project, MODELS.classic);
      const before = client.notifications.length;
      const started = await client.request('turn/start', { threadId, input: [{ type: 'text', text: 'probe interrupt me', text_elements: [] }] });
      const turnId = started.turn.id;
      await client.waitFor('command started', () => client.notifications.slice(before).find((n) => n.method === 'item/started' && n.params && n.params.item && n.params.item.type === 'commandExecution'), 60000);
      await client.request('turn/interrupt', { threadId, turnId });
      await client.waitFor('interrupted turn completed', () => client.notifications.slice(before).find((n) => n.method === 'turn/completed'), 60000);
      const compactBefore = client.notifications.length;
      await client.request('thread/compact/start', { threadId });
      await client.waitFor('compaction', () => client.notifications.slice(compactBefore).find((n) => n.method === 'thread/compacted' || n.method === 'turn/completed'), 60000);
      await runTurn(client, ctx, { threadId, text: 'probe after compaction' });
      return {
        trusted: allTrusted(trusted),
        interruptStatus: (client.notifications.slice(before).find((n) => n.method === 'turn/completed') || {}).params,
        compactMethods: [...new Set(client.notifications.slice(compactBefore).map((n) => n.method))].sort(),
      };
    },
  },
  {
    name: 'app-permission',
    group: 'app',
    grantsHookTrust: true,
    expectHooks: true,
    notes: [`thread approvalPolicy=${PERMISSION_THREAD.approvalPolicy}`, `thread sandbox=${PERMISSION_THREAD.sandbox}`],
    script: {
      main: [
        [call('exec_command', { cmd: 'touch escalated.txt', sandbox_permissions: 'require_escalated', justification: 'Probe escalation request.' }, undefined, CALLS.escalate)],
        [message('probe main: done.')],
      ],
    },
    drive: async (client, { ctx, project }) => {
      const trusted = await trustAll(client, project);
      const threadId = await startThread(client, project, MODELS.classic, PERMISSION_THREAD);
      await runTurn(client, ctx, { threadId, text: 'probe escalate' });
      return { trusted: allTrusted(trusted) };
    },
  },
  {
    name: 'app-gates',
    group: 'app',
    grantsHookTrust: true,
    expectHooks: true,
    notes: ['hooks trusted through config/batchWrite, no trust bypass'],
    mode: { deny: { tool: 'Bash', via: 'json', marker: MARKERS.deny }, stop: { shape: 'decision-block', marker: MARKERS.stop } },
    script: { main: [[call('exec_command', { cmd: `touch ${FILES.denied}` }, undefined, CALLS.deny)], [message('probe gate turn 1.')], [message('probe gate turn 2.')], [message('probe gate turn 3.')]] },
    drive: async (client, { ctx, project }) => {
      const trusted = await trustAll(client, project);
      const threadId = await startThread(client, project, MODELS.classic);
      await runTurn(client, ctx, { threadId, text: 'probe trusted gates' });
      return { trusted: allTrusted(trusted) };
    },
  },
  {
    name: 'exec-trusted',
    group: 'trust',
    surface: 'classic',
    bypassTrust: false,
    grantsHookTrust: true,
    expectHooks: false,
    late: true,
    setup: grantTrust,
    script: { main: [[call('exec_command', { cmd: `echo ${MARKERS.trustedTool}` })], [message('probe main: done.')]] },
  },
  {
    ...denyScenario('deny-classic-bash-json-trusted', 'classic', 'Bash', 'json', CLASSIC_DENY),
    bypassTrust: false,
    grantsHookTrust: true,
    expectHooks: false,
    late: true,
    setup: grantTrust,
  },
  {
    ...stopScenario('decision-block', 'classic'),
    name: 'stop-decision-block-trusted',
    bypassTrust: false,
    grantsHookTrust: true,
    expectHooks: false,
    late: true,
    setup: grantTrust,
  },
];

function overridesOf(ctx, scenario) {
  return typeof scenario.config === 'function' ? scenario.config(ctx) : scenario.config || [];
}

function expectOf(scenario) {
  return {
    hooks: scenario.expectHooks === undefined ? scenario.group !== 'app' : scenario.expectHooks,
    model: scenario.expectModel !== false,
    subagent: Boolean(scenario.expectSubagent),
    exit: scenario.expectExit === undefined ? 0 : scenario.expectExit,
  };
}

async function runExecScenario(ctx, scenario) {
  const dir = path.join(ctx.sandbox.out, scenario.name);
  const project = path.join(ctx.sandbox.projects, scenario.name);
  fs.mkdirSync(dir, { recursive: true });
  const requests = [];
  const mockErrors = [];
  ctx.route = {
    respond: makeResponder(scenario.script),
    onRequest: (request) => {
      if (request.served) requests.push(request.body);
    },
    onError: (error) => mockErrors.push(error),
  };
  const env = { ...ctx.env, PROBE_DIR: dir, PROBE_MODE: JSON.stringify(scenario.mode || {}) };
  const args = ['exec', '--json', '--skip-git-repo-check'];
  if (scenario.bypassTrust !== false) args.push('--dangerously-bypass-hook-trust');
  args.push('-C', project, '-c', `model=${tomlString(MODELS[scenario.surface])}`);
  for (const override of overridesOf(ctx, scenario)) args.push('-c', override);
  args.push(`probe scenario ${scenario.name}`);
  let setupError = null;
  let proc = null;
  try {
    if (scenario.setup) await scenario.setup(ctx, project);
    proc = await runProcess(ctx.codex, args, { env, cwd: scenario.startIn === 'sandbox' ? ctx.sandbox.root : project, timeoutMs: ctx.timeoutMs });
  } catch (error) {
    setupError = error.message;
  } finally {
    if (scenario.teardown) scenario.teardown(ctx, project);
  }
  const recorded = readHooks(dir);
  const run = { name: scenario.name, surface: scenario.surface, expect: expectOf(scenario), setupError, proc, events: parseJsonl(proc ? proc.stdout : ''), requests, mockErrors, hooks: recorded.hooks, hookErrors: recorded.errors, project, dir };
  fs.writeFileSync(path.join(dir, 'run.json'), JSON.stringify({ ...run, hooks: undefined }, null, 2));
  return run;
}

function collaborationMode(mode, model) {
  return { mode, settings: { model, reasoning_effort: null, developer_instructions: null } };
}

async function withAppServer(ctx, options, work) {
  if (processes.state.stopping) throw new Error('the probe is stopping');
  const client = new AppServerClient({ codex: ctx.codex, env: options.env, cwd: ctx.sandbox.root, onServerRequest: options.onServerRequest });
  if (options.onClient) options.onClient(client);
  try {
    await client.initialize();
    return await work(client);
  } finally {
    await client.close();
  }
}

async function runTurn(client, ctx, { threadId, text, mode, model }) {
  const before = client.notifications.length;
  const params = { threadId, input: [{ type: 'text', text, text_elements: [] }] };
  if (mode) params.collaborationMode = collaborationMode(mode, model);
  const started = await client.request('turn/start', params);
  const turnId = started && started.turn && started.turn.id;
  const completed = await client.waitFor('turn/completed', () => client.notifications
    .slice(before)
    .find((n) => n.method === 'turn/completed' && (!turnId || (n.params && n.params.turn && n.params.turn.id === turnId))), ctx.timeoutMs);
  const status = completed.params && completed.params.turn ? completed.params.turn.status : null;
  if (status !== 'completed') throw new Error(`the turn for "${text}" ended with status ${status}`);
  return { turnId, notifications: client.notifications.slice(before) };
}

async function runAppScenario(ctx, scenario) {
  const dir = path.join(ctx.sandbox.out, scenario.name);
  const project = path.join(ctx.sandbox.projects, scenario.name);
  fs.mkdirSync(dir, { recursive: true });
  const requests = [];
  const mockErrors = [];
  ctx.route = {
    respond: makeResponder(scenario.script || { main: [] }),
    onRequest: (request) => {
      if (request.served) requests.push(request.body);
    },
    onError: (error) => mockErrors.push(error),
  };
  const env = { ...ctx.env, PROBE_DIR: dir, PROBE_MODE: JSON.stringify(scenario.mode || {}) };
  const serverRequests = [];
  let lastClient = null;
  let result = {};
  let error = null;
  try {
    result = await withAppServer(ctx, {
      env,
      onClient: (client) => {
        lastClient = client;
      },
      onServerRequest: (method, params) => {
        serverRequests.push({ method, params });
        if (method === 'item/tool/requestUserInput') {
          const answers = {};
          for (const question of params.questions || []) {
            const first = (question.options || [])[0];
            answers[question.id] = { answers: [first ? first.label : 'probe'] };
          }
          return { answers };
        }
        if (/requestApproval|Approval$/.test(method)) return { decision: 'accept' };
        return {};
      },
    }, (client) => scenario.drive(client, { ctx, project, dir }));
  } catch (caught) {
    error = caught.message;
  }
  const recorded = readHooks(dir);
  const appServer = lastClient ? { exit: lastClient.exit, stderrTail: lastClient.stderr.slice(-4000), unparsed: lastClient.unparsed } : null;
  const run = { name: scenario.name, surface: null, expect: expectOf(scenario), error, result, requests, mockErrors, serverRequests, notices: noticesOf(lastClient), hookNotifications: hookNotificationsOf(lastClient), appServer, hooks: recorded.hooks, hookErrors: recorded.errors, project, dir };
  fs.writeFileSync(path.join(dir, 'run.json'), JSON.stringify({ ...run, hooks: undefined }, null, 2));
  return run;
}

function trustEdits(hooks) {
  return hooks.map((hook) => ({ keyPath: `hooks.state."${hook.key}".trusted_hash`, mergeStrategy: 'upsert', value: hook.currentHash }));
}

function trustSummary(list) {
  const entry = (list && list.data && list.data[0]) || { hooks: [] };
  return entry.hooks.map((hook) => ({ key: hook.key, event: hook.eventName, trustStatus: hook.trustStatus, currentHash: hook.currentHash }));
}

function allTrusted(summary) {
  return summary.length > 0 && summary.every((hook) => hook.trustStatus === 'trusted');
}

async function listHooksFresh(ctx, env, project) {
  return withAppServer(ctx, { env }, (client) => client.request('hooks/list', { cwds: [project] }));
}

function fixturePlugin(ctx) {
  return path.join(ctx.sandbox.fixture, 'plugins', PLUGIN.name);
}

function editHooks(root, mutate) {
  const hooksFile = path.join(root, 'hooks', 'hooks.json');
  const config = JSON.parse(fs.readFileSync(hooksFile, 'utf8'));
  mutate(config.hooks);
  fs.writeFileSync(hooksFile, `${JSON.stringify(config, null, 2)}\n`);
}

async function installFixture(ctx, version) {
  const manifestFile = path.join(fixturePlugin(ctx), '.codex-plugin', 'plugin.json');
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  manifest.version = version;
  fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = await runCodex(ctx, ['plugin', 'add', PLUGIN.id]);
  const installed = path.join(ctx.sandbox.codexHome, 'plugins', 'cache', PLUGIN.marketplace, PLUGIN.name, version);
  if (result.status !== 0 || !fs.existsSync(installed)) throw new Error(`fixture ${version} did not install: ${result.stderr.trim().slice(0, 200)}`);
}

function semanticScriptEdit(root) {
  const script = path.join(root, 'hooks', 'record.js');
  const text = fs.readFileSync(script, 'utf8');
  const marker = `require('node:fs').writeFileSync(require('node:path').join(process.env.PROBE_DIR || process.cwd(), ${JSON.stringify(FILES.semanticEdit)}), 'ran');\n`;
  const edited = text.replace("'use strict';\n", `'use strict';\n${marker}`);
  if (edited === text) throw new Error('the semantic hook script edit did not apply');
  fs.writeFileSync(script, edited);
}

async function bumpFixture(ctx, version, mutate) {
  if (mutate) mutate(fixturePlugin(ctx));
  await installFixture(ctx, version);
}

async function restoreFixture(ctx, version, mutate) {
  fs.rmSync(fixturePlugin(ctx), { recursive: true, force: true });
  fs.cpSync(path.join(FIXTURE, 'plugins', PLUGIN.name), fixturePlugin(ctx), { recursive: true });
  await bumpFixture(ctx, version, mutate);
}

async function trustAll(client, project) {
  const list = await client.request('hooks/list', { cwds: [project] });
  await client.request('config/batchWrite', { edits: trustEdits(trustSummary(list)), reloadUserConfig: true });
  return trustSummary(await client.request('hooks/list', { cwds: [project] }));
}

async function grantTrust(ctx, project) {
  const summary = await withAppServer(ctx, { env: ctx.env }, (client) => trustAll(client, project));
  if (!allTrusted(summary)) throw new Error('the hook trust grant did not take');
}

async function startThread(client, project, model, overrides = {}) {
  const started = await client.request('thread/start', { cwd: project, model, approvalPolicy: DEFAULTS.approvalPolicy, sandbox: DEFAULTS.sandboxMode, ...overrides });
  return started.thread.id;
}

function controlOf(run) {
  const fail = (reason) => ({ name: run.name, ok: false, reason });
  if (run.setupError) return fail(`setup failed: ${run.setupError}`);
  if (run.hookErrors && run.hookErrors.length) return fail(`a hook record could not be read: ${run.hookErrors[0]}`);
  if (run.mockErrors && run.mockErrors.length) return fail(`the mock model hit a ${run.mockErrors[0].stage} error: ${run.mockErrors[0].message}`);
  if (run.proc) {
    if (run.proc.spawnError) return fail(`codex exec could not start: ${run.proc.spawnError}`);
    if (run.proc.timedOut) return fail('codex exec exceeded the time bound');
    if (run.proc.signal) return fail(`codex exec ended on signal ${run.proc.signal}`);
    if (run.proc.code !== run.expect.exit) return fail(`codex exec exited ${run.proc.code}, expected ${run.expect.exit}`);
  } else if (run.error) {
    return fail(run.error);
  }
  if (run.expect.model && !run.requests.length) return fail('the mock model received no request');
  if (run.proc && run.requests.length && !(SURFACES[run.surface] && SURFACES[run.surface](analyze.toolsOfBody(run.requests[0])))) return fail(`the first request did not offer the ${run.surface} tool surface`);
  if (run.expect.hooks && !run.hooks.some((hook) => hook.event === 'SessionStart')) return fail('no plugin hook ran (SessionStart control missing)');
  if (run.expect.hooks && run.result && run.result.trusted === false) return fail('the hook trust grant did not take');
  if (run.expect.subagent && !run.requests.some(contract.isSubagentBody)) return fail('no model request carried the subagent thread metadata');
  return { name: run.name, ok: true };
}

function sanitizeOverride(text) {
  return text.replace(/"[^"]*\/[^"]*"/g, '"<path>"');
}

function conditionsOf(ctx, selected, native) {
  const scenarioOverrides = {};
  for (const scenario of selected) {
    const list = [...overridesOf(ctx, scenario).map(sanitizeOverride), ...(scenario.notes || [])];
    if (scenario.bypassTrust === false) list.push('without --dangerously-bypass-hook-trust');
    if (scenario.setup === grantTrust) list.push('hooks trusted through config/batchWrite before the run');
    if (list.length) scenarioOverrides[scenario.name] = list;
  }
  return {
    classicModel: MODELS.classic,
    codeModeModel: MODELS.code,
    gpt55Model: MODELS.gpt55,
    sandboxMode: DEFAULTS.sandboxMode,
    approvalPolicy: DEFAULTS.approvalPolicy,
    features: DEFAULTS.features,
    scenarioOverrides,
    modelProvider: 'local Responses-API mock',
    network: 'HTTP(S) and ALL proxy variables point at a closed loopback port with loopback exempt; clients that ignore them are not isolated',
    execHookTrust: 'bypassed with --dangerously-bypass-hook-trust unless a scenario override says otherwise',
    appServerHookTrust: 'measured, then granted through config/batchWrite',
    launcher: native.packageRoot ? 'npm package' : 'native binary',
  };
}

function summaryLines(results) {
  const lines = [];
  for (const key of analyze.FACT_KEYS) {
    const open = analyze.collectUnverified(results.facts[key]);
    lines.push(open.length ? `  UNVERIFIED  ${key} — ${open.join('; ')}` : `  MEASURED    ${key}`);
  }
  lines.push(`  GATE        ${analyze.GATE_INPUTS.map((key) => `${key}=${results.gate[key]}`).join(' ')} → ${results.gate.verdict}`);
  return lines;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (process.env.CODEX_HOME) throw new Error('refusing to run with an inherited CODEX_HOME');
  if ((opts.record || opts.check) && opts.only) throw new Error('--record and --check measure every scenario; drop --only');
  const codex = resolveCodex(opts.codex);
  const native = nativeBinary(codex.bin, codex.version);
  const sandbox = makeSandbox();
  const release = () => {
    try {
      if (opts.keep) process.stdout.write(`kept sandbox: ${sandbox.root}\n`);
      else fs.rmSync(sandbox.root, { recursive: true, force: true, maxRetries: 3 });
    } catch (error) {
      process.stderr.write(`probe: could not remove the sandbox ${sandbox.root}: ${error.message}\n`);
    }
  };
  let signals = 0;
  const onSignal = (signal) => {
    signals += 1;
    processes.state.stopping = true;
    const code = 128 + os.constants.signals[signal];
    if (signals > 1) {
      processes.killChildren();
      process.exit(code);
    }
    processes.stopChildren().finally(() => {
      release();
      process.exit(code);
    });
  };
  process.on('SIGINT', onSignal);
  process.on('SIGTERM', onSignal);
  try {
    process.exitCode = await measure(opts, codex, native, sandbox);
  } finally {
    if (!signals) {
      process.removeListener('SIGINT', onSignal);
      process.removeListener('SIGTERM', onSignal);
      release();
    }
  }
}

function orderedScenarios() {
  const names = SCENARIOS.map((scenario) => scenario.name);
  const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
  const unknown = names.filter((name) => !contract.SCENARIO_NAMES.includes(name));
  const missing = contract.SCENARIO_NAMES.filter((name) => !names.includes(name));
  if (duplicates.length || unknown.length || missing.length) {
    throw new Error(`the scenario table disagrees with contract.SCENARIO_NAMES: duplicated ${duplicates.join(', ') || 'none'}; not in the contract ${unknown.join(', ') || 'none'}; missing ${missing.join(', ') || 'none'}`);
  }
  const unordered = SCENARIOS.filter((scenario) => scenario.group === 'app' && !APP_ORDER.includes(scenario.name));
  if (unordered.length) throw new Error(`app scenarios missing from APP_ORDER: ${unordered.map((scenario) => scenario.name).join(', ')}`);
  const ordered = [
    ...SCENARIOS.filter((scenario) => scenario.group !== 'app' && !scenario.late),
    ...APP_ORDER.map((name) => SCENARIOS.find((scenario) => scenario.name === name)).filter(Boolean),
    ...SCENARIOS.filter((scenario) => scenario.group !== 'app' && scenario.late),
  ];
  if (ordered.length !== SCENARIOS.length || new Set(ordered).size !== SCENARIOS.length) throw new Error('the scenario order does not run every scenario exactly once');
  const firstGrant = ordered.findIndex((scenario) => scenario.grantsHookTrust);
  const afterGrant = firstGrant === -1 ? [] : ordered.slice(firstGrant).filter((scenario) => scenario.needsUntrustedHooks);
  if (afterGrant.length) throw new Error(`untrusted-hook scenarios run after a trust grant: ${afterGrant.map((scenario) => scenario.name).join(', ')}`);
  return ordered;
}

async function measure(opts, codex, native, sandbox) {
  const selected = orderedScenarios().filter((scenario) => !opts.only || opts.only.includes(scenario.name) || opts.only.includes(scenario.group));
  const ctx = {
    codex: codex.bin,
    version: codex.version,
    sandbox,
    env: baseEnv(sandbox),
    timeoutMs: opts.timeoutSec * 1000,
    projectDirs: selected.filter((scenario) => !scenario.untrusted).map((scenario) => path.join(sandbox.projects, scenario.name)),
    route: { respond: () => [message('probe: no scenario is active.')], onRequest: () => {}, onError: () => {} },
  };
  for (const scenario of selected) fs.mkdirSync(path.join(sandbox.projects, scenario.name), { recursive: true });
  const mock = await startMockModel({
    respond: (body, turn) => ctx.route.respond(body, turn),
    onRequest: (request) => ctx.route.onRequest(request),
    onError: (error) => ctx.route.onError(error),
  });
  ctx.port = mock.port;
  const runs = [];
  try {
    writeConfig(ctx);
    const install = await installPlugin(ctx);
    if (install.marketplace.status !== 0 || install.plugin.status !== 0) {
      throw new Error(`fixture install failed: ${install.marketplace.stderr}${install.plugin.stderr}`);
    }
    for (const scenario of selected) {
      process.stdout.write(`  running ${scenario.name}\n`);
      if (scenario.group === 'app') runs.push(await runAppScenario(ctx, scenario));
      else runs.push(await runExecScenario(ctx, scenario));
    }
  } finally {
    await mock.close();
  }
  const controls = runs.map(controlOf);
  if (!native.binary) controls.push({ name: 'codex-binary', ok: false, reason: `no native codex binary that reports version ${codex.version} was found, so the TUI strings cannot be read` });
  const facts = analyze.deriveFacts(runs, {
    fs,
    codexHome: sandbox.codexHome,
    plugin: { ...PLUGIN, version: '0.0.1' },
    tuiStrings: binaryStrings(native.binary, TUI_STRINGS),
  });
  const results = {
    schemaVersion: analyze.SCHEMA_VERSION,
    codexVersion: codex.version,
    measuredOn: new Date().toISOString().slice(0, 10),
    conditions: conditionsOf(ctx, selected, native),
    facts,
    gate: analyze.deriveGate(facts),
  };
  process.stdout.write(`\nCodex ${codex.version}: ${runs.length} scenario(s)\n`);
  for (const control of controls) if (!control.ok) process.stdout.write(`  FAIL        control ${control.name}: ${control.reason}\n`);
  process.stdout.write(`${summaryLines(results).join('\n')}\n`);
  const problems = analyze.validateResults(results);
  for (const problem of problems) process.stdout.write(`  FAIL        results: ${problem}\n`);
  let exit = controls.every((control) => control.ok) && problems.length === 0 ? 0 : 1;
  const resultFile = path.join(RESULTS_DIR, `${codex.version}.json`);
  if (opts.record && exit === 0) {
    fs.mkdirSync(RESULTS_DIR, { recursive: true });
    fs.writeFileSync(resultFile, `${JSON.stringify(results, null, 2)}\n`);
    process.stdout.write(`  RECORDED    ${path.relative(process.cwd(), resultFile)}\n`);
  }
  if (opts.check) {
    if (!fs.existsSync(resultFile)) {
      process.stdout.write(`  FAIL        no recorded results for codex ${codex.version}\n`);
      exit = 1;
    } else {
      const recorded = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
      const diffs = analyze.diffPaths(analyze.comparable(recorded), analyze.comparable(results));
      for (const line of diffs) process.stdout.write(`  DRIFT       ${line}\n`);
      process.stdout.write(diffs.length ? '  FAIL        the measured contract drifted from the recorded one\n' : `  MATCH       results/${codex.version}.json\n`);
      if (diffs.length) exit = 1;
    }
  }
  if (opts.print) process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
  return exit;
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`probe: ${error.message}\n`);
    process.exitCode = 2;
  });
}

module.exports = { parseArgs, makeResponder, orderedScenarios, controlOf, expectOf, baseEnv, sessionIdFrom, agentIdFrom, runProcess, reviewerProfileRole, conditionsOf, SCENARIOS };
