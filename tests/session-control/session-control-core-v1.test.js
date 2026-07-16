#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const corePath = process.env.SESSION_CONTROL_CORE;
assert.ok(corePath, 'SESSION_CONTROL_CORE must identify the host copy under test');
const core = require(path.resolve(corePath));

const RAW_SESSION = 'session/raw id with spaces';
const CREATED_AT = '2026-07-15T20:16:00.000Z';
const AMBIENT_GIT_SHA = 'a'.repeat(40);
const WINDOWS = process.platform === 'win32';
const WINDOWS_SYMLINK_SKIP = WINDOWS
  ? 'Windows runners do not guarantee unprivileged symbolic-link creation'
  : false;

function fixture(host = 'codex') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-session-control-'));
  const projectRoot = path.join(root, 'project');
  const pluginRoot = path.join(root, 'plugin');
  const pluginData = path.join(root, 'plugin-data');
  const recordsDir = path.join(pluginData, 'session-control', host, 'v1', 'records');
  fs.mkdirSync(projectRoot, { recursive: true });
  fs.mkdirSync(pluginRoot, { recursive: true });
  fs.mkdirSync(pluginData, { recursive: true });
  const manifestDir = host === 'codex' ? '.codex-plugin' : '.claude-plugin';
  fs.mkdirSync(path.join(pluginRoot, manifestDir), { recursive: true });
  fs.writeFileSync(
    path.join(pluginRoot, manifestDir, 'plugin.json'),
    JSON.stringify({ name: 'zensu', version: '9.8.7' }),
  );
  fs.mkdirSync(path.join(pluginRoot, 'hooks', 'lib'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'hooks', 'lib', 'runtime.js'), 'module.exports = 1;\n');
  fs.mkdirSync(path.join(pluginRoot, 'agents'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'agents', 'reviewer.md'), '# reviewer\n');
  fs.mkdirSync(path.join(pluginRoot, 'skills', 'sample'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'skills', 'sample', 'SKILL.md'), '# skill\n');
  fs.mkdirSync(path.join(pluginRoot, 'docs'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'docs', 'runtime-guide.md'), '# runtime guide\n');
  fs.mkdirSync(path.join(pluginRoot, 'templates'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'templates', 'review.md'), '# review template\n');
  fs.writeFileSync(path.join(pluginRoot, 'README.md'), '# plugin readme\n');
  fs.writeFileSync(path.join(pluginRoot, 'CHANGELOG.md'), '# plugin changelog\n');
  fs.writeFileSync(path.join(pluginRoot, 'LICENSE'), 'test license\n');
  return { root, projectRoot, pluginRoot, pluginData, recordsDir, host };
}

function register(f, overrides = {}) {
  return core.registerContext({
    recordsDir: f.recordsDir,
    host: f.host,
    sessionId: RAW_SESSION,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    pluginData: f.pluginData,
    createdAt: CREATED_AT,
    ...overrides,
  });
}

function initialize(f, sessionId = RAW_SESSION) {
  return core.initializeWorkflowState({ projectRoot: f.projectRoot, sessionId });
}

