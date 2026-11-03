#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const core = require('./session-control-core-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const MAX_RECORD_BYTES = 64 * 1024;
const MAX_DIRECTIVE_LENGTH = 256;
const GIT_TIMEOUT_MS = 2000;
const RUNTIME_VERSION_RE = /^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$/;
const PLUGIN_ROOT_VARIABLES = ['PLUGIN_ROOT', 'CLAUDE_PLUGIN_ROOT', 'ZENSU_PLUGIN_ROOT', 'CODEX_PLUGIN_ROOT'];
const NOTICE_EVENTS = new Set(['UserPromptSubmit']);
const QUIET_EVENTS = new Set(['UserPromptSubmit', 'PreToolUse', 'Stop']);
const REANCHOR_DIRECTIVE = 'zensu reanchor';
const DISCARD_OPEN_WORK = '--discard-open-work';
const REANCHOR_PHASE = 'PROJECT_ROOT_REANCHORED';
const PROJECT_MISMATCH = 'ZENSU_PROJECT_MISMATCH';
const REANCHOR_HINT = `This chat works in another directory than the project root Zensu Session Control is anchored to. If it moved to another worktree of the same repository, only the user can move the anchor there, by sending the message \`${REANCHOR_DIRECTIVE}\` on its own; otherwise start a new chat in this directory.`;

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

const REANCHOR_REFUSALS = Object.freeze({
  RECORDED_ROOT_MISSING: 'recorded-root-missing',
  TARGET_MISSING: 'target-missing',
  ALREADY_ANCHORED: 'already-anchored',
  RECORDED_ROOT_NOT_IN_WORKTREE: 'recorded-root-not-in-a-worktree',
  TARGET_NOT_IN_WORKTREE: 'target-not-in-a-worktree',
  DIFFERENT_REPOSITORY: 'different-repository',
  TARGET_NOT_REGISTERED: 'target-not-a-registered-worktree',
  TARGET_CONTAINS_RECORDED_ROOT: 'target-contains-recorded-root',
  TARGET_CONTAINS_WORKTREES: 'target-contains-other-worktrees',
  DIFFERENT_POSITION: 'different-position-in-worktree',
  WORKFLOW_IN_PROGRESS: 'workflow-in-progress',
  TARGET_WORKFLOW_STATE: 'target-workflow-state-unusable',
});

