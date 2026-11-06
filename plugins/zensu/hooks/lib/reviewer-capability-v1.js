#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const adoption = require('./codex-session-adopt-v1.js');
const directive = require('./codex-reanchor-directive-v1.js');
const principals = require('./codex-principal-v1.js');
const { RETRUST_HINT } = require('./codex-retrust-hint-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const SHELL_TOOLS = new Set(['shell', 'bash', 'exec', 'exec_command', 'functions.exec', 'terminal', 'command']);
const SPAWN_OR_CONTROL_TOOLS = new Set([
  'agent',
  'task',
  'spawn_agent',
  'followup_task',
  'send_message',
  'skill',
  'update_goal',
  'update_plan',
]);
const SEARCH_TOOLS = new Set(['grep', 'glob', 'search', 'rg']);
const HOST_SAFE_TOOLS = new Set([
  'read',
  'read_file',
  'grep',
  'glob',
  'search',
  'rg',
  'write',
  'edit',
  'multiedit',
  'notebookedit',
  'apply_patch',
]);
const CONTROL_TOKENS = [
  'ZENSU_SESSION_KEY',
  'CODEX_THREAD_ID',
  'main-v1',
  'session-control',
  'session_control',
  'resolve-v3.js',
  'zensu-log.sh',
  'tdd-phase-',
  'workflow-state',
  'render-main',
];

function deny(reason) {
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: `Zensu Session Control capability boundary: ${reason}`,
    },
  })}\n`);
}

function parsePayload() {
  const raw = fs.readFileSync(0);
  if (raw.length === 0 || raw.length > MAX_PAYLOAD_BYTES) {
    throw new Error('trusted hook payload is empty or too large');
  }
  const payload = JSON.parse(raw.toString('utf8'));
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error('trusted hook payload must be an object');
  }
  if (payload.hook_event_name && payload.hook_event_name !== 'PreToolUse') {
    throw new Error('unexpected hook event');
  }
  for (const field of ['session_id', 'cwd', 'tool_name']) {
    if (
      typeof payload[field] !== 'string'
      || payload[field].trim() === ''
      || payload[field].length > (field === 'session_id' ? 4096 : 16384)
      || /[\0\r\n]/.test(payload[field])
    ) {
      throw new Error(`${field} is unavailable or unsafe`);
    }
  }
  for (const field of ['agent_id', 'agent_type']) {
    if (
      Object.prototype.hasOwnProperty.call(payload, field)
      && (
        typeof payload[field] !== 'string'
        || payload[field].trim() === ''
        || payload[field].length > 512
        || /[\0\r\n]/.test(payload[field])
      )
    ) {
      throw new Error(`${field} is unsafe`);
    }
  }
  if (!payload.tool_input || typeof payload.tool_input !== 'object' || Array.isArray(payload.tool_input)) {
    payload.tool_input = {};
  }
  return payload;
}

function canonicalDirectory(value, label) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) {
    throw new Error(`${label} is missing or unsafe`);
  }
  let canonical;
  try {
    canonical = fs.realpathSync.native(value);
  } catch {
    throw new Error(`${label} does not exist`);
  }
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory`);
  return canonical;
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function canonicalCandidate(projectRoot, value) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) return null;
  const requested = path.resolve(projectRoot, value);
  let existing = requested;
  const suffix = [];
  while (true) {
    let stat;
    try {
      stat = fs.lstatSync(existing);
    } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
      const parent = path.dirname(existing);
      if (parent === existing) throw new Error('tool path has no existing canonical ancestor');
      suffix.unshift(path.basename(existing));
      existing = parent;
      continue;
    }
    if (stat.isSymbolicLink()) {
      let canonicalTarget;
      try {
        canonicalTarget = fs.realpathSync.native(existing);
      } catch {
        throw new Error('tool path traverses a dangling symbolic link');
      }
      if (suffix.length > 0 && !fs.lstatSync(canonicalTarget).isDirectory()) {
        throw new Error('tool path traverses a non-directory ancestor');
      }
      return path.resolve(canonicalTarget, ...suffix);
    }
    if (suffix.length > 0 && !stat.isDirectory()) {
      throw new Error('tool path traverses a non-directory ancestor');
    }
    return path.resolve(fs.realpathSync.native(existing), ...suffix);
  }
}

function servedOrAdoptedContext({ home, recordsDir, pluginRoot, payload }) {
  let failure;
  try {
    const context = core.readContext({ recordsDir, sessionId: payload.session_id, expectedHost: 'codex' });
    if (context.plugin_root === pluginRoot) return context;
    failure = new Error('context plugin root mismatch');
  } catch (error) {
    failure = error;
  }
  if (principals.classifyPreToolPayload(payload) !== principals.PRINCIPALS.MAIN) throw failure;
  const verdict = adoption.adoptForHook({ home, sessionId: payload.session_id, cwd: payload.cwd, executingPluginRoot: pluginRoot });
  if (verdict.adopted || verdict.reason === adoption.REFUSALS.ALREADY_SERVED) return verdict.context;
  const refused = adoption.refusalText(verdict);
  if (verdict.reason === adoption.REFUSALS.FOREIGN_PROJECT) throw directive.projectMismatch(`${failure.message}; re-bind refused: ${refused}`);
  throw new Error(refused ? `${failure.message}; re-bind refused: ${refused}; start a new chat to continue the Zensu workflow` : failure.message);
}

