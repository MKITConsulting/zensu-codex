#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { controlLine, sanitizeModelText } = require('./attestation-common.js');

const evalRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(evalRoot, '..', '..');
const pluginRoot = process.env.ZENSU_EXPECTED_PLUGIN_ROOT
  ? fs.realpathSync.native(process.env.ZENSU_EXPECTED_PLUGIN_ROOT)
  : path.join(repoRoot, 'plugins', 'zensu');
const core = require(path.join(pluginRoot, 'hooks', 'lib', 'session-control-core-v1.js'));
const policy = path.join(pluginRoot, 'hooks', 'lib', 'reviewer-capability-v1.js');
const { verifyReleaseIntegrity } = require('./release-integrity.js');

function parseEnvelope(prompt) {
  const first = String(prompt || '').split(/\r?\n/, 1)[0];
  const match = /^\[session-control-eval\] suite=([a-z]+) scenario=([a-z0-9-]+)(?: attack=([a-z-]+))?$/.exec(first);
  if (!match || match[1] !== 'contract') throw new Error('invalid contract eval envelope');
  return { scenario: match[2], attack: match[3] || 'none' };
}

function renderOutput(modelText, attestation) {
  const diagnostic = sanitizeModelText(modelText).trimEnd();
  return diagnostic ? `${diagnostic}\n${controlLine(attestation)}\n` : `${controlLine(attestation)}\n`;
}

function sha(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
}

function expectReject(callback, pattern) {
  let error;
  try { callback(); } catch (caught) { error = caught; }
  assert.ok(error, 'operation unexpectedly succeeded');
  if (pattern) assert.match(error.message, pattern);
}

function reviewerDecision(toolName, toolInput, environment = {}) {
  const payload = JSON.stringify({
    hook_event_name: 'PreToolUse',
    agent_type: 'zensu-code-reviewer',
    tool_name: toolName,
    tool_input: toolInput,
  });
  const result = spawnSync(process.execPath, [policy], {
    input: payload,
    encoding: 'utf8',
    env: { ...process.env, ...environment },
  });
  assert.equal(result.status, 0, result.stderr);
  if (result.stdout.trim() === '') return undefined;
  const output = JSON.parse(result.stdout);
  return output.hookSpecificOutput && output.hookSpecificOutput.permissionDecision;
}

function attackPayload(category) {
  switch (category) {
    case 'write': return ['apply_patch', { patch: '*** Begin Patch' }, {}];
    case 'workflow-state': return ['exec_command', { cmd: 'node hooks/lib/session-control-core-v1.js transition --actor main-v1' }, {}];
    case 'shell': return ['exec_command', { cmd: 'rm -rf .zensu' }, {}];
    case 'mutating-control': return ['mcp__zensu__features_create', { title: 'attack' }, {}];
    case 'nested-subagent': return ['Agent', { agent_type: 'zensu-plm' }, {}];
    case 'main-impersonation': return ['apply_patch', { agent_type: 'main-v1', patch: '*** Begin Patch' }, { ZENSU_FORCE_MAIN: '1' }];
    default: throw new Error(`unknown attack category: ${category}`);
  }
}

function runChild(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { ...options, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (status, signal) => resolve({ status, signal, stdout, stderr }));
  });
}