const REANCHOR_REFUSAL_TEXT = Object.freeze({
  [REFUSALS.NO_RECORD]: 'this chat has no Session Control record',
  [REFUSALS.RECORD_UNREADABLE]: 'its Session Control record is unreadable',
  [REFUSALS.PLUGIN_DATA]: 'its record belongs to another Session Control store',
  [REFUSALS.WORKFLOW_STATE]: 'its workflow state under the anchored project root is missing or unreadable',
  [REANCHOR_REFUSALS.RECORDED_ROOT_MISSING]: 'the project root it is anchored to no longer exists, so the repository it belonged to cannot be proven',
  [REANCHOR_REFUSALS.TARGET_MISSING]: 'the working directory of this chat is unavailable',
  [REANCHOR_REFUSALS.ALREADY_ANCHORED]: 'it is already anchored to the working directory of this chat',
  [REANCHOR_REFUSALS.RECORDED_ROOT_NOT_IN_WORKTREE]: 'git does not place the anchored project root inside a worktree',
  [REANCHOR_REFUSALS.TARGET_NOT_IN_WORKTREE]: 'git does not place the working directory of this chat inside a worktree',
  [REANCHOR_REFUSALS.DIFFERENT_REPOSITORY]: 'the working directory of this chat belongs to another repository than the anchored project root',
  [REANCHOR_REFUSALS.TARGET_NOT_REGISTERED]: 'the worktree of this chat is not a registered worktree of that repository, or git marks it prunable',
  [REANCHOR_REFUSALS.TARGET_CONTAINS_RECORDED_ROOT]: 'the worktree of this chat contains the anchored project root',
  [REANCHOR_REFUSALS.TARGET_CONTAINS_WORKTREES]: 'other registered worktrees of the repository lie inside the worktree of this chat',
  [REANCHOR_REFUSALS.DIFFERENT_POSITION]: 'the working directory of this chat does not sit at the same place in its worktree as the anchored project root in its own',
  [REANCHOR_REFUSALS.WORKFLOW_IN_PROGRESS]: 'its workflow state under the anchored project root still holds open work',
  [REANCHOR_REFUSALS.TARGET_WORKFLOW_STATE]: 'a workflow state of this chat under the new worktree is unsafe or unreadable, and it is never overwritten',
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

function directoryOrNull(value) {
  try {
    return canonicalDirectory(value, 'directory');
  } catch {
    return null;
  }
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function refusal(reason, state = {}) {
  return { adoptable: false, adopted: false, reason, ...state };
}

function reanchorRefusal(reason, state = {}) {
  return { reanchorable: false, reanchored: false, reason, ...state };
}

function projectMismatch(message) {
  return Object.assign(new Error(message), { code: PROJECT_MISMATCH });
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

function boundRecord(options) {
  let pluginRoot;
  let controlRoot;
  try {
    pluginRoot = executingPluginRoot(options.executingPluginRoot);
    const home = canonicalDirectory(options.home, 'HOME');
    const controlPath = path.join(home, '.zensu', 'session-control', 'codex', 'v3');
    if (!fs.existsSync(controlPath)) return { refusal: REFUSALS.NO_RECORD };
    controlRoot = canonicalDirectory(controlPath, 'Session Control root');
  } catch {
    return { refusal: REFUSALS.EXECUTING_UNIDENTIFIED };
  }
  const recordsDir = path.join(controlRoot, 'records');
  const file = path.join(recordsDir, `${core.sessionKey(options.sessionId)}.json`);
  if (!fs.existsSync(file)) return { refusal: REFUSALS.NO_RECORD };
  const current = servedContext(recordsDir, options.sessionId);
  const served = current && current.plugin_root === pluginRoot ? current : null;
  let record;
  try {
    record = readRecord(file);
  } catch {
    return { refusal: REFUSALS.RECORD_UNREADABLE, served };
  }
  if (
    record.schema !== core.SCHEMA
    || record.schema_version !== core.SCHEMA_VERSION
    || record.host !== 'codex'
    || record.session_id_hash !== core.sessionIdHash(options.sessionId)
    || typeof record.plugin_root !== 'string'
    || typeof record.project_root !== 'string'
  ) {
    return { refusal: REFUSALS.RECORD_UNREADABLE, served };
  }
  if (record.plugin_data !== controlRoot) return { refusal: REFUSALS.PLUGIN_DATA, served };
  return { served, pluginRoot, controlRoot, recordsDir, record };
}

function installationVerdict(record, pluginRoot) {
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
  return { adoptable: true, adopted: false, ...versions };
}

function adoptableRecord(options) {
  const bound = boundRecord(options);
  if (bound.served) return refusal(REFUSALS.ALREADY_SERVED, { context: bound.served });
  if (bound.refusal) return refusal(bound.refusal);
  const { record, recordsDir, controlRoot, pluginRoot } = bound;
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
  const installation = installationVerdict(record, pluginRoot);
  if (!installation.adoptable) return installation;
  const versions = { recorded: installation.recorded, executing: installation.executing };
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

function gitEnvironment() {
  const environment = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (!name.startsWith('GIT_')) environment[name] = value;
  }
  return { ...environment, LC_ALL: 'C', GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' };
}

function runGit(cwd, args) {
  try {
    return execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: 4 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
      env: gitEnvironment(),
    });
  } catch {
    return null;
  }
}

function worktreeIdentity(directory) {
  const top = runGit(directory, ['rev-parse', '--path-format=absolute', '--show-toplevel']);
  const common = runGit(directory, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
  if (top === null || common === null) return null;
  const topPath = directoryOrNull(path.resolve(directory, top.split(/\r?\n/)[0]));
  const commonDir = directoryOrNull(path.resolve(directory, common.split(/\r?\n/)[0]));
  return topPath && commonDir ? { top: topPath, commonDir } : null;
}

function registeredWorktrees(directory) {
  const listed = runGit(directory, ['worktree', 'list', '--porcelain', '-z']);
  if (listed === null) return null;
  const entries = [];
  let current = null;
  for (const field of listed.split('\0')) {
    if (field.startsWith('worktree ')) {
      if (current) entries.push(current);
      current = { path: field.slice('worktree '.length), bare: false, prunable: false };
    } else if (field === '') {
      if (current) entries.push(current);
      current = null;
    } else if (current && field === 'bare') {
      current.bare = true;
    } else if (current && (field === 'prunable' || field.startsWith('prunable '))) {
      current.prunable = true;
    }
  }
  if (current) entries.push(current);
  return entries.map((entry) => ({ ...entry, canonical: directoryOrNull(entry.path) }));
}

function workflowDocument(root, sessionId) {
  const zensu = path.join(root, '.zensu');
  const stateDirectory = path.join(zensu, 'state');
  const file = path.join(stateDirectory, `tdd-phase-${core.sessionKey(sessionId)}.json`);
  for (const [candidate, kind] of [[zensu, 'directory'], [stateDirectory, 'directory'], [file, 'file']]) {
    let stat;
    try {
      stat = fs.lstatSync(candidate);
    } catch (error) {
      return { state: error.code === 'ENOENT' ? 'missing' : 'unusable' };
    }
    if (stat.isSymbolicLink() || (kind === 'directory' ? !stat.isDirectory() : !stat.isFile())) return { state: 'unusable' };
    if (kind === 'file' && (stat.nlink !== 1 || stat.size > MAX_PAYLOAD_BYTES)) return { state: 'unusable' };
  }
  try {
    return { state: 'present', document: core.readWorkflowState({ projectRoot: root, sessionId }) };
  } catch {
    return { state: 'unusable' };
  }
}

function openWork(state) {
  if (state.workflowActive === true) return 'an open Zensu skill workflow';
  if (state.active === true && state.chainDone !== true) return 'an armed review chain that has not reached its terminus';
  return '';
}

function reanchorVerdict(options) {
  const bound = boundRecord(options);
  if (bound.refusal) return reanchorRefusal(bound.refusal);
  const { record } = bound;
  const recordedRoot = directoryOrNull(record.project_root);
  if (recordedRoot === null) return reanchorRefusal(REANCHOR_REFUSALS.RECORDED_ROOT_MISSING);
  if (recordedRoot !== record.project_root) return reanchorRefusal(REFUSALS.RECORD_UNREADABLE);
  const anchor = { anchoredRoot: recordedRoot };
  const target = directoryOrNull(options.cwd);
  if (target === null) return reanchorRefusal(REANCHOR_REFUSALS.TARGET_MISSING, anchor);
  if (target === recordedRoot) return reanchorRefusal(REANCHOR_REFUSALS.ALREADY_ANCHORED, anchor);
  const recorded = worktreeIdentity(recordedRoot);
  if (!recorded) return reanchorRefusal(REANCHOR_REFUSALS.RECORDED_ROOT_NOT_IN_WORKTREE, anchor);
  const moved = worktreeIdentity(target);
  if (!moved) return reanchorRefusal(REANCHOR_REFUSALS.TARGET_NOT_IN_WORKTREE, anchor);
  if (moved.commonDir !== recorded.commonDir) return reanchorRefusal(REANCHOR_REFUSALS.DIFFERENT_REPOSITORY, anchor);
  const worktrees = registeredWorktrees(recorded.top);
  const entry = worktrees && worktrees.find((worktree) => worktree.canonical === moved.top);
  if (!entry || entry.prunable || entry.bare) return reanchorRefusal(REANCHOR_REFUSALS.TARGET_NOT_REGISTERED, anchor);
  if (isInside(moved.top, recordedRoot)) return reanchorRefusal(REANCHOR_REFUSALS.TARGET_CONTAINS_RECORDED_ROOT, anchor);
  if (worktrees.some((worktree) => worktree.canonical && worktree.canonical !== moved.top && isInside(moved.top, worktree.canonical))) {
    return reanchorRefusal(REANCHOR_REFUSALS.TARGET_CONTAINS_WORKTREES, anchor);
  }
  if (path.relative(recorded.top, recordedRoot) !== path.relative(moved.top, target)) {
    return reanchorRefusal(REANCHOR_REFUSALS.DIFFERENT_POSITION, anchor);
  }
  let installation = { rebind: false };
  if (!bound.served) {
    if (record.plugin_root === bound.pluginRoot) return reanchorRefusal(REFUSALS.SAME_INSTALLATION, anchor);
    const verdict = installationVerdict(record, bound.pluginRoot);
    if (!verdict.adoptable) return reanchorRefusal(verdict.reason, anchor);
    installation = { rebind: true, recorded: verdict.recorded, executing: verdict.executing };
  }
  const current = workflowDocument(recordedRoot, options.sessionId);
  if (current.state !== 'present') return reanchorRefusal(REFUSALS.WORKFLOW_STATE, anchor);
  const open = openWork(current.document);
  if (open && options.discardOpenWork !== true) return reanchorRefusal(REANCHOR_REFUSALS.WORKFLOW_IN_PROGRESS, { ...anchor, openWork: open });
  const next = workflowDocument(target, options.sessionId);
  if (next.state === 'unusable') return reanchorRefusal(REANCHOR_REFUSALS.TARGET_WORKFLOW_STATE, anchor);
  return {
    reanchorable: true,
    reanchored: false,
    recordsDir: bound.recordsDir,
    controlRoot: bound.controlRoot,
    pluginRoot: bound.pluginRoot,
    fromPluginRoot: record.plugin_root,
    recordedRoot,
    target,
    installation,
    openWork: open,
    targetDocument: next.state,
    targetOpenWork: next.state === 'present' ? openWork(next.document) : '',
  };
}

function discardedWorkflow(state) {
  return {
    ...state,
    active: false,
    implComplete: false,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    workflowActive: false,
    workflowTools: [],
    reviewRound: 0,
    stopBlocks: 0,
    phase: 'UNINITIALIZED',
    step_id: '',
  };
}

function appendReanchorHistory(projectRoot, sessionId, entry, discardOpenWork) {
  let discarded = '';
  try {
    core.mutateWorkflowState({
      projectRoot,
      sessionId,
      workflowState: 'project_root_reanchored',
      event: 'project-root-reanchored',
    }, (state) => {
      discarded = discardOpenWork ? openWork(state) : '';
      const next = discarded ? discardedWorkflow(state) : state;
      next.history = [
        ...(Array.isArray(state.history) ? state.history : []),
        discarded ? { ...entry, reason: `${entry.reason}; open work discarded: ${discarded}` } : entry,
      ];
      return next;
    });
    return { recorded: true, discarded };
  } catch {
    return { recorded: false, discarded: '' };
  }
}

function stampOf(milliseconds) {
  return new Date(milliseconds).toISOString().replace(/[^0-9TZ]/g, '');
}

function reanchorForHook(options) {
  const verdict = reanchorVerdict(options);
  if (!verdict.reanchorable) return verdict;
  const now = Date.now();
  let locked = verdict;
  let swapped;
  try {
    swapped = core.reanchorContext({
      recordsDir: verdict.recordsDir,
      pluginData: verdict.controlRoot,
      host: 'codex',
      sessionId: options.sessionId,
      fromProjectRoot: verdict.recordedRoot,
      fromPluginRoot: verdict.fromPluginRoot,
      projectRoot: verdict.target,
      pluginRoot: verdict.pluginRoot,
      stamp: stampOf(now),
      prepare: () => {
        const fresh = reanchorVerdict(options);
        if (!fresh.reanchorable) throw Object.assign(new Error(fresh.reason), { verdict: fresh });
        if (fresh.recordedRoot !== verdict.recordedRoot || fresh.target !== verdict.target || fresh.fromPluginRoot !== verdict.fromPluginRoot) {
          throw new Error('the re-anchor verdict changed while the move was being prepared');
        }
        if (fresh.targetDocument === 'missing') core.initializeWorkflowState({ projectRoot: fresh.target, sessionId: options.sessionId });
        locked = fresh;
      },
    });
  } catch (error) {
    if (error.verdict) return error.verdict;
    throw error;
  }
  const ts = new Date(now).toISOString();
  const entry = { step: '', phase: REANCHOR_PHASE, ts, reason: `project-root-reanchored: ${locked.recordedRoot} -> ${locked.target}` };
  const target = appendReanchorHistory(locked.target, options.sessionId, entry, false);
  const previous = appendReanchorHistory(locked.recordedRoot, options.sessionId, entry, options.discardOpenWork === true);
  const context = servedContext(locked.recordsDir, options.sessionId);
  return {
    reanchorable: true,
    reanchored: true,
    verified: Boolean(context) && context.project_root === locked.target && context.plugin_root === locked.pluginRoot,
    previousRoot: locked.recordedRoot,
    projectRoot: locked.target,
    supersededFile: swapped.supersededFile,
    installation: locked.installation,
    openWork: locked.openWork,
    discarded: previous.discarded,
    discardFailed: Boolean(locked.openWork) && !previous.recorded,
    targetDocument: locked.targetDocument === 'missing' ? 'created' : 'kept',
    targetOpenWork: locked.targetOpenWork,
    historyRecorded: target.recorded && previous.recorded,
  };
}

function reanchorRequest(prompt) {
  if (typeof prompt !== 'string' || prompt.length > MAX_DIRECTIVE_LENGTH) return null;
  const words = prompt.trim().toLowerCase().split(/\s+/);
  if (words.length < 2 || words.length > 3 || words[0] !== 'zensu' || !['reanchor', 're-anchor'].includes(words[1])) return null;
  if (words.length === 2) return { discardOpenWork: false };
  return words[2] === DISCARD_OPEN_WORK ? { discardOpenWork: true } : null;
}

function refusalText(verdict) {
  return REFUSAL_TEXT[verdict.reason] || null;
}

function reanchorRefusalText(verdict) {
  return REANCHOR_REFUSAL_TEXT[verdict.reason] || REFUSAL_TEXT[verdict.reason] || 'the re-anchor verdict is unavailable';
}

function adoptionNotice(verdict) {
  if (verdict.adopted) {
    return `Zensu Session Control re-bound this chat from Zensu ${verdict.recorded} to the installed Zensu ${verdict.executing} after a plugin update; the Zensu workflow continues in this chat.`;
  }
  const text = refusalText(verdict);
  if (!text) return null;
  return `Zensu Session Control cannot re-bind this chat to the installed Zensu plugin: ${text}. Start a new chat to continue the Zensu workflow.`;
}

function reanchorNotice(outcome) {
  if (outcome.reanchored) {
    return [
      `Zensu Session Control re-anchored this chat from ${JSON.stringify(outcome.previousRoot)} to ${JSON.stringify(outcome.projectRoot)} on the user's request.`,
      outcome.installation.rebind ? `It also re-bound the chat from Zensu ${outcome.installation.recorded} to the installed Zensu ${outcome.installation.executing}.` : '',
      'Every other field of its record is unchanged, and the previous record is kept beside it.',
      outcome.targetDocument === 'created'
        ? 'This chat starts with a fresh, inactive workflow state in the new worktree;'
        : `This chat keeps the workflow state it already had in the new worktree${outcome.targetOpenWork ? `, which still holds open work (${outcome.targetOpenWork})` : ''};`,
      outcome.discarded
        ? `its open work under the previous root (${outcome.discarded}) was abandoned at the user's request.`
        : outcome.discardFailed
          ? `its open work under the previous root (${outcome.openWork}) could not be closed, because that workflow state could not be written, so it still holds that work.`
          : 'its workflow state under the previous root stays there.',
      outcome.historyRecorded ? '' : 'Warning: the move is complete, but its history entry could not be written into every workflow state.',
      outcome.verified ? '' : 'Warning: reading the record back after the move did not show the new worktree and the executing installation; send the message again to check the anchor.',
      'Zensu gates, the stable reader and the zensu-log.sh verbs use the new worktree from the next tool call on. Tell the user that the chat is re-anchored.',
    ].filter(Boolean).join(' ');
  }
  const head = `Zensu Session Control did not re-anchor this chat: ${reanchorRefusalText(outcome)}`;
  if (outcome.reason === REANCHOR_REFUSALS.ALREADY_ANCHORED) return `${head}. Nothing was changed, and nothing needs to move.`;
  if (outcome.reason === REANCHOR_REFUSALS.WORKFLOW_IN_PROGRESS) {
    return `${head} (${outcome.openWork}), whose evidence is bound to that tree. Nothing was changed. Only the user can move the anchor anyway, by sending the message \`${REANCHOR_DIRECTIVE} ${DISCARD_OPEN_WORK}\` on its own, which abandons that work; otherwise start a new chat in this directory. Tell the user this.`;
  }
  return `${head}. Nothing was changed. Start a new chat in this directory to continue the Zensu workflow. Tell the user this.`;
}

function movedNotice(options, anchoredRoot) {
  const cwd = directoryOrNull(options.cwd);
  if (cwd !== null && cwd === anchoredRoot) return null;
  const verdict = reanchorVerdict({ ...options, discardOpenWork: false });
  if (verdict.reason === REANCHOR_REFUSALS.ALREADY_ANCHORED) return null;
  const where = `Zensu Session Control: this chat now works in ${JSON.stringify(options.cwd)}, but Session Control is anchored to ${JSON.stringify(anchoredRoot)}, so Zensu denies every tool call here.`;
  if (verdict.reanchorable) {
    return `${where} That directory is in another worktree of the same repository. Only the user can move the anchor there, by sending the message \`${REANCHOR_DIRECTIVE}\` on its own. Tell the user this and do not work around it.`;
  }
  if (verdict.reason === REANCHOR_REFUSALS.WORKFLOW_IN_PROGRESS) {
    return `${where} The anchor cannot move there because ${reanchorRefusalText(verdict)} (${verdict.openWork}). Only the user can move it anyway, by sending the message \`${REANCHOR_DIRECTIVE} ${DISCARD_OPEN_WORK}\` on its own, which abandons that work; otherwise start a new chat in this directory. Tell the user this and do not work around it.`;
  }
  return `${where} The anchor cannot move there because ${reanchorRefusalText(verdict)}. Start a new chat in this directory to continue the Zensu workflow. Tell the user this.`;
}

function promptNotice(options) {
  const verdict = adoptForHook(options);
  if (verdict.reason === REFUSALS.ALREADY_SERVED) return movedNotice(options, verdict.context.project_root);
  if (verdict.reason === REFUSALS.FOREIGN_PROJECT) {
    const bound = boundRecord(options);
    if (bound.record) return movedNotice(options, bound.record.project_root);
  }
  return adoptionNotice(verdict);
}

function directiveNotice(options) {
  const outcome = reanchorForHook(options);
  if (outcome.reason !== REANCHOR_REFUSALS.ALREADY_ANCHORED) return reanchorNotice(outcome);
  return [reanchorNotice(outcome), promptNotice(options)].filter(Boolean).join(' ');
}

function anchorReport(options) {
  let bound;
  try {
    bound = boundRecord(options);
  } catch {
    bound = {};
  }
  if (!bound.record) return 'Its Session Control record could not be read back, so whether the anchor moved is unknown.';
  const anchored = JSON.stringify(bound.record.project_root);
  return bound.record.project_root === directoryOrNull(options.cwd)
    ? `Its Session Control record names ${anchored} as the project root.`
    : `Its Session Control record still names ${anchored} as the project root.`;
}

function reanchorFailureNotice(options, error) {
  return `Zensu Session Control could not re-anchor this chat: ${String(error.message).replace(/\.$/, '')}. ${anchorReport(options)} Sending the message again retries the move; otherwise start a new chat in this directory. Tell the user this.`;
}

function outsideAnchorNotice(options) {
  const bound = boundRecord(options);
  return bound.record ? movedNotice(options, bound.record.project_root) : null;
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
  const outside = argv.length === 1 && argv[0] === '--outside-anchor';
  if (argv.length > 0 && !quiet && !outside) return;
  const payload = readPayload(quiet || outside ? QUIET_EVENTS : NOTICE_EVENTS);
  if (!payload) return;
  const options = { home: process.env.HOME, sessionId: payload.session_id, cwd: payload.cwd };
  if (quiet) {
    try {
      if (adoptForHook(options).reason === REFUSALS.FOREIGN_PROJECT) process.stdout.write(REANCHOR_HINT);
    } catch (error) {
      process.stderr.write(`zensu session-control re-bind failed: ${error.message}\n`);
    }
    return;
  }
  if (outside) {
    try {
      const notice = outsideAnchorNotice(options);
      if (notice) process.stdout.write(notice);
    } catch (error) {
      process.stderr.write(`zensu session-control anchor check failed: ${error.message}\n`);
    }
    return;
  }
  const request = reanchorRequest(payload.prompt);
  let notice;
  try {
    notice = request ? directiveNotice({ ...options, discardOpenWork: request.discardOpenWork }) : promptNotice(options);
  } catch (error) {
    process.stderr.write(`zensu session-control ${request ? 're-anchor' : 're-bind'} failed: ${error.message}\n`);
    if (!request) return;
    notice = reanchorFailureNotice(options, error);
  }
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

module.exports = {
  REFUSALS,
  REANCHOR_REFUSALS,
  REANCHOR_DIRECTIVE,
  REANCHOR_HINT,
  PROJECT_MISMATCH,
  adoptableRecord,
  adoptForHook,
  adoptionNotice,
  refusalText,
  projectMismatch,
  reanchorRequest,
  reanchorVerdict,
  reanchorForHook,
  reanchorNotice,
};