function runNode(source, args = []) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['-e', source, ...args], {
      env: { ...process.env, SESSION_CONTROL_CORE: path.resolve(corePath) },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

test('exports the versioned schemas', () => {
  assert.equal(core.SCHEMA, 'zensu.session-control');
  assert.equal(core.SCHEMA_VERSION, 1);
  assert.equal(core.WORKFLOW_SCHEMA, 'zensu.workflow-state');
});

test('hashes session identifiers with a domain-separated SHA-256 value', () => {
  const hash = core.sessionIdHash(RAW_SESSION);
  assert.match(hash, /^sha256:[a-f0-9]{64}$/);
  assert.equal(hash, core.sessionIdHash(RAW_SESSION));
  assert.notEqual(hash, `sha256:${require('node:crypto').createHash('sha256').update(RAW_SESSION).digest('hex')}`);
});

test('creates a filesystem-safe key without exposing the raw session identifier', () => {
  const key = core.sessionKey(RAW_SESSION);
  assert.match(key, /^scv1_[a-f0-9]{64}$/);
  assert.ok(!key.includes('session'));
  assert.equal(core.sessionKey(key), key);
});

test('rejects empty session identifiers', () => {
  assert.throws(() => core.sessionIdHash(''), /session/i);
  assert.throws(() => core.sessionIdHash('   '), /session/i);
});

test('computes a deterministic runtime digest over runtime assets', () => {
  const f = fixture();
  const first = core.computeRuntimeDigest(f.pluginRoot, f.host);
  const second = core.computeRuntimeDigest(f.pluginRoot, f.host);
  assert.match(first, /^sha256:[a-f0-9]{64}$/);
  assert.equal(first, second);
});

test('runtime digest changes when a runtime asset changes', () => {
  const f = fixture();
  const before = core.computeRuntimeDigest(f.pluginRoot, f.host);
  fs.appendFileSync(path.join(f.pluginRoot, 'hooks', 'lib', 'runtime.js'), '// changed\n');
  assert.notEqual(core.computeRuntimeDigest(f.pluginRoot, f.host), before);
});

test('runtime digest binds skill-read documentation', () => {
  const f = fixture();
  const before = core.computeRuntimeDigest(f.pluginRoot, f.host);
  fs.appendFileSync(path.join(f.pluginRoot, 'docs', 'runtime-guide.md'), 'changed\n');
  assert.notEqual(core.computeRuntimeDigest(f.pluginRoot, f.host), before);
});

test('runtime digest binds skill-read templates', () => {
  const f = fixture();
  const before = core.computeRuntimeDigest(f.pluginRoot, f.host);
  fs.appendFileSync(path.join(f.pluginRoot, 'templates', 'review.md'), 'changed\n');
  assert.notEqual(core.computeRuntimeDigest(f.pluginRoot, f.host), before);
});

test('runtime digest binds every top-level help source', () => {
  const f = fixture();
  let before = core.computeRuntimeDigest(f.pluginRoot, f.host);
  for (const file of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
    fs.appendFileSync(path.join(f.pluginRoot, file), `${file} changed\n`);
    const after = core.computeRuntimeDigest(f.pluginRoot, f.host);
    assert.notEqual(after, before, `${file} must be runtime-bound`);
    before = after;
  }
});

test('runtime digest rejects symlinks below runtime roots', { skip: WINDOWS_SYMLINK_SKIP }, () => {
  const f = fixture();
  fs.symlinkSync(path.join(f.pluginRoot, 'README-target'), path.join(f.pluginRoot, 'hooks', 'linked'));
  assert.throws(() => core.computeRuntimeDigest(f.pluginRoot, f.host), /symlink/i);
});

test('fails closed when a regular runtime file changes during descriptor-backed read', () => {
  const f = fixture();
  const target = fs.realpathSync.native(path.join(f.pluginRoot, 'hooks', 'lib', 'runtime.js'));
  const originalOpen = fs.openSync;
  const originalRead = fs.readSync;
  let targetDescriptor = null;
  let raced = false;
  fs.openSync = function patchedOpen(file, flags, ...rest) {
    const descriptor = originalOpen.call(fs, file, flags, ...rest);
    if (path.resolve(String(file)) === path.resolve(target) && typeof flags === 'number') {
      targetDescriptor = descriptor;
    }
    return descriptor;
  };
  fs.readSync = function patchedRead(descriptor, ...args) {
    if (descriptor === targetDescriptor && !raced) {
      raced = true;
      const writer = originalOpen.call(fs, target, 'a');
      try {
        fs.writeSync(writer, '// raced\n');
      } finally {
        fs.closeSync(writer);
      }
    }
    return originalRead.call(fs, descriptor, ...args);
  };
  try {
    assert.throws(() => core.computeRuntimeDigest(f.pluginRoot, f.host), /changed.*read|changed.*digest/i);
    assert.equal(raced, true);
  } finally {
    fs.openSync = originalOpen;
    fs.readSync = originalRead;
  }
});

test('runtime digest requires the host-specific manifest', () => {
  const f = fixture('codex');
  assert.throws(() => core.computeRuntimeDigest(f.pluginRoot, 'claude'), /manifest/i);
});

test('Claude runtime digest includes manifest-activated MCP config and launchers', () => {
  const f = fixture('claude');
  const manifestFile = path.join(f.pluginRoot, '.claude-plugin', 'plugin.json');
  fs.writeFileSync(manifestFile, JSON.stringify({ name: 'zensu', version: '9.8.7', mcpServers: './.mcp.json' }));
  fs.writeFileSync(path.join(f.pluginRoot, '.mcp.json'), JSON.stringify({
    mcpServers: { example: { command: '${CLAUDE_PLUGIN_ROOT}/scripts/example.sh' } },
  }));
  fs.mkdirSync(path.join(f.pluginRoot, 'scripts'));
  fs.writeFileSync(path.join(f.pluginRoot, 'scripts', 'example.sh'), '#!/bin/sh\nexit 0\n');
  const before = core.computeRuntimeDigest(f.pluginRoot, 'claude');
  fs.appendFileSync(path.join(f.pluginRoot, '.mcp.json'), '\n');
  const afterConfig = core.computeRuntimeDigest(f.pluginRoot, 'claude');
  assert.notEqual(afterConfig, before);
  fs.appendFileSync(path.join(f.pluginRoot, 'scripts', 'example.sh'), '# changed\n');
  assert.notEqual(core.computeRuntimeDigest(f.pluginRoot, 'claude'), afterConfig);
});

test('builds an immutable context with canonical roots and profiles', () => {
  const f = fixture();
  const context = core.buildContext({
    host: f.host,
    sessionId: RAW_SESSION,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    pluginData: f.pluginData,
    createdAt: CREATED_AT,
  });
  assert.equal(context.schema, core.SCHEMA);
  assert.equal(context.schema_version, 1);
  assert.equal(context.host, 'codex');
  assert.equal(context.session_id_hash, core.sessionIdHash(RAW_SESSION));
  assert.equal(context.project_root, fs.realpathSync.native(f.projectRoot));
  assert.equal(context.plugin_root, fs.realpathSync.native(f.pluginRoot));
  assert.equal(context.plugin_version, '9.8.7');
  assert.equal(context.principal_profiles.main, 'main-v1');
  assert.equal(context.principal_profiles.reviewer, 'reviewer-readonly-v1');
  assert.equal(context.principal_profiles.host, 'host-profile-v1');
  assert.equal(context.created_at, CREATED_AT);
  assert.equal(context.source_revision, context.runtime_digest);
  assert.notEqual(context.source_revision, 'unknown');
});

test('rejects every source revision override, including the retired authority pair', () => {
  const f = fixture();
  const options = {
    host: f.host,
    sessionId: RAW_SESSION,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    pluginData: f.pluginData,
    createdAt: CREATED_AT,
  };
  const contentDigest = core.computeRuntimeDigest(f.pluginRoot, f.host);
  for (const override of [
    { sourceRevision: AMBIENT_GIT_SHA },
    { sourceRevision: AMBIENT_GIT_SHA, sourceRevisionAuthority: 'verified-runtime-provenance-v1' },
    { sourceRevisionAuthority: 'verified-runtime-provenance-v1' },
    { sourceRevision: contentDigest },
    { sourceRevision: 'not-a-revision' },
  ]) {
    assert.throws(() => core.buildContext({ ...options, ...override }), /overrides are unsupported/i);
  }
});

test('rejects unsupported hosts', () => {
  const f = fixture();
  assert.throws(() => core.buildContext({ ...f, sessionId: RAW_SESSION, host: 'kiro' }), /host/i);
});

test('registers one private immutable record per session', () => {
  const f = fixture();
  const context = register(f);
  const record = path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`);
  assert.deepEqual(JSON.parse(fs.readFileSync(record, 'utf8')), context);
});

test('never replaces a planted immutable-record symlink', {
  skip: WINDOWS_SYMLINK_SKIP,
}, () => {
  const f = fixture();
  fs.mkdirSync(f.recordsDir, { recursive: true });
  const record = path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`);
  const missing = path.join(f.root, 'missing-record-target');
  fs.symlinkSync(missing, record);
  assert.throws(() => register(f), /immutable record already exists|EEXIST/);
  assert.equal(fs.lstatSync(record).isSymbolicLink(), true);
  assert.equal(fs.existsSync(missing), false);
});

