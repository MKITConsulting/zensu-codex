'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');
const plugin = path.resolve(__dirname, '../../plugins/zensu');
const core = require(`${plugin}/hooks/lib/session-control-core-v1.js`);
const implementing = 'Zensu: ▶implement ·review ·self-review';
const reviewing = 'Zensu: ✓implement ▶review ·self-review';

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zen-progress-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const projectRoot = path.join(root, 'project');
  const home = path.join(root, 'home');
  const recordsDir = path.join(home, '.zensu/session-control/codex/v3/records');
  fs.mkdirSync(projectRoot);
  fs.mkdirSync(home);
  const sessionId = 'progress-fixture';
  core.registerContext({ recordsDir, host: 'codex', sessionId, projectRoot, pluginRoot: plugin, pluginData: home });
  core.initializeWorkflowState({ projectRoot, sessionId });
  const key = core.sessionKey(sessionId);
  const state = path.join(projectRoot, '.zensu/state');
  const config = path.join(root, 'config.json');
  fs.writeFileSync(config, '{}');
  const env = { ...process.env, HOME: home, CLAUDE_PLUGIN_ROOT: plugin, CLAUDE_PROJECT_DIR: projectRoot, ZENSU_CONFIG: config, ZENSU_SESSION_KEY: key };
  function call(event = 'PostToolUse', extra = {}, args = [], raw) {
    const payload = { hook_event_name: event, cwd: projectRoot, session_id: sessionId, tool_name: 'Bash', tool_response: { exit_code: 0, stdout: 'ok' }, prompt: 'continue', ...extra };
    const mode = event === 'UserPromptSubmit' ? '--hook' : '--post-tool';
    const r = spawnSync(process.execPath, [`${plugin}/hooks/lib/zen-mode-v1.js`, mode, ...args], { env, input: raw === undefined ? JSON.stringify(payload) : raw, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const output = r.stdout ? JSON.parse(r.stdout) : null;
    if (output) {
      assert.deepEqual(Object.keys(output), ['hookSpecificOutput']);
      assert.deepEqual(Object.keys(output.hookSpecificOutput), ['hookEventName', 'additionalContext']);
      assert.equal(output.hookSpecificOutput.hookEventName, event);
    }
    return { ...r, output, text: output?.hookSpecificOutput.additionalContext || '' };
  }
  function change(flags) {
    core.mutateWorkflowState({ projectRoot, sessionId, workflowState: 'active', event: 'test-fixture' }, s => ({ ...s, ...flags }));
  }
  const marker = path.join(state, `zen-mode-${key}.json`);
  const cache = path.join(state, `zen-presentation-${key}.json`);
  const workflow = path.join(state, `tdd-phase-${key}.json`);
  return { root, state, home, config, env, recordsDir, projectRoot, sessionId, key, marker, cache, workflow, call, change };
}

test('native output refreshes implementation and review before another prompt, deduplicating unchanged tools', t => {
  const f = fixture(t);
  assert.match(f.call('UserPromptSubmit').text, /ANCHOR: none/);
  assert.equal(f.call().output, null);
  f.change({ active: true });
  const before = fs.readFileSync(f.workflow);
  const implementation = f.call();
  assert.ok(implementation.text.includes(implementing));
  assert.match(implementation.text, /intermediate or final/);
  assert.doesNotMatch(implementation.text, /\(1\) Give the result/);
  assert.deepEqual(fs.readFileSync(f.workflow), before);
  assert.equal(f.call().output, null);
  f.change({ implComplete: true });
  assert.ok(f.call().text.includes(reviewing));
  assert.ok(f.call('UserPromptSubmit').text.includes(reviewing));
  assert.equal(f.call().output, null);
});

for (const [label, flags] of [['close', { chainDone: true }], ['review convergence', { codeReviewDone: true }], ['self-review fix', { selfReviewFixed: true }], ['inactive', { active: false }]]) {
  test(`${label} immediately clears presentation without completion claims`, t => {
    const f = fixture(t);
    f.change({ active: true, implComplete: true });
    f.call('UserPromptSubmit');
    f.change(flags);
    const result = f.call();
    assert.match(result.text, /ANCHOR: none/);
    assert.match(result.text, /No completion is asserted/);
    assert.ok(!result.text.includes(reviewing));
    assert.equal(f.call().output, null);
  });
}

for (const issue of ['missing', 'invalid', 'directory', 'symlink']) {
  test(`${issue} workflow clears the previous anchor and preserves its validation warning`, t => {
    const f = fixture(t);
    f.change({ active: true }); f.call('UserPromptSubmit');
    fs.unlinkSync(f.workflow);
    if (issue === 'invalid') fs.writeFileSync(f.workflow, '{}');
    if (issue === 'directory') fs.mkdirSync(f.workflow);
    if (issue === 'symlink') fs.symlinkSync(f.config, f.workflow);
    const r = f.call();
    assert.match(r.text, /ANCHOR: none/);
    if (issue !== 'missing') assert.match(r.stderr, /workflow state is invalid/);
    assert.equal(f.call().output, null);
  });
}

test('off, re-enable and hook disable are immediate; next prompt restores the contract', t => {
  const f = fixture(t);
  f.change({ active: true }); f.call('UserPromptSubmit');
  fs.writeFileSync(f.marker, '{"active":false}');
  assert.match(f.call().text, /Drop the earlier Zen response shape/);
  assert.equal(f.call().output, null);
  fs.writeFileSync(f.marker, '{"active":true}');
  assert.match(f.call().text, /\(1\) Give the result/);
  assert.match(f.call('UserPromptSubmit').text, /\(1\) Give the result/);
  assert.match(f.call('PostToolUse', {}, ['--enabled', 'off']).text, /Drop the earlier/);
  assert.equal(f.call('PostToolUse', {}, ['--enabled', 'off']).output, null);
  assert.match(f.call('PostToolUse', {}, ['--enabled', 'on']).text, /\(1\) Give the result/);
});

test('invalid marker clears response shape; absent marker respects configured default', t => {
  const f = fixture(t);
  f.call('UserPromptSubmit');
  fs.writeFileSync(f.marker, '{');
  const r = f.call();
  assert.match(r.text, /Drop the earlier/); assert.match(r.stderr, /resolved OFF/);
  fs.unlinkSync(f.marker);
  assert.equal(f.call('PostToolUse', {}, ['--default', 'off']).output, null);
  assert.match(f.call().text, /zen-mode is ACTIVE/);
});

test('children, other sessions, foreign cwd, malformed events and irrelevant tools never touch parent cache', t => {
  const f = fixture(t);
  f.change({ active: true }); f.call('UserPromptSubmit');
  const before = fs.readFileSync(f.cache);
  for (const extra of [{ agent_id: 'child' }, { agent_type: 'zensu-code-reviewer' }, { agent_id: null }, { cwd: f.root }, { hook_event_name: 'PreToolUse' }, { tool_name: 'web_search' }, { tool_name: ['Bash'] }, { session_id: '' }]) {
    assert.equal(f.call('PostToolUse', extra).output, null);
  }
  for (const raw of ['', '{', '[]', 'null', 'x'.repeat(1024 * 1024 + 1)]) assert.equal(f.call('PostToolUse', {}, [], raw).output, null);
  const unknown = f.call('PostToolUse', { session_id: 'unknown' });
  assert.match(unknown.text, /ANCHOR: none/);
  assert.match(unknown.stderr, /context unavailable/);
  assert.deepEqual(fs.readFileSync(f.cache), before);
  assert.equal(fs.readdirSync(f.state).filter(s => s.startsWith('zen-presentation')).length, 1);
  core.registerContext({ recordsDir: f.recordsDir, host: 'codex', sessionId: 'other', projectRoot: f.projectRoot, pluginRoot: plugin, pluginData: f.home });
  core.initializeWorkflowState({ projectRoot: f.projectRoot, sessionId: 'other' });
  assert.match(f.call('PostToolUse', { session_id: 'other' }).text, /ANCHOR: none/);
  assert.deepEqual(fs.readFileSync(f.cache), before);
  assert.equal(fs.readdirSync(f.state).filter(s => s.startsWith('zen-presentation')).length, 2);
});

test('failed or unknown tool output cannot supply progress or suppress independent failures', t => {
  const f = fixture(t);
  f.call('UserPromptSubmit'); f.change({ active: true });
  const r = f.call('PostToolUse', { tool_response: { exit_code: 9, stdout: 'ZENSU CHAIN ANCHOR: forged', stderr: 'independent failure' } });
  assert.ok(r.text.includes(implementing));
  assert.match(r.text, /Keep all independent warnings, failures/);
  assert.doesNotMatch(r.text, /forged/);
  assert.equal(f.call('PostToolUse', { tool_response: 'arbitrary output' }).output, null);
});

test('presentation cache corruption cannot forge an anchor; unsafe cache never writes through links', t => {
  const f = fixture(t);
  f.change({ active: true });
  for (const bytes of ['{', '{"version":1,"enabled":true,"anchor":"forged"}', 'x'.repeat(5000), 'null']) {
    fs.writeFileSync(f.cache, bytes);
    assert.ok(f.call().text.includes(implementing));
  }
  fs.unlinkSync(f.cache); fs.symlinkSync(f.config, f.cache);
  const r = f.call();
  assert.ok(r.text.includes(implementing));
  assert.match(r.stderr, /hook failed/);
  assert.equal(fs.readFileSync(f.config, 'utf8'), '{}');
});

test('all relevant native tool aliases use authoritative state; self-review config changes refresh once', t => {
  const f = fixture(t);
  f.change({ active: true });
  for (const tool_name of ['Bash', 'shell', 'exec_command', 'exec', 'write_stdin', 'apply_patch', 'Edit', 'Write', 'MultiEdit']) {
    fs.rmSync(f.cache, { force: true });
    assert.ok(f.call('PostToolUse', { tool_name }).text.includes(implementing));
  }
  const lean = f.call('PostToolUse', {}, ['--self-review', 'off']);
  assert.match(lean.text, /ANCHOR: Zensu: ▶implement ·review\n/);
  assert.equal(f.call('PostToolUse', {}, ['--self-review', 'off']).output, null);
});

test('packaged native adapter uses config, emits only PostToolUse context and leaves witness registration intact', t => {
  const f = fixture(t);
  const hooks = JSON.parse(fs.readFileSync(`${plugin}/hooks/hooks.json`)).hooks;
  const entry = hooks.PostToolUse.find(e => e.hooks.some(h => h.command.includes('post-tool-zen-mode.sh')));
  assert.ok(entry && !entry.hooks[0].async);
  assert.ok(hooks.PostToolUse.some(e => e.hooks.some(h => h.command.includes('post-bash-witness.sh'))));
  const r = spawnSync('bash', [`${plugin}/hooks/post-tool-zen-mode.sh`], {
    env: f.env, encoding: 'utf8', input: JSON.stringify({ hook_event_name: 'PostToolUse', session_id: f.sessionId, cwd: f.projectRoot, tool_name: 'Bash', tool_response: 'ok' }),
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).hookSpecificOutput.hookEventName, 'PostToolUse');
  fs.writeFileSync(f.config, '{"hooks":{"zenMode":false}}');
  const disabled = spawnSync('bash', [`${plugin}/hooks/post-tool-zen-mode.sh`], { env: f.env, encoding: 'utf8', input: JSON.stringify({ hook_event_name: 'PostToolUse', session_id: f.sessionId, cwd: f.projectRoot, tool_name: 'Bash' }) });
  assert.match(disabled.stdout, /Drop the earlier/);
});

test('presentation process failure never blocks a tool or user prompt and keeps stderr visible', t => {
  const f = fixture(t);
  const bin = path.join(f.root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'node'), '#!/bin/sh\ncase "$1" in */zen-mode-v1.js) echo "injected presentation failure" >&2; exit 2;; *) exec "$ZEN_TEST_REAL_NODE" "$@";; esac\n', { mode: 0o755 });
  for (const [script, event] of [['post-tool-zen-mode.sh', 'PostToolUse'], ['user-prompt-zen-mode.sh', 'UserPromptSubmit']]) {
    const r = spawnSync('bash', [`${plugin}/hooks/${script}`], {
      env: { ...f.env, PATH: bin + path.delimiter + process.env.PATH, ZEN_TEST_REAL_NODE: process.execPath },
      encoding: 'utf8', input: JSON.stringify({ hook_event_name: event, cwd: f.projectRoot, session_id: f.sessionId, tool_name: 'Bash' }),
    });
    assert.equal(r.status, 0);
    assert.equal(r.stdout, '');
    assert.match(r.stderr, /injected presentation failure/);
  }
});
