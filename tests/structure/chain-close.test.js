'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');
const plugin = path.resolve(__dirname, '../../plugins/zensu');
const core = require(`${plugin}/hooks/lib/session-control-core-v1.js`);

function fixture(t, hooks = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'chain-close-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const projectRoot = path.join(root, 'project');
  const home = path.join(root, 'home');
  fs.mkdirSync(projectRoot);
  fs.mkdirSync(home);
  const config = path.join(root, 'config.json');
  fs.writeFileSync(config, JSON.stringify({ hooks }));
  const sessionId = 'closure-owner';
  const key = core.sessionKey(sessionId);
  // These children own independent fixtures, never the invoking session.
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) =>
    !/^(ZENSU_|CLAUDE_|COPILOT_|CODEX_THREAD_)/.test(name)
    && !['PLUGIN_ROOT', 'PLUGIN_DATA'].includes(name)));
  Object.assign(env, { HOME: home, PWD: projectRoot, ZENSU_CONFIG: config, ZENSU_SESSION_KEY: key });
  function run(file, args = [], input = '', override = {}) {
    const result = spawnSync('bash', [path.join(plugin, file), ...args], {
      cwd: projectRoot, env: { ...env, ...override }, input, encoding: 'utf8', timeout: 15000,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, 'fixture process must exit without a signal');
    assert.equal(typeof result.status, 'number', 'fixture process must report a numeric exit');
    return result;
  }
  const started = run('hooks/session-start-session-control.sh', [], JSON.stringify({ hook_event_name: 'SessionStart', session_id: sessionId, cwd: projectRoot }));
  assert.equal(started.status, 0, started.stderr);
  assert.match(started.stdout, /principal=main-v1/);
  function mark(verb) {
    const r = run('hooks/lib/zensu-log.sh', [verb]);
    assert.equal(r.status, 0, r.stderr);
    return r;
  }
  function stop() {
    const r = run('hooks/stop-chain-enforcer.sh', [], JSON.stringify({ hook_event_name: 'Stop', session_id: sessionId, cwd: projectRoot }));
    assert.equal(r.status, 0, r.stderr);
    return { ...r, output: r.stdout.trim() ? JSON.parse(r.stdout) : null };
  }
  const workflow = path.join(projectRoot, '.zensu/state', `tdd-phase-${key}.json`);
  const state = () => JSON.parse(fs.readFileSync(workflow, 'utf8'));
  return { projectRoot, workflow, state, mark, stop, run, sessionId, key };
}

for (const strict of [false, true]) {
  test(`Stop requires a positively blocked implementation plan, mode=${strict ? 'strict' : 'vanilla'}`, t => {
    const f = fixture(t, { tddImplementation: strict });
    f.mark('--tdd-begin');
    assert.equal(f.stop().output, null, 'mid-implementation pauses remain valid');
    f.mark('--tdd-complete');
    const before = f.state();
    const { output } = f.stop();
    assert.equal(output.decision, 'block');
    assert.match(output.reason, /ZERO file changes AND EVERY planned implementation step is recorded as blocked \[!\]/);
    assert.match(output.reason, /non-empty implementation plan/);
    assert.match(output.reason, /empty diff.*does not authorize.*--chain-done/);
    assert.match(output.reason, /REVIEW PACKET v1/);
    assert.match(output.reason, /zensu-review-aspect/);
    assert.match(output.reason, /zensu-code-reviewer/);
    assert.match(output.reason, strict ? /under the gate/ : /vanilla mode/);
    assert.equal(f.state().chainDone, false);
    assert.equal(f.state().codeReviewDone, false);
    assert.equal(f.state().stopBlocks, before.stopBlocks + 1);
  });
}

test('Stop reminders preserve lifecycle ownership through review and self-review', t => {
  const f = fixture(t);
  f.mark('--tdd-begin');
  f.mark('--tdd-complete');
  for (const reviewed of [false, true]) {
    if (reviewed) f.mark('--code-review-done');
    const { output } = f.stop();
    assert.equal(output.decision, 'block');
    assert.match(output.reason, /This reminder grants no new lifecycle authority/);
    assert.match(output.reason, /status request|observation-only/);
    assert.match(output.reason, /preserve its state until the authorized owner explicitly requests the transition/);
    if (reviewed) {
      assert.match(output.reason, /zensu-self-review/);
      assert.match(output.reason, /Do NOT.*re-run the reviewer/);
    }
    assert.equal(f.state().chainDone, false);
  }
});

test('explicit owner closure still works before review and after genuine review convergence', t => {
  const f = fixture(t);
  for (const reviewed of [false, true]) {
    f.mark('--tdd-begin');
    f.mark('--tdd-complete');
    if (reviewed) f.mark('--code-review-done');
    f.mark('--chain-done');
    assert.equal(f.state().chainDone, true);
    assert.equal(f.stop().output, null);
  }
});

test('self-review disabled retains the documented converged review closure path', t => {
  const f = fixture(t, { selfReview: false });
  f.mark('--tdd-begin');
  f.mark('--tdd-complete');
  f.mark('--code-review-done');
  f.mark('--chain-done');
  assert.equal(f.stop().output, null);
  assert.equal(f.state().chainDone, true);
});

test('normal Stop budget allows stopping without manufacturing completion', t => {
  const f = fixture(t, { autoFixMaxRounds: 1 });
  f.mark('--tdd-begin');
  f.mark('--tdd-complete');
  for (let i = 0; i < 4; i++) assert.equal(f.stop().output.decision, 'block');
  const last = f.stop();
  assert.equal(last.output, null);
  assert.match(last.stderr, /cap 4/);
  assert.equal(f.state().chainDone, false);
});

test('invalid state retains its separate bounded refusal and rejects the terminus', t => {
  const f = fixture(t);
  f.mark('--tdd-begin');
  fs.writeFileSync(f.workflow, '{}');
  for (let i = 0; i < 3; i++) assert.equal(f.stop().output.decision, 'block');
  const last = f.stop();
  assert.equal(last.output, null);
  assert.match(last.stderr, /invalid-state stop blocks exceed the cap/);
  const rejected = f.run('hooks/lib/zensu-log.sh', ['--chain-done']);
  assert.notEqual(rejected.status, 0);
  t.diagnostic(`invalid-state terminus rejected with exit ${rejected.status}`);
  assert.equal(fs.readFileSync(f.workflow, 'utf8'), '{}');
});

test('a foreign selector cannot close the owned workflow', t => {
  const f = fixture(t);
  f.mark('--tdd-begin');
  f.mark('--tdd-complete');
  const before = fs.readFileSync(f.workflow);
  const r = f.run('hooks/lib/zensu-log.sh', ['--chain-done'], '', { ZENSU_SESSION_KEY: core.sessionKey('foreign-owner') });
  assert.notEqual(r.status, 0);
  t.diagnostic(`foreign-selector terminus rejected with exit ${r.status}`);
  assert.deepEqual(fs.readFileSync(f.workflow), before);
});

test('the skill states the same non-vacuous blocked-plan and ownership contract', () => {
  const skill = fs.readFileSync(path.join(plugin, 'skills/tdd/SKILL.md'), 'utf8');
  assert.match(skill, /ZERO file changes AND EVERY planned implementation step is recorded as blocked \[!\]/);
  assert.match(skill, /non-empty implementation plan/);
  assert.match(skill, /This reminder grants no new lifecycle authority/);
});