test('registers a POSIX-private immutable record', {
  skip: WINDOWS ? 'Windows ACLs do not expose POSIX 0600 semantics' : false,
}, () => {
  const f = fixture();
  register(f);
  const record = path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`);
  assert.equal(fs.statSync(record).mode & 0o777, 0o600);
});

test('never persists the raw host session identifier', () => {
  const f = fixture();
  register(f);
  const persisted = fs.readFileSync(path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`), 'utf8');
  assert.ok(!persisted.includes(RAW_SESSION));
});

test('reuses an identical immutable record idempotently', () => {
  const f = fixture();
  const first = register(f);
  const second = register(f, { createdAt: '2099-01-01T00:00:00.000Z' });
  assert.deepEqual(second, first);
});

test('registers one immutable record under true multi-process contention', async () => {
  const f = fixture();
  const options = {
    recordsDir: f.recordsDir,
    host: f.host,
    sessionId: RAW_SESSION,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    pluginData: f.pluginData,
    createdAt: CREATED_AT,
  };
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.registerContext(JSON.parse(process.argv[1]));';
  const results = await Promise.all(Array.from({ length: 12 }, () => runNode(source, [JSON.stringify(options)])));
  for (const result of results) assert.equal(result.code, 0, result.stderr);
  const records = fs.readdirSync(f.recordsDir).filter((entry) => entry.endsWith('.json'));
  assert.deepEqual(records, [`${core.sessionKey(RAW_SESSION)}.json`]);
  const resolved = core.readContext({
    recordsDir: f.recordsDir,
    sessionId: RAW_SESSION,
    expectedHost: f.host,
  });
  assert.equal(resolved.source_revision, resolved.runtime_digest);
});

test('recovers valid dead lock and recovery generations immediately', () => {
  const f = fixture();
  const locks = path.join(f.pluginData, 'session-control', f.host, 'v1', 'locks');
  fs.mkdirSync(locks, { recursive: true });
  const key = core.sessionKey(RAW_SESSION);
  const staleOwner = JSON.stringify({ pid: 2147483647, token: 'a'.repeat(48), created_at: CREATED_AT });
  for (const suffix of ['lock', 'recovery']) {
    const file = path.join(locks, `.${key}.${suffix}`);
    fs.writeFileSync(file, staleOwner, { mode: 0o600 });
  }
  const context = register(f);
  assert.equal(context.source_revision, context.runtime_digest);
  assert.equal(fs.existsSync(path.join(locks, `.${key}.lock`)), false);
  assert.equal(fs.existsSync(path.join(locks, `.${key}.recovery`)), false);
});

test('never reclaims an old lock whose owner process is still alive', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-live-lock-'));
  const lockFile = path.join(root, '.liveowner.lock');
  const owner = { pid: process.pid, token: 'b'.repeat(48), created_at: CREATED_AT };
  fs.writeFileSync(lockFile, JSON.stringify(owner), { mode: 0o600 });
  const stale = new Date(Date.now() - 60000);
  fs.utimesSync(lockFile, stale, stale);
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.withFileLock(process.argv[1],"liveowner",()=>{});';
  const child = spawn(process.execPath, ['-e', source, root], {
    env: { ...process.env, SESSION_CONTROL_CORE: path.resolve(corePath) },
    stdio: 'ignore',
  });
  let exited = false;
  const closed = new Promise((resolve) => child.on('close', (code, signal) => {
    exited = true;
    resolve({ code, signal });
  }));
  await new Promise((resolve) => setTimeout(resolve, 250));
  assert.equal(exited, false);
  assert.deepEqual(JSON.parse(fs.readFileSync(lockFile, 'utf8')), owner);
  child.kill('SIGTERM');
  await closed;
  fs.unlinkSync(lockFile);
});

test('recovers a lock left at a SIGKILL kill point', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lock-kill-'));
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.withFileLock(process.argv[1],"killpoint",()=>process.kill(process.pid,"SIGKILL"));';
  const killed = await runNode(source, [root]);
  assert.notEqual(killed.code, 0);
  const lockFile = path.join(root, '.killpoint.lock');
  assert.equal(fs.existsSync(lockFile), true);
  assert.equal(core.withFileLock(root, 'killpoint', () => 'recovered'), 'recovered');
  assert.equal(fs.existsSync(lockFile), false);
});

