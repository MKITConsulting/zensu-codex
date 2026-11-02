#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const MAX_RECORD_BYTES = 64 * 1024;
const RUNTIME_VERSION_RE = /^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$/;
const PLUGIN_ROOT_VARIABLES = ['PLUGIN_ROOT', 'CLAUDE_PLUGIN_ROOT', 'ZENSU_PLUGIN_ROOT', 'CODEX_PLUGIN_ROOT'];
const NOTICE_EVENTS = new Set(['UserPromptSubmit']);
const QUIET_EVENTS = new Set(['UserPromptSubmit', 'PreToolUse', 'Stop']);

const REFUSALS = Object.freeze({
  NO_RECORD: 'no-record',
  ALREADY_SERVED: 'already-served',
  RECORD_UNREADABLE: 'record-unreadable',
  PLUGIN_DATA: 'plugin-data-mismatch',
  PROJECT_ROOT: 'project-root-unavailable',
  FOREIGN_PROJECT: 'foreign-project',
  SAME_INSTALLATION: 'same-installation',
  NOT_SIBLING: 'not-a-sibling-installation',
  EXECUTING_UNIDENTIFIED: 'executing-installation-unidentified',
  BACKWARDS: 'backwards',
  WORKFLOW_STATE: 'workflow-state-unreadable',
});

const REFUSAL_TEXT = Object.freeze({
  [REFUSALS.RECORD_UNREADABLE]: 'its Session Control record is unreadable',
  [REFUSALS.PLUGIN_DATA]: 'its record belongs to another Session Control store',
  [REFUSALS.PROJECT_ROOT]: 'its recorded project root is unavailable',
  [REFUSALS.FOREIGN_PROJECT]: 'the hook ran in another project than the recorded one',
  [REFUSALS.SAME_INSTALLATION]: 'the bound installation changed in place, which is never re-bound',
  [REFUSALS.NOT_SIBLING]: 'the installed plugin is not a sibling of the bound installation',
  [REFUSALS.EXECUTING_UNIDENTIFIED]: 'the bound or the installed plugin version cannot be identified',
  [REFUSALS.BACKWARDS]: 'the installed plugin is older than the bound one',
  [REFUSALS.WORKFLOW_STATE]: 'its workflow state is missing or unreadable',
});

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

function refusal(reason, state = {}) {
  return { adoptable: false, adopted: false, reason, ...state };
}

function parseVersion(value) {
  const match = typeof value === 'string' ? RUNTIME_VERSION_RE.exec(value) : null;
  return match ? match.slice(1).map(Number) : null;
}

function compareVersions(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  }
  return 0;
}

function executingPluginRoot(input) {
  const root = canonicalDirectory(input || path.resolve(__dirname, '..', '..'), 'executing plugin root');
  for (const variable of PLUGIN_ROOT_VARIABLES) {
    if (!process.env[variable]) continue;
    if (canonicalDirectory(process.env[variable], variable) !== root) {
      throw new Error(`${variable} does not match the executing plugin installation`);
    }
  }
  return root;
}

function manifestVersion(pluginRoot) {
  const file = path.join(pluginRoot, '.codex-plugin', 'plugin.json');
  const stat = fs.lstatSync(file);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size > MAX_RECORD_BYTES) throw new Error('plugin manifest is unsafe');
  const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!manifest || manifest.name !== 'zensu') throw new Error('plugin manifest must identify zensu');
  return manifest.version;
}

function readRecord(file) {
  const stat = fs.lstatSync(file);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.nlink !== 1 || stat.size > MAX_RECORD_BYTES) {
    throw new Error('record is unsafe');
  }
  const record = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error('record is not an object');
  return record;
}

function servedContext(recordsDir, sessionId) {
  try {
    return core.readContext({ recordsDir, sessionId, expectedHost: 'codex' });
  } catch {
    return null;
  }
}