function revalidateSessionContext(payload) {
  const pluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  const home = canonicalDirectory(process.env.HOME, 'HOME');
  const controlRoot = path.join(home, '.zensu', 'session-control', 'codex', 'v3');
  const recordsDir = path.join(controlRoot, 'records');
  const context = servedOrAdoptedContext({ home, recordsDir, pluginRoot, payload });
  if (context.plugin_data !== fs.realpathSync.native(controlRoot)) throw new Error('context control root mismatch');
  const projectRoot = canonicalDirectory(payload.cwd, 'PreToolUse cwd');
  if (context.project_root !== projectRoot) throw directive.projectMismatch('tool project does not match immutable context');
  core.readWorkflowState({ projectRoot: context.project_root, sessionId: payload.session_id });
  return {
    context,
    projectRoot,
    pluginRoot,
    controlRoot: fs.realpathSync.native(controlRoot),
    homeZensu: path.join(home, '.zensu'),
  };
}

function inputStrings(input) {
  const strings = [];
  const pending = [input];
  let visited = 0;
  while (pending.length > 0) {
    const value = pending.pop();
    visited += 1;
    if (visited > 20000) throw new Error('tool input is too complex');
    if (typeof value === 'string') strings.push(value);
    else if (Array.isArray(value)) pending.push(...value);
    else if (value && typeof value === 'object') pending.push(...Object.values(value));
  }
  return strings;
}

function pathInputs(input) {
  const values = [];
  const pending = [input];
  let visited = 0;
  while (pending.length > 0) {
    const current = pending.pop();
    if (!current || typeof current !== 'object') continue;
    visited += 1;
    if (visited > 20000) throw new Error('tool path input is too complex');
    for (const [key, value] of Object.entries(current)) {
      if (/(?:^|_)(?:file_?path|path|paths|files|directory|root|cwd|workdir)$/i.test(key)) {
        if (typeof value === 'string') values.push(value);
        else if (Array.isArray(value)) values.push(...value.filter((entry) => typeof entry === 'string'));
      }
      if (Array.isArray(value)) pending.push(...value);
      else if (value && typeof value === 'object') pending.push(value);
    }
  }
  for (const value of inputStrings(input)) {
    for (const match of value.matchAll(/^\*\*\*\s+(?:Add|Update|Delete) File:\s+(.+?)\s*$/gm)) values.push(match[1]);
    for (const match of value.matchAll(/^\*\*\*\s+Move to:\s+(.+?)\s*$/gm)) values.push(match[1]);
  }
  return values;
}

function hostViolation(payload, trusted) {
  const tool = payload.tool_name.toLowerCase();
  if (SHELL_TOOLS.has(tool) || /(?:^|[.:_/])(?:shell|bash|exec_command|terminal)(?:$|[.:_/])/.test(tool)) {
    return 'host-profile-v1 cannot invoke shell or command-execution tools';
  }
  if (SPAWN_OR_CONTROL_TOOLS.has(tool) || tool.startsWith('mcp__')) {
    return 'host-profile-v1 cannot invoke agent, workflow-control, Skill, or MCP tools';
  }
  if (!HOST_SAFE_TOOLS.has(tool)) return `host-profile-v1 cannot invoke unapproved tool ${payload.tool_name}`;

  const normalizedStrings = [payload.tool_name, ...inputStrings(payload.tool_input)]
    .map((value) => value.replaceAll('\\', '/'));
  const protectedText = [trusted.controlRoot, trusted.homeZensu, trusted.pluginRoot]
    .map((value) => value.replaceAll('\\', '/'));
  for (const value of normalizedStrings) {
    if (CONTROL_TOKENS.some((token) => value.includes(token))) {
      return 'host-profile-v1 cannot select main-v1 or access Session Control/workflow state';
    }
    if (/(?:^|\/)\.zensu(?:\/|$)/.test(value) || protectedText.some((entry) => value.includes(entry))) {
      return 'host-profile-v1 cannot access a protected control path';
    }
  }

  const candidates = pathInputs(payload.tool_input).map((value) => canonicalCandidate(trusted.projectRoot, value));
  const protectedRoots = [trusted.controlRoot, trusted.homeZensu, trusted.pluginRoot, path.join(trusted.projectRoot, '.zensu')];
  if (candidates.some((candidate) => candidate && !isInside(trusted.projectRoot, candidate))) {
    return 'host-profile-v1 file access must remain inside the immutable project root';
  }
  if (candidates.some((candidate) => candidate && protectedRoots.some((root) => isInside(root, candidate)))) {
    return 'host-profile-v1 cannot access a protected control path or alias';
  }
  if (SEARCH_TOOLS.has(tool)) {
    if (candidates.length === 0) return 'host-profile-v1 searches require an explicit non-control path';
    if (candidates.some((candidate) => candidate === trusted.projectRoot)) {
      return 'host-profile-v1 cannot recursively search the workflow-root ancestor';
    }
  }
  return null;
}

function main() {
  let payload;
  try {
    payload = parsePayload();
  } catch (error) {
    deny(error.message);
    return;
  }

  let trusted;
  try {
    trusted = revalidateSessionContext(payload);
  } catch (error) {
    deny(`immutable context revalidation failed: ${error.message}. ${error.code === directive.PROJECT_MISMATCH ? directive.REANCHOR_HINT : RETRUST_HINT}`);
    return;
  }

  const principal = principals.classifyPreToolPayload(payload);
  if (principal === principals.PRINCIPALS.MAIN) return;
  if (principal === principals.PRINCIPALS.REVIEWER) {
    deny(`reviewer-readonly-v1 cannot invoke ${payload.tool_name}; Codex reviewers are packet-only`);
    return;
  }
  try {
    const violation = hostViolation(payload, trusted);
    if (violation) deny(violation);
  } catch (error) {
    deny(`host-profile-v1 input validation failed: ${error.message}`);
  }
}

main();