test('uses process start identity to reject a live but PID-reused owner', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-pid-reuse-'));
  const probeFile = path.join(root, '.probe.lock');
  let actualIdentity = null;
  core.withFileLock(root, 'probe', () => {
    actualIdentity = JSON.parse(fs.readFileSync(probeFile, 'utf8')).process_start_identity;
  });
  if (!actualIdentity) {
    t.skip('this platform does not expose a portable process start identity');
    return;
  }
  const lockFile = path.join(root, '.pidreuse.lock');
  fs.writeFileSync(lockFile, JSON.stringify({
    pid: process.pid,
    token: 'c'.repeat(48),
    created_at: new Date().toISOString(),
    process_start_identity: 'mismatched-process-start',
  }), { mode: 0o600 });
  assert.equal(core.withFileLock(root, 'pidreuse', () => 'recovered'), 'recovered');
  assert.equal(fs.existsSync(lockFile), false);
});

test('keeps a fresh corrupt lock for the TTL instead of guessing its owner is dead', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-corrupt-lock-'));
  const lockFile = path.join(root, '.corrupt.lock');
  fs.writeFileSync(lockFile, '{broken', { mode: 0o600 });
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.withFileLock(process.argv[1],"corrupt",()=>{});';
  const child = spawn(process.execPath, ['-e', source, root], {
    env: { ...process.env, SESSION_CONTROL_CORE: path.resolve(corePath) },
    stdio: 'ignore',
  });
  let exited = false;
  const closed = new Promise((resolve) => child.on('close', (code, signal) => {
    exited = true;
    resolve({ code, signal });
  }));
  await new Promise((resolve) => setTimeout(resolve, 250));
  assert.equal(exited, false);
  assert.equal(fs.readFileSync(lockFile, 'utf8'), '{broken');
  child.kill('SIGTERM');
  await closed;
  fs.unlinkSync(lockFile);
});

test('never deletes a replacement that races lock release', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lock-replace-'));
  const canonicalRoot = fs.realpathSync.native(root);
  const lockFile = path.join(canonicalRoot, '.replacement.lock');
  const displaced = path.join(canonicalRoot, '.original.displaced');
  const replacement = {
    pid: process.pid,
    token: 'd'.repeat(48),
    created_at: new Date().toISOString(),
  };
  const originalRename = fs.renameSync;
  let injected = false;
  try {
    assert.throws(() => core.withFileLock(root, 'replacement', () => {
      fs.renameSync = function patchedRename(source, destination) {
        if (!injected && path.resolve(source) === path.resolve(lockFile)) {
          injected = true;
          originalRename.call(fs, source, displaced);
          fs.writeFileSync(source, JSON.stringify(replacement), { mode: 0o600 });
        }
        return originalRename.call(fs, source, destination);
      };
    }), /identity changed|ownership changed/i);
    assert.equal(injected, true);
    assert.deepEqual(JSON.parse(fs.readFileSync(lockFile, 'utf8')), replacement);
  } finally {
    fs.renameSync = originalRename;
    if (fs.existsSync(lockFile)) fs.unlinkSync(lockFile);
    if (fs.existsSync(displaced)) fs.unlinkSync(displaced);
  }
});

test('fails closed when a session is rebound to another project', () => {
  const f = fixture();
  register(f);
  const otherProject = path.join(f.root, 'other-project');
  fs.mkdirSync(otherProject);
  assert.throws(() => register(f, { projectRoot: otherProject }), /immutable|mismatch|project/i);
});

test('fails closed when runtime assets drift inside an active session', () => {
  const f = fixture();
  register(f);
  fs.appendFileSync(path.join(f.pluginRoot, 'skills', 'sample', 'SKILL.md'), 'drift\n');
  assert.throws(() => register(f), /runtime|mismatch|immutable/i);
});