function adoptableRecord(options) {
  let pluginRoot;
  let controlRoot;
  try {
    pluginRoot = executingPluginRoot(options.executingPluginRoot);
    const home = canonicalDirectory(options.home, 'HOME');
    const controlPath = path.join(home, '.zensu', 'session-control', 'codex', 'v3');
    if (!fs.existsSync(controlPath)) return refusal(REFUSALS.NO_RECORD);
    controlRoot = canonicalDirectory(controlPath, 'Session Control root');
  } catch {
    return refusal(REFUSALS.EXECUTING_UNIDENTIFIED);
  }
  const recordsDir = path.join(controlRoot, 'records');
  const key = core.sessionKey(options.sessionId);
  const file = path.join(recordsDir, `${key}.json`);
  if (!fs.existsSync(file)) return refusal(REFUSALS.NO_RECORD);
  const served = servedContext(recordsDir, options.sessionId);
  if (served && served.plugin_root === pluginRoot) return refusal(REFUSALS.ALREADY_SERVED, { context: served });
  let record;
  try {
    record = readRecord(file);
  } catch {
    return refusal(REFUSALS.RECORD_UNREADABLE);
  }
  if (
    record.schema !== core.SCHEMA
    || record.schema_version !== core.SCHEMA_VERSION
    || record.host !== 'codex'
    || record.session_id_hash !== core.sessionIdHash(options.sessionId)
    || typeof record.plugin_root !== 'string'
    || typeof record.project_root !== 'string'
  ) {
    return refusal(REFUSALS.RECORD_UNREADABLE);
  }
  if (record.plugin_data !== controlRoot) return refusal(REFUSALS.PLUGIN_DATA);
  let projectRoot;
  try {
    projectRoot = canonicalDirectory(record.project_root, 'recorded project root');
  } catch {
    return refusal(REFUSALS.PROJECT_ROOT);
  }
  if (projectRoot !== record.project_root) return refusal(REFUSALS.PROJECT_ROOT);
  let cwd;
  try {
    cwd = canonicalDirectory(options.cwd, 'hook cwd');
  } catch {
    return refusal(REFUSALS.FOREIGN_PROJECT);
  }
  if (cwd !== projectRoot) return refusal(REFUSALS.FOREIGN_PROJECT);
  if (record.plugin_root === pluginRoot) {
    const current = servedContext(recordsDir, options.sessionId);
    if (current && current.plugin_root === pluginRoot) return refusal(REFUSALS.ALREADY_SERVED, { context: current });
    return refusal(REFUSALS.SAME_INSTALLATION);
  }
  if (path.dirname(record.plugin_root) !== path.dirname(pluginRoot)) return refusal(REFUSALS.NOT_SIBLING);
  let executingVersion;
  try {
    executingVersion = manifestVersion(pluginRoot);
  } catch {
    return refusal(REFUSALS.EXECUTING_UNIDENTIFIED);
  }
  const recordedParts = parseVersion(record.plugin_version);
  const executingParts = parseVersion(executingVersion);
  if (recordedParts === null || executingParts === null) return refusal(REFUSALS.EXECUTING_UNIDENTIFIED);
  const versions = { recorded: record.plugin_version, executing: executingVersion };
  if (compareVersions(executingParts, recordedParts) < 0) return refusal(REFUSALS.BACKWARDS, versions);
  try {
    core.readWorkflowState({ projectRoot, sessionId: options.sessionId });
  } catch {
    return refusal(REFUSALS.WORKFLOW_STATE, versions);
  }
  return { adoptable: true, adopted: false, recordsDir, controlRoot, pluginRoot, projectRoot, ...versions };
}

function adoptForHook(options) {
  const verdict = adoptableRecord(options);
  if (!verdict.adoptable) return verdict;
  core.registerContext({
    recordsDir: verdict.recordsDir,
    host: 'codex',
    sessionId: options.sessionId,
    projectRoot: verdict.projectRoot,
    pluginRoot: verdict.pluginRoot,
    pluginData: verdict.controlRoot,
    supersedeInstallation: true,
  });
  const context = core.readContext({ recordsDir: verdict.recordsDir, sessionId: options.sessionId, expectedHost: 'codex' });
  if (context.plugin_root !== verdict.pluginRoot) throw new Error('the re-bound record does not name the executing installation');
  return { adoptable: true, adopted: true, context, recorded: verdict.recorded, executing: verdict.executing };
}

function refusalText(verdict) {
  return REFUSAL_TEXT[verdict.reason] || null;
}

function adoptionNotice(verdict) {
  if (verdict.adopted) {
    return `Zensu Session Control re-bound this chat from Zensu ${verdict.recorded} to the installed Zensu ${verdict.executing} after a plugin update; the Zensu workflow continues in this chat.`;
  }
  const text = refusalText(verdict);
  if (!text) return null;
  return `Zensu Session Control cannot re-bind this chat to the installed Zensu plugin: ${text}. Start a new chat to continue the Zensu workflow.`;
}

function readPayload(events) {
  const raw = fs.readFileSync(0);
  if (raw.length === 0 || raw.length > MAX_PAYLOAD_BYTES) return null;
  let payload;
  try {
    payload = JSON.parse(raw.toString('utf8'));
  } catch {
    return null;
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
  if (!events.has(payload.hook_event_name)) return null;
  if (Object.prototype.hasOwnProperty.call(payload, 'agent_id') || Object.prototype.hasOwnProperty.call(payload, 'agent_type')) return null;
  for (const field of ['session_id', 'cwd']) {
    if (typeof payload[field] !== 'string' || payload[field].trim() === '' || payload[field].length > 16384 || /[\0\r\n]/.test(payload[field])) {
      return null;
    }
  }
  return payload;
}

function main(argv) {
  const quiet = argv.length === 1 && argv[0] === '--quiet';
  if (argv.length > 0 && !quiet) return;
  const payload = readPayload(quiet ? QUIET_EVENTS : NOTICE_EVENTS);
  if (!payload) return;
  let verdict;
  try {
    verdict = adoptForHook({ home: process.env.HOME, sessionId: payload.session_id, cwd: payload.cwd });
  } catch (error) {
    process.stderr.write(`zensu session-control re-bind failed: ${error.message}\n`);
    return;
  }
  if (quiet) return;
  const notice = adoptionNotice(verdict);
  if (!notice) return;
  process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: notice } })}\n`);
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`zensu session-control re-bind failed: ${error.message}\n`);
  }
}

module.exports = { REFUSALS, adoptableRecord, adoptForHook, adoptionNotice, refusalText };