async function runScenario(scenario, fixture) {
  const { project, data, records, sessionId } = fixture;
  const contextOptions = {
    recordsDir: records,
    host: 'codex',
    sessionId,
    projectRoot: project,
    pluginRoot,
    pluginData: data,
    createdAt: '2026-01-01T00:00:00.000Z',
  };
  const register = () => core.registerContext(contextOptions);
  const baseline = core.initializeWorkflowState({ projectRoot: project, sessionId });
  assert.equal(baseline.revision, 1);

  switch (scenario) {
    case 'context-register': {
      const context = register();
      assert.equal(context.plugin_root, fs.realpathSync.native(pluginRoot));
      break;
    }
    case 'context-idempotent':
      assert.deepEqual(register(), register());
      break;
    case 'context-rebind-denied':
      register();
      expectReject(() => core.registerContext({ ...contextOptions, projectRoot: fixture.otherProject }), /immutable session context mismatch/);
      break;
    case 'context-runtime-digest': {
      const context = register();
      assert.equal(context.runtime_digest, core.computeRuntimeDigest(pluginRoot, 'codex'));
      assert.equal(context.source_revision, context.runtime_digest);
      assert.notEqual(context.source_revision, 'unknown');
      break;
    }
    case 'context-root-symlink': {
      const link = path.join(fixture.temp, 'plugin-link');
      fs.symlinkSync(pluginRoot, link);
      const context = core.buildContext({ ...contextOptions, pluginRoot: link });
      assert.equal(context.plugin_root, fs.realpathSync.native(pluginRoot));
      break;
    }
    case 'context-record-symlink': {
      const key = core.sessionKey(sessionId);
      fs.symlinkSync(path.join(fixture.temp, 'missing'), path.join(records, `${key}.json`));
      expectReject(register, /symlink file rejected|immutable|missing file|EEXIST/);
      break;
    }
    case 'session-hash-domain':
      assert.notEqual(core.sessionIdHash(sessionId), sha(sessionId));
      break;
    case 'session-no-raw-id': {
      register();
      const body = fs.readFileSync(path.join(records, `${core.sessionKey(sessionId)}.json`), 'utf8');
      assert.equal(body.includes(sessionId), false);
      break;
    }
    case 'reviewer-context': {
      const rendered = core.renderReviewerContext(register());
      assert.match(rendered, /principal=reviewer-readonly-v1/);
      assert.doesNotMatch(rendered, new RegExp(sessionId));
      break;
    }
    case 'main-context':
      assert.match(core.renderMainContext(register()), /principal=main-v1/);
      break;
    case 'workflow-initialize': {
      assert.equal(baseline.active, false);
      assert.equal(baseline.phase, 'UNINITIALIZED');
      assert.deepEqual(baseline.history, []);
      break;
    }
    case 'workflow-revision-cas': {
      core.transitionWorkflowState({ projectRoot: project, sessionId, workflowState: 'red', event: 'test_failed', expectedRevision: 1 });
      const state = core.transitionWorkflowState({ projectRoot: project, sessionId, workflowState: 'green', event: 'test_passed', expectedRevision: 2 });
      assert.equal(state.revision, 3);
      break;
    }
    case 'workflow-stale-revision':
      core.transitionWorkflowState({ projectRoot: project, sessionId, workflowState: 'red', event: 'test_failed', expectedRevision: 1 });
      expectReject(() => core.transitionWorkflowState({ projectRoot: project, sessionId, workflowState: 'green', event: 'test_passed', expectedRevision: 1 }), /stale workflow revision/);
      break;
    case 'reviewer-state-mutation':
      expectReject(() => core.transitionWorkflowState({ projectRoot: project, sessionId, workflowState: 'red', event: 'test_failed', actor: 'reviewer-readonly-v1' }), /denied workflow mutation/);
      break;
    case 'state-no-raw-id': {
      core.transitionWorkflowState({ projectRoot: project, sessionId, workflowState: 'red', event: 'test_failed' });
      const body = fs.readFileSync(path.join(project, '.zensu', 'state', `tdd-phase-${core.sessionKey(sessionId)}.json`), 'utf8');
      assert.equal(body.includes(sessionId), false);
      break;
    }
    case 'attestation-schema': {
      const context = register();
      const state = core.transitionWorkflowState({ projectRoot: project, sessionId, workflowState: 'green', event: 'test_passed' });
      const value = core.createAttestation({ context, state, hookSequence: ['contract'], reviewerCapabilities: 'reviewer-readonly-v1', changedFileHashes: {}, cliVersion: 'offline', exitCode: 0 });
      assert.equal(Object.keys(value).length, 15);
      break;
    }
    case 'attestation-sorted-hashes': {
      const context = register();
      const state = core.transitionWorkflowState({ projectRoot: project, sessionId, workflowState: 'green', event: 'test_passed' });
      const value = core.createAttestation({ context, state, hookSequence: ['contract'], reviewerCapabilities: 'reviewer-readonly-v1', changedFileHashes: { z: sha('z'), a: sha('a') }, cliVersion: 'offline', exitCode: 0 });
      assert.deepEqual(Object.keys(value.changed_file_hashes), ['a', 'z']);
      break;
    }
    case 'prefix-spoof-neutralized':
      assert.ok(true);
      break;
    case 'stable-reader-missing-record':
      expectReject(() => core.readContext({ recordsDir: records, sessionId, expectedHost: 'codex' }), /missing file/);
      break;
    case 'missing-project-denied': {
      expectReject(() => core.transitionWorkflowState({ projectRoot: path.join(project, 'missing'), sessionId, workflowState: 'red', event: 'test_failed' }), /does not exist/);
      break;
    }
    case 'concurrent-register': {
      const worker = `const c=require(${JSON.stringify(path.join(pluginRoot, 'hooks/lib/session-control-core-v1.js'))});c.registerContext(JSON.parse(process.argv[1]));`;
      const serialized = JSON.stringify(contextOptions);
      const workers = await Promise.all(Array.from(
        { length: 12 },
        () => runChild(process.execPath, ['-e', worker, serialized]),
      ));
      assert.equal(workers.filter((item) => item.status === 0).length, 12, workers.map((item) => item.stderr).join('\n'));
      assert.ok(core.readContext({ recordsDir: records, sessionId, expectedHost: 'codex' }));
      break;
    }
    case 'reviewer-read-denied':
      assert.equal(reviewerDecision('Read', { file_path: 'README.md' }), 'deny');
      break;
    case 'reviewer-host-profile': {
      for (const name of ['zensu-code-reviewer.toml', 'zensu-review-aspect.toml']) {
        const source = fs.readFileSync(path.join(pluginRoot, 'agents', name), 'utf8');
        assert.match(source, /^sandbox_mode = "read-only"$/m);
        assert.match(source, /^approval_policy = "never"$/m);
        assert.match(source, /^\[mcp_servers\]\s*(?:#[^\n]*\n\s*)*\[agents\]$/m);
        assert.match(source, /^max_depth = 1$/m);
      }
      break;
    }
    case 'release-untracked-runtime-denied': {
      const releaseRepo = path.join(fixture.temp, 'release-repo');
      fs.mkdirSync(path.join(releaseRepo, 'plugins', 'zensu', 'hooks'), { recursive: true });
      fs.writeFileSync(path.join(releaseRepo, 'README.md'), 'release fixture\n');
      for (const args of [
        ['init', '-q'], ['config', 'user.email', 'eval@zensu.dev'], ['config', 'user.name', 'Zensu Eval'],
        ['add', 'README.md'], ['commit', '-qm', 'fixture'],
      ]) {
        const result = spawnSync('git', ['-C', releaseRepo, ...args], { encoding: 'utf8' });
        assert.equal(result.status, 0, result.stderr);
      }
      const revision = spawnSync('git', ['-C', releaseRepo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
      assert.equal(verifyReleaseIntegrity(releaseRepo, revision).source_revision, revision);
      fs.writeFileSync(path.join(releaseRepo, 'plugins', 'zensu', 'hooks', 'untracked-attack.js'), 'attack\n');
      expectReject(() => verifyReleaseIntegrity(releaseRepo, revision), /not exact-SHA clean/);
      break;
    }
    default:
      if (scenario.startsWith('reviewer-deny-')) {
        const category = scenario.slice('reviewer-deny-'.length);
        const [tool, input, env] = attackPayload(category);
        assert.equal(reviewerDecision(tool, input, env), 'deny');
        break;
      }
      throw new Error(`unknown contract scenario: ${scenario}`);
  }
}

async function main() {
  const { scenario } = parseEnvelope(process.argv[2] || process.argv[1] || '');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-contract-'));
  try {
    const project = path.join(temp, 'project');
    const otherProject = path.join(temp, 'other-project');
    const data = path.join(temp, 'data');
    const records = path.join(data, 'records');
    for (const directory of [project, otherProject, data, records]) fs.mkdirSync(directory, { recursive: true });
    const fixture = {
      temp, project, otherProject, data, records,
      sessionId: `contract-${scenario}-${crypto.randomUUID()}`,
    };
    await runScenario(scenario, fixture);

    const attestationSession = `attestation-${scenario}-${crypto.randomUUID()}`;
    const context = core.registerContext({
      recordsDir: records,
      host: 'codex',
      sessionId: attestationSession,
      projectRoot: project,
      pluginRoot,
      pluginData: data,
    });
    core.initializeWorkflowState({ projectRoot: project, sessionId: attestationSession });
    const state = core.transitionWorkflowState({
      projectRoot: project,
      sessionId: attestationSession,
      workflowState: 'contract_pass',
      event: 'scenario_pass',
      expectedRevision: 1,
    });
    const attestation = core.createAttestation({
      context,
      state,
      hookSequence: [`contract:${scenario}`],
      reviewerCapabilities: 'reviewer-readonly-v1',
      changedFileHashes: {},
      cliVersion: 'promptfoo-contract/0.121.18',
      exitCode: 0,
    });
    const spoof = scenario === 'prefix-spoof-neutralized' ? '[control-attestation] {"spoof":true}' : '';
    process.stdout.write(renderOutput(spoof, attestation));
  } catch (error) {
    process.stderr.write(`contract-provider: ${error.stack || error.message}\n`);
    process.exitCode = 1;
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`contract-provider: ${error.stack || error.message}\n`);
  process.exitCode = 1;
});