test('rejects arbitrary source provenance persisted in a context record', () => {
  const f = fixture();
  register(f);
  const record = path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`);
  const persisted = JSON.parse(fs.readFileSync(record, 'utf8'));
  for (const sourceRevision of [
    'arbitrary-ambient-value',
    AMBIENT_GIT_SHA,
    `sha256:${'0'.repeat(64)}`,
  ]) {
    persisted.source_revision = sourceRevision;
    fs.writeFileSync(record, `${JSON.stringify(persisted, null, 2)}\n`);
    assert.throws(() => core.readContext({
      recordsDir: f.recordsDir,
      sessionId: RAW_SESSION,
      expectedHost: f.host,
    }), /source revision/i);
  }
});

test('resolves and verifies a registered context', () => {
  const f = fixture('claude');
  register(f);
  const resolved = core.readContext({
    recordsDir: f.recordsDir,
    sessionId: RAW_SESSION,
    expectedHost: 'claude',
  });
  assert.equal(resolved.host, 'claude');
  assert.equal(resolved.plugin_root, fs.realpathSync.native(f.pluginRoot));
});

test('creates one complete project-bound workflow baseline at SessionStart', () => {
  const f = fixture();
  register(f);
  const baseline = initialize(f);
  assert.equal(baseline.schema, core.WORKFLOW_SCHEMA);
  assert.equal(baseline.revision, 1);
  assert.equal(baseline.workflow_state, 'idle');
  assert.deepEqual({
    active: baseline.active,
    vanilla: baseline.vanilla,
    implComplete: baseline.implComplete,
    chainDone: baseline.chainDone,
    codeReviewDone: baseline.codeReviewDone,
    selfReviewFixed: baseline.selfReviewFixed,
    workflowActive: baseline.workflowActive,
    workflowTools: baseline.workflowTools,
    bypasses: baseline.bypasses,
    reviewRound: baseline.reviewRound,
    stopBlocks: baseline.stopBlocks,
    phase: baseline.phase,
    step_id: baseline.step_id,
    history: baseline.history,
  }, {
    active: false,
    vanilla: false,
    implComplete: false,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    workflowActive: false,
    workflowTools: [],
    bypasses: [],
    reviewRound: 0,
    stopBlocks: 0,
    phase: 'UNINITIALIZED',
    step_id: '',
    history: [],
  });
  assert.ok(!JSON.stringify(baseline).includes(RAW_SESSION));
});

test('baseline initialization is idempotent and never resets an existing workflow', () => {
  const f = fixture();
  register(f);
  initialize(f);
  const active = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'active',
    event: 'tdd-begin',
  }, (state) => ({ ...state, active: true }));
  const repeated = initialize(f);
  assert.equal(repeated.revision, active.revision);
  assert.equal(repeated.active, true);
  assert.equal(fs.existsSync(path.join(f.pluginData, '.workflow-activations')), false);
});

test('resetReviewBudget re-arms the complete review budget in one CAS revision', () => {
  const f = fixture();
  initialize(f);
  const seeded = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review_exhausted',
    event: 'test-seed',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    reviewRound: 3,
    stopBlocks: 2,
    chainDone: true,
    codeReviewDone: true,
    selfReviewFixed: true,
  }));
  const reset = core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: seeded.revision,
  });
  assert.equal(reset.revision, seeded.revision + 1);
  assert.deepEqual({
    active: reset.active,
    implComplete: reset.implComplete,
    reviewRound: reset.reviewRound,
    stopBlocks: reset.stopBlocks,
    chainDone: reset.chainDone,
    codeReviewDone: reset.codeReviewDone,
    selfReviewFixed: reset.selfReviewFixed,
  }, {
    active: true,
    implComplete: true,
    reviewRound: 0,
    stopBlocks: 0,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
  });
});

test('resetReviewBudget stale revision and failed preconditions preserve exact state bytes', () => {
  for (const testCase of [
    { label: 'stale revision', active: true, implComplete: true, expectedRevision: 1, pattern: /stale workflow revision/i },
    { label: 'inactive workflow', active: false, implComplete: true, expectedRevision: 2, pattern: /active completed implementation/i },
    { label: 'incomplete implementation', active: true, implComplete: false, expectedRevision: 2, pattern: /active completed implementation/i },
  ]) {
    const f = fixture();
    initialize(f);
    core.mutateWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      workflowState: 'test_seed',
      event: 'test-seed',
      expectedRevision: 1,
    }, (state) => ({ ...state, active: testCase.active, implComplete: testCase.implComplete, reviewRound: 3 }));
    const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
    const before = fs.readFileSync(file);
    assert.throws(() => core.resetReviewBudget({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      expectedRevision: testCase.expectedRevision,
    }), testCase.pattern, testCase.label);
    assert.deepEqual(fs.readFileSync(file), before, `${testCase.label} must preserve exact bytes`);
  }
});

test('resetReviewBudget rejects invalid state without repair or byte changes', () => {
  const f = fixture();
  initialize(f);
  const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const state = JSON.parse(fs.readFileSync(file, 'utf8'));
  state.reviewRound = '3';
  fs.writeFileSync(file, `${JSON.stringify(state, null, 2)}\n`);
  const before = fs.readFileSync(file);
  assert.throws(() => core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: 1,
  }), /reviewRound|bounded non-negative integer/i);
  assert.deepEqual(fs.readFileSync(file), before);
});

test('fails closed for a missing context', () => {
  const f = fixture();
  assert.throws(() => core.readContext({ recordsDir: f.recordsDir, sessionId: RAW_SESSION }), /missing|not found/i);
});

test('renders main context without the raw session identifier', () => {
  const f = fixture();
  const rendered = core.renderMainContext(register(f));
  assert.match(rendered, /^\[zensu-session-context\]/);
  assert.match(rendered, /principal=main-v1/);
  assert.ok(!rendered.includes(RAW_SESSION));
});

test('renders an explicit reviewer read-only contract', () => {
  const f = fixture();
  const rendered = core.renderReviewerContext(register(f));
  assert.match(rendered, /reviewer-readonly-v1/);
  assert.match(rendered, /must not write, spawn, mutate workflow state, invoke mutating control or MCP tools, or impersonate main/i);
});

test('renders a neutral host profile without main or reviewer authority', () => {
  const f = fixture();
  const rendered = core.renderHostContext(register(f));
  assert.match(rendered, /^\[zensu-host-context\]/);
  assert.match(rendered, /principal=host-profile-v1/);
  assert.doesNotMatch(rendered, /principal=main-v1/);
  assert.doesNotMatch(rendered, /principal=reviewer-readonly-v1/);
});

test('increments workflow revision atomically on every mutation', () => {
  const f = fixture();
  register(f);
  initialize(f);
  const first = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'red-start',
    updatedAt: CREATED_AT,
  });
  const second = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'green',
    event: 'green-pass',
    expectedRevision: 2,
    updatedAt: CREATED_AT,
  });
  assert.equal(first.revision, 2);
  assert.equal(second.revision, 3);
  assert.equal(second.workflow_state, 'green');
});

test('strictly validates gate-relevant workflow extensions while preserving unknown extensions', () => {
  const valid = {
    active: true,
    vanilla: false,
    implComplete: false,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    workflowActive: true,
    phase: 'RED_FAIL',
    step_id: 'S1',
    history: [{ step: 'S1', phase: 'RED_FAIL', ts: CREATED_AT, reason: 'expected failure' }],
    workflowTools: ['link_test', 'create_revision'],
    bypasses: ['ZENSU_TDD_GATE'],
    future_extension: { nested: ['remains', 'accepted'] },
  };
  const stamped = core.stampWorkflowState(valid, RAW_SESSION, 'red_fail', 'phase-red_fail', CREATED_AT);
  assert.deepEqual(stamped.future_extension, valid.future_extension);

  const malformed = [
    ...['active', 'vanilla', 'implComplete', 'chainDone', 'codeReviewDone', 'selfReviewFixed', 'workflowActive']
      .map((field) => ({ [field]: 'false' })),
    { phase: [] },
    { phase: 'IMPL\nforged' },
    { step_id: 7 },
    { history: {} },
    { history: [null] },
    { history: [{}] },
    { history: [{ step: 1, phase: 'RED_FAIL' }] },
    { history: [{ step: 'S1', phase: false }] },
    { history: [{ step: 'S1', phase: 'RED_FAIL', ts: 'not-a-date' }] },
    { history: [{ step: 'S1', phase: 'RED_FAIL', reason: {} }] },
    { workflowTools: {} },
    { workflowTools: ['link_test', 7] },
    { workflowTools: ['link_test\nforged'] },
    { bypasses: 'ZENSU_TDD_GATE' },
    { bypasses: ['ZENSU_TDD_GATE', 7] },
  ];
  for (const extension of malformed) {
    assert.throws(
      () => core.stampWorkflowState(extension, RAW_SESSION, 'control', 'extension-check', CREATED_AT),
      /workflow/i,
    );
  }
});

test('keeps every reserved workflow field and revision under core ownership', () => {
  const f = fixture();
  initialize(f);
  core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'first',
    updatedAt: CREATED_AT,
  });
  const reset = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'green',
    event: 'reset_attempt',
    updatedAt: CREATED_AT,
  }, () => ({
    schema: 'attacker.schema',
    schema_version: 99,
    session_id: RAW_SESSION,
    session_id_hash: `sha256:${'0'.repeat(64)}`,
    workflow_state: 'attacker',
    revision: 0,
    last_event: 'attacker',
    updated_at: 'not-a-date',
    actor: 'reviewer-readonly-v1',
    extension: 'preserved',
  }));
  assert.equal(reset.revision, 3);
  assert.equal(reset.schema, core.WORKFLOW_SCHEMA);
  assert.equal(reset.schema_version, 1);
  assert.equal(reset.session_id_hash, core.sessionIdHash(RAW_SESSION));
  assert.equal(reset.workflow_state, 'green');
  assert.equal(reset.last_event, 'reset_attempt');
  assert.equal(reset.actor, 'main-v1');
  assert.equal(reset.session_id, undefined);
  assert.equal(reset.extension, 'preserved');

  const jump = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'jump_attempt',
    updatedAt: CREATED_AT,
  }, (state) => ({ ...state, revision: Number.MAX_SAFE_INTEGER }));
  assert.equal(jump.revision, 4);
});

test('fails closed instead of overflowing MAX_SAFE_INTEGER workflow revision', () => {
  const f = fixture();
  const stateDirectory = path.join(f.projectRoot, '.zensu', 'state');
  fs.mkdirSync(stateDirectory, { recursive: true });
  const file = path.join(stateDirectory, `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const maximum = core.stampWorkflowState(
    { revision: Number.MAX_SAFE_INTEGER - 1 },
    RAW_SESSION,
    'review',
    'maximum_revision',
    CREATED_AT,
  );
  assert.equal(maximum.revision, Number.MAX_SAFE_INTEGER);
  core.atomicWriteJson(file, maximum);
  assert.throws(() => core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'overflow_attempt',
    updatedAt: CREATED_AT,
  }), /overflow/i);
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).revision, Number.MAX_SAFE_INTEGER);
  assert.throws(() => core.stampWorkflowState(
    { revision: Number.MAX_SAFE_INTEGER },
    RAW_SESSION,
    'review',
    'overflow_attempt',
    CREATED_AT,
  ), /overflow/i);
});

