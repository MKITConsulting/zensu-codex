#!/usr/bin/env node
'use strict';

const path = require('node:path');
const { execFileSync } = require('node:child_process');
const core = require('./session-control-core-v1.js');
const adoption = require('./codex-session-adopt-v1.js');
const { REANCHOR_DIRECTIVE, DISCARD_OPEN_WORK, reanchorRequest } = require('./codex-reanchor-directive-v1.js');

const GIT_TIMEOUT_MS = 2000;
const NOTICE_EVENTS = new Set(['UserPromptSubmit']);
const ANCHOR_EVENTS = new Set(['UserPromptSubmit', 'PreToolUse', 'Stop']);
const REANCHOR_PHASE = 'PROJECT_ROOT_REANCHORED';
const { REFUSALS } = adoption;

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
  GIT_UNAVAILABLE: 'git-unavailable',
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
  [REANCHOR_REFUSALS.GIT_UNAVAILABLE]: 'git did not answer about the anchored project root or the working directory of this chat (it is missing, timed out, or does not support `rev-parse --path-format` or `worktree list -z`)',
});

function directoryOrNull(value) {
  try {
    return adoption.canonicalDirectory(value, 'directory');
  } catch {
    return null;
  }
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function reanchorRefusal(reason, state = {}) {
  return { reanchorable: false, reanchored: false, reason, ...state };
}

function gitEnvironment() {
  const environment = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (!name.startsWith('GIT_')) environment[name] = value;
  }
  return { ...environment, LC_ALL: 'C', GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' };
}

function runGit(cwd, args, execGit = execFileSync) {
  let output;
  try {
    output = execGit('git', args, {
      cwd,
      encoding: 'utf8',
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: 4 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
      env: gitEnvironment(),
    });
  } catch (error) {
    return { output: null, unavailable: !error || error.status !== 128 };
  }
  return typeof output === 'string' ? { output, unavailable: false } : { output: null, unavailable: true };
}

function worktreeIdentity(directory, execGit) {
  const identity = { state: 'inside' };
  for (const [field, flag] of [['top', '--show-toplevel'], ['commonDir', '--git-common-dir']]) {
    const result = runGit(directory, ['rev-parse', '--path-format=absolute', flag], execGit);
    if (result.unavailable) return { state: 'unavailable' };
    const line = result.output === null ? '' : result.output.split(/\r?\n/)[0];
    if (line !== '' && !path.isAbsolute(line)) return { state: 'unavailable' };
    identity[field] = line === '' ? null : directoryOrNull(line);
    if (identity[field] === null) return { state: 'outside' };
  }
  return identity;
}

function registeredWorktrees(directory, execGit) {
  const listed = runGit(directory, ['worktree', 'list', '--porcelain', '-z'], execGit);
  if (listed.unavailable) return { state: 'unavailable' };
  const entries = [];
  let current = null;
  for (const field of (listed.output || '').split('\0')) {
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
  return { state: 'listed', entries: entries.map((entry) => ({ ...entry, canonical: directoryOrNull(entry.path) })) };
}

function reanchorVerdict(options) {
  const bound = adoption.boundRecord(options);
  if (bound.refusal) return reanchorRefusal(bound.refusal);
  const { record } = bound;
  const recordedRoot = directoryOrNull(record.project_root);
  if (recordedRoot === null) return reanchorRefusal(REANCHOR_REFUSALS.RECORDED_ROOT_MISSING);
  if (recordedRoot !== record.project_root) return reanchorRefusal(REFUSALS.RECORD_UNREADABLE);
  const anchor = { anchoredRoot: recordedRoot };
  const target = directoryOrNull(options.cwd);
  if (target === null) return reanchorRefusal(REANCHOR_REFUSALS.TARGET_MISSING, anchor);
  if (target === recordedRoot) return reanchorRefusal(REANCHOR_REFUSALS.ALREADY_ANCHORED, anchor);
  const recorded = worktreeIdentity(recordedRoot, options.execGit);
  if (recorded.state === 'unavailable') return reanchorRefusal(REANCHOR_REFUSALS.GIT_UNAVAILABLE, anchor);
  if (recorded.state === 'outside') return reanchorRefusal(REANCHOR_REFUSALS.RECORDED_ROOT_NOT_IN_WORKTREE, anchor);
  const moved = worktreeIdentity(target, options.execGit);
  if (moved.state === 'unavailable') return reanchorRefusal(REANCHOR_REFUSALS.GIT_UNAVAILABLE, anchor);
  if (moved.state === 'outside') return reanchorRefusal(REANCHOR_REFUSALS.TARGET_NOT_IN_WORKTREE, anchor);
  if (moved.commonDir !== recorded.commonDir) return reanchorRefusal(REANCHOR_REFUSALS.DIFFERENT_REPOSITORY, anchor);
  const listed = registeredWorktrees(recorded.top, options.execGit);
  if (listed.state === 'unavailable') return reanchorRefusal(REANCHOR_REFUSALS.GIT_UNAVAILABLE, anchor);
  const worktrees = listed.entries;
  const entry = worktrees.find((worktree) => worktree.canonical === moved.top);
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
    const verdict = adoption.installationVerdict(record, bound.pluginRoot);
    if (!verdict.adoptable) return reanchorRefusal(verdict.reason, anchor);
    installation = { rebind: true, recorded: verdict.recorded, executing: verdict.executing };
  }
  const current = core.inspectWorkflowState({ projectRoot: recordedRoot, sessionId: options.sessionId });
  if (current.state !== 'present') return reanchorRefusal(REFUSALS.WORKFLOW_STATE, anchor);
  const open = core.describeOpenWork(current.document);
  if (open && options.discardOpenWork !== true) return reanchorRefusal(REANCHOR_REFUSALS.WORKFLOW_IN_PROGRESS, { ...anchor, openWork: open });
  const next = core.inspectWorkflowState({ projectRoot: target, sessionId: options.sessionId });
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
    targetOpenWork: next.state === 'present' ? core.describeOpenWork(next.document) : '',
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
      discarded = discardOpenWork ? core.describeOpenWork(state) : '';
      const next = discarded ? core.discardOpenWork(state) : state;
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
  const context = adoption.servedContext(locked.recordsDir, options.sessionId);
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

function reanchorRefusalText(verdict) {
  return REANCHOR_REFUSAL_TEXT[verdict.reason] || adoption.refusalText(verdict) || 'the re-anchor verdict is unavailable';
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
  if (outcome.reason === REANCHOR_REFUSALS.GIT_UNAVAILABLE) {
    return `${head}. Nothing was changed. Once git answers, sending the message again retries the move; otherwise start a new chat in this directory. Tell the user this.`;
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
  if (verdict.reason === REANCHOR_REFUSALS.GIT_UNAVAILABLE) {
    return `${where} Whether the anchor can move there is unknown, because ${reanchorRefusalText(verdict)}. Once git answers, only the user can move it there, by sending the message \`${REANCHOR_DIRECTIVE}\` on its own; otherwise start a new chat in this directory. Tell the user this and do not work around it.`;
  }
  return `${where} The anchor cannot move there because ${reanchorRefusalText(verdict)}. Start a new chat in this directory to continue the Zensu workflow. Tell the user this.`;
}

function promptNotice(options) {
  const verdict = adoption.adoptForHook(options);
  if (verdict.reason === REFUSALS.ALREADY_SERVED) return movedNotice(options, verdict.context.project_root);
  if (verdict.reason === REFUSALS.FOREIGN_PROJECT) {
    const bound = adoption.boundRecord(options);
    if (bound.record) return movedNotice(options, bound.record.project_root);
  }
  return adoption.adoptionNotice(verdict);
}

function directiveNotice(options) {
  const outcome = reanchorForHook(options);
  if (outcome.reason !== REANCHOR_REFUSALS.ALREADY_ANCHORED) return reanchorNotice(outcome);
  return [reanchorNotice(outcome), promptNotice(options)].filter(Boolean).join(' ');
}

function anchorReport(options) {
  let bound;
  try {
    bound = adoption.boundRecord(options);
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
  const bound = adoption.boundRecord(options);
  return bound.record ? movedNotice(options, bound.record.project_root) : null;
}

function main(argv) {
  const outside = argv.length === 1 && argv[0] === '--outside-anchor';
  if (argv.length > 0 && !outside) return;
  const payload = adoption.readPayload(outside ? ANCHOR_EVENTS : NOTICE_EVENTS);
  if (!payload) return;
  const options = { home: process.env.HOME, sessionId: payload.session_id, cwd: payload.cwd };
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

module.exports = {
  REANCHOR_REFUSALS,
  reanchorVerdict,
  reanchorForHook,
  reanchorNotice,
  promptNotice,
  outsideAnchorNotice,
};

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`zensu session-control re-bind failed: ${error.message}\n`);
  }
}