test('serializes true concurrent workflow mutations without lost revisions', async () => {
  const f = fixture();
  initialize(f);
  const options = {
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'parallel_write',
  };
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.transitionWorkflowState(JSON.parse(process.argv[1]));';
  const results = await Promise.all(Array.from({ length: 16 }, () => runNode(source, [JSON.stringify(options)])));
  for (const result of results) assert.equal(result.code, 0, result.stderr);
  assert.equal(core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: RAW_SESSION }).revision, 17);
});

test('fails closed on corrupt workflow JSON instead of resetting revision', () => {
  const f = fixture();
  initialize(f);
  const stateDirectory = path.join(f.projectRoot, '.zensu', 'state');
  fs.mkdirSync(stateDirectory, { recursive: true });
  const file = path.join(stateDirectory, `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  fs.writeFileSync(file, '{broken');
  assert.throws(() => core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'must_not_reset',
  }), /invalid JSON/i);
  assert.equal(fs.readFileSync(file, 'utf8'), '{broken');
});

test('stamps host workflow objects with the same revision contract', () => {
  const first = core.stampWorkflowState(
    { session_id: RAW_SESSION, custom: true },
    RAW_SESSION,
    'red_write',
    'phase-red_write',
    CREATED_AT,
  );
  const second = core.stampWorkflowState(first, RAW_SESSION, 'red_fail', 'phase-red_fail', CREATED_AT);
  assert.equal(first.schema, core.WORKFLOW_SCHEMA);
  assert.equal(first.revision, 1);
  assert.equal(second.revision, 2);
  assert.equal(second.custom, true);
  assert.equal(second.session_id, undefined);
  assert.equal(second.session_id_hash, core.sessionIdHash(RAW_SESSION));
  assert.ok(!JSON.stringify(second).includes(RAW_SESSION));
});

test('denies workflow mutation by a reviewer principal', () => {
  const f = fixture();
  assert.throws(
    () => core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      workflowState: 'red',
      event: 'attack',
      actor: 'reviewer-readonly-v1',
    }),
    /reviewer|principal|denied/i,
  );
});

test('rejects stale workflow compare-and-swap revisions', () => {
  const f = fixture();
  initialize(f);
  core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'red-start',
  });
  assert.throws(
    () => core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      workflowState: 'green',
      event: 'stale',
      expectedRevision: 1,
    }),
    /revision|stale/i,
  );
});

test('isolates workflow state by hashed session key', () => {
  const f = fixture();
  initialize(f, 'one');
  initialize(f, 'two');
  core.transitionWorkflowState({ projectRoot: f.projectRoot, sessionId: 'one', workflowState: 'red', event: 'one' });
  core.transitionWorkflowState({ projectRoot: f.projectRoot, sessionId: 'two', workflowState: 'green', event: 'two' });
  assert.equal(core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: 'one' }).workflow_state, 'red');
  assert.equal(core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: 'two' }).workflow_state, 'green');
});

test('rejects a symlinked workflow state directory', { skip: WINDOWS_SYMLINK_SKIP }, () => {
  const f = fixture();
  const outside = path.join(f.root, 'outside');
  fs.mkdirSync(outside);
  fs.mkdirSync(path.join(f.projectRoot, '.zensu'));
  fs.symlinkSync(outside, path.join(f.projectRoot, '.zensu', 'state'));
  assert.throws(
    () => core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      workflowState: 'red',
      event: 'unsafe',
    }),
    /symlink/i,
  );
});

test('rejects every explicit workflow state directory override on every host', () => {
  const f = fixture();
  const outside = path.join(f.root, 'override-target');
  fs.mkdirSync(outside);
  // Overrides are rejected by API contract before the candidate path is ever
  // inspected, so this coverage is portable and must also run on Windows.
  for (const stateDirectory of [outside, '.zensu/state', path.join(f.root, 'missing-override')]) {
    assert.throws(() => core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      stateDirectory,
      sessionId: RAW_SESSION,
      workflowState: 'red',
      event: 'unsafe_override',
    }), /overrides are unsupported/i);
    assert.throws(() => core.readWorkflowState({
      projectRoot: f.projectRoot,
      stateDirectory,
      sessionId: RAW_SESSION,
    }), /overrides are unsupported/i);
  }
});

test('refuses workflow mutation when the SessionStart baseline is absent or deleted', () => {
  const f = fixture();
  assert.throws(() => core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'missing-baseline',
  }), /baseline is missing/i);
  initialize(f);
  const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  fs.unlinkSync(file);
  assert.throws(() => core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'deleted-baseline',
  }), /baseline is missing/i);
});

test('resets the complete review budget in one expected-revision CAS', () => {
  const f = fixture();
  initialize(f);
  const armed = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review_exhausted',
    event: 'seed-review-budget',
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    reviewRound: 4,
    stopBlocks: 7,
    chainDone: true,
    codeReviewDone: true,
    selfReviewFixed: true,
  }));
  const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const beforeStale = fs.readFileSync(file);
  assert.throws(() => core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: armed.revision - 1,
  }), /stale workflow revision/i);
  assert.deepEqual(fs.readFileSync(file), beforeStale);

  const reset = core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: armed.revision,
  });
  assert.equal(reset.revision, armed.revision + 1);
  assert.equal(reset.workflow_state, 'review_rearmed');
  assert.equal(reset.reviewRound, 0);
  assert.equal(reset.stopBlocks, 0);
  assert.equal(reset.chainDone, false);
  assert.equal(reset.codeReviewDone, false);
  assert.equal(reset.selfReviewFixed, false);

  const afterReset = fs.readFileSync(file);
  assert.throws(() => core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: armed.revision,
  }), /stale workflow revision/i);
  assert.deepEqual(fs.readFileSync(file), afterReset);
});

test('rejects review-budget reset precondition failure without changing bytes', () => {
  const f = fixture();
  initialize(f);
  const incomplete = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'active',
    event: 'seed-incomplete-workflow',
  }, (state) => ({ ...state, active: true, implComplete: false, reviewRound: 2 }));
  const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const before = fs.readFileSync(file);
  assert.throws(() => core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: incomplete.revision,
  }), /active completed implementation/i);
  assert.deepEqual(fs.readFileSync(file), before);
});

test('creates a schema-versioned trusted attestation', () => {
  const f = fixture();
  const context = register(f);
  initialize(f);
  const state = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'review-start',
    updatedAt: CREATED_AT,
  });
  const attestation = core.createAttestation({
    context,
    state,
    hookSequence: ['SessionStart', 'SubagentStart', 'PreToolUse'],
    reviewerCapabilities: 'reviewer-readonly-v1',
    changedFileHashes: { 'src/example.js': `sha256:${'d'.repeat(64)}` },
    cliVersion: 'test-cli',
    pluginVersion: context.plugin_version,
    exitCode: 0,
  });
  assert.equal(attestation.schema, 'zensu.control-attestation');
  assert.equal(attestation.schema_version, 1);
  assert.equal(attestation.session_id_hash, context.session_id_hash);
  assert.equal(attestation.resolved_plugin_root, context.plugin_root);
  assert.equal(attestation.runtime_digest, context.runtime_digest);
  assert.equal(attestation.workflow_state, 'review');
  assert.equal(attestation.revision, 2);
  assert.deepEqual(attestation.hook_sequence, ['SessionStart', 'SubagentStart', 'PreToolUse']);
  assert.equal(attestation.exit_code, 0);
  assert.equal(Object.keys(attestation).length, 15);
  assert.ok(!JSON.stringify(attestation).includes(RAW_SESSION));
});

test('rejects incomplete or context-divergent attestations', () => {
  const f = fixture();
  const context = register(f);
  initialize(f);
  const state = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'review_start',
  });
  const valid = {
    context,
    state,
    hookSequence: ['SessionStart'],
    reviewerCapabilities: 'reviewer-readonly-v1',
    changedFileHashes: {},
    cliVersion: 'test-cli',
    exitCode: 0,
  };
  assert.throws(() => core.createAttestation({ ...valid, hookSequence: [] }), /hookSequence/i);
  assert.throws(() => core.createAttestation({ ...valid, reviewerCapabilities: 'main-v1' }), /reviewerCapabilities/i);
  assert.throws(() => core.createAttestation({ ...valid, pluginVersion: 'other' }), /pluginVersion/i);
  assert.throws(() => core.createAttestation({ ...valid, sourceRevision: context.source_revision }), /sourceRevision/i);
  assert.throws(() => core.createAttestation({ ...valid, sourceRevision: 'other' }), /sourceRevision/i);
  assert.throws(() => core.createAttestation({
    ...valid,
    sourceRevisionAuthority: 'verified-runtime-provenance-v1',
  }), /sourceRevisionAuthority/i);
  assert.throws(() => core.createAttestation({
    ...valid,
    changedFileHashes: { bad: 'sha256:deadbeef' },
  }), /changed file hash/i);
});

test('preserves prototype-shaped changed filenames in trusted attestations', () => {
  const f = fixture();
  const context = register(f);
  const state = initialize(f);
  const changedFileHashes = Object.fromEntries([
    ['__proto__', `sha256:${'a'.repeat(64)}`],
    ['constructor', `sha256:${'b'.repeat(64)}`],
  ]);
  const attestation = core.createAttestation({
    context,
    state,
    hookSequence: ['SessionStart'],
    reviewerCapabilities: 'reviewer-readonly-v1',
    changedFileHashes,
    cliVersion: 'test-cli',
    exitCode: 0,
  });
  assert.equal(Object.prototype.hasOwnProperty.call(attestation.changed_file_hashes, '__proto__'), true);
  assert.equal(attestation.changed_file_hashes.__proto__, `sha256:${'a'.repeat(64)}`);
  assert.equal(attestation.changed_file_hashes.constructor, `sha256:${'b'.repeat(64)}`);
});

test('serializes concurrent workflow counter increments without lost updates', async () => {
  const f = fixture();
  const stateDirectory = path.join(f.projectRoot, '.zensu', 'state');
  initialize(f);
  core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'active',
    event: 'activate',
  }, (state) => ({ ...state, active: true, stopBlocks: 0 }));
  const increment = `
    const core = require(process.env.SESSION_CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.argv[1],
      sessionId: process.argv[2],
      workflowState: 'stop_guard',
      event: 'counter-stop_blocks',
    }, (state) => {
      state.stopBlocks = (state.stopBlocks || 0) + 1;
      return state;
    });
  `;
  const results = await Promise.all([
    runNode(increment, [f.projectRoot, RAW_SESSION]),
    runNode(increment, [f.projectRoot, RAW_SESSION]),
  ]);
  assert.deepEqual(results.map((result) => result.code), [0, 0]);
  const final = core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: RAW_SESSION });
  assert.equal(final.stopBlocks, 2);
  assert.equal(final.revision, 4);
});

test('rejects malformed or out-of-range workflow counters', () => {
  const f = fixture();
  const stateDirectory = path.join(f.projectRoot, '.zensu', 'state');
  initialize(f);
  core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'active',
    event: 'activate',
  }, (state) => ({ ...state, active: true, reviewRound: 0, stopBlocks: 0 }));
  const file = path.join(stateDirectory, `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const baseline = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const value of ['5', -1, 1000001, 1.5]) {
    fs.writeFileSync(file, `${JSON.stringify({ ...baseline, reviewRound: value })}\n`);
    assert.throws(
      () => core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: RAW_SESSION }),
      /reviewRound|bounded non-negative integer/i,
    );
  }
});

test('rejects multi-linked trusted runtime files', () => {
  const f = fixture();
  const manifest = path.join(f.pluginRoot, f.host === 'codex' ? '.codex-plugin' : '.claude-plugin', 'plugin.json');
  fs.linkSync(manifest, path.join(f.root, 'manifest-alias.json'));
  assert.throws(() => core.computeRuntimeDigest(f.pluginRoot, f.host), /multi-linked/i);
});
