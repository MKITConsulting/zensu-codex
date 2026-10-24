'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const plugin = fs.existsSync(path.join(root, 'plugins/zensu')) ? path.join(root, 'plugins/zensu') : root;
const capture = require(path.join(plugin, 'hooks/lib/ai-work-capture-v1.js'));
const session = `scv1_${'b'.repeat(64)}`;
const actor = 'ba2e3519-3a56-4efa-815d-b411c882c769';
const other = '97e89c7f-3ce7-4593-9da3-7dfcab18387a';
const org = 'f72c484b-204d-4157-9326-93e02e1e02e1';

function fixture(t) {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-work-capture-'));
  fs.mkdirSync(path.join(workspace, '.git'));
  const options = { workspace, session, task: 'goal-1', title: 'Implement agreed goal', criteria: 'spec-v1' };
  const state = { apiUrl: 'https://api.example.test', actor, head: 'a'.repeat(40), dirty: '', unit: null, submits: [], calls: [], failResponse: false };
  const previous = cp.spawnSync;
  cp.spawnSync = (command, args, opts) => {
    assert.equal(opts.shell, undefined, 'metadata must never become a shell command');
    let value;
    if (command === 'git') {
      value = args.includes('--absolute-git-dir') ? path.join(workspace, '.git') : args[0] === 'status' ? state.dirty : state.head;
    } else {
      assert.equal(command, 'zensu'); assert.equal(args[0], 'ai-work');
      state.calls.push(args);
      const flag = (key) => args[args.indexOf(key) + 1];
      switch (args[1]) {
        case 'context': value = { apiUrl: state.apiUrl }; break;
        case 'start':
          if (state.unit && state.unit.actor !== state.actor) return { status: 1, stderr: 'secret server body' };
          state.unit ??= { id: flag('--id'), actor: state.actor, version: 1, result: null, decision: null };
          value = { id: state.unit.id }; break;
        case 'get':
          value = { ...state.unit, reportingUserId: state.actor, organizationId: org,
            reviewUrl: `https://app.example.test/ai-work?unit=${state.unit.id}${state.unit.result ? `&result=${state.unit.result.id}` : ''}` };
          if (state.forged) value.id = other;
          break;
        case 'submit': {
          const event = { id: flag('--event-id'), artifactRef: flag('--artifact'), criteriaVersion: flag('--criteria-version'), expectedVersion: Number(flag('--expected-version')) };
          state.submits.push(event);
          if (!state.unit.result || state.unit.result.id !== event.id) {
            if (event.expectedVersion !== state.unit.version) return { status: 1 };
            state.unit.result = event; state.unit.version++; state.unit.decision = null;
          }
          if (state.failResponse) { state.failResponse = false; return { status: 1 }; }
          value = { id: event.id }; break;
        }
        default: assert.fail(`unexpected command: ${args[1]}`);
      }
      value = JSON.stringify(value);
    }
    return { status: 0, stdout: value };
  };
  t.after(() => { cp.spawnSync = previous; fs.rmSync(workspace, { recursive: true, force: true }); });
  return { options, state, file: path.join(workspace, '.git/zensu-ai-work-v1', `${session}.json`) };
}

test('captures one goal and one exact version, with no acceptance command', (t) => {
  const { options, state } = fixture(t);
  assert.equal(capture.begin(options).status, 'recording');
  capture.begin(options);
  state.head = 'c'.repeat(40);
  assert.equal(capture.checkpoint(options).status, 'submitted_for_review');
  assert.equal(capture.checkpoint(options).status, 'already_submitted');
  assert.equal(state.submits.length, 1); assert.equal(state.unit.version, 2);
  assert.equal(state.unit.result.artifactRef, `commit:${state.head}`);
  assert.equal(state.unit.result.criteriaVersion, options.criteria);
  assert.equal(state.unit.decision, null);
  assert.ok(state.calls.every((args) => !args.includes('accept') && !args.includes('user-id')));
});
test('lost response retries the exact durable event even after human acceptance', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options); state.head = 'c'.repeat(40); state.failResponse = true;
  assert.throws(() => capture.checkpoint(options), /incomplete/);
  assert.ok(JSON.parse(fs.readFileSync(file)).pending);
  state.unit.decision = { kind: 'accepted' }; state.unit.version++;
  capture.checkpoint(options);
  assert.deepEqual(state.submits[0], state.submits[1]);
  assert.equal(state.unit.version, 3); assert.equal(state.unit.decision.kind, 'accepted');
  assert.equal(JSON.parse(fs.readFileSync(file)).pending, undefined);
});
test('changed login or host cannot attribute an existing task to someone else', (t) => {
  const { options, state } = fixture(t);
  capture.begin(options); state.head = 'c'.repeat(40); state.actor = other;
  assert.throws(() => capture.checkpoint(options), /incomplete/);
  state.actor = actor; state.apiUrl = 'https://other.example.test';
  assert.throws(() => capture.checkpoint(options), /host changed/);
  assert.equal(state.submits.length, 0);
});
test('uncommitted work and unchanged starting head are not submitted', (t) => {
  const { options, state } = fixture(t);
  capture.begin(options); assert.equal(capture.checkpoint(options).status, 'no_new_commit');
  state.head = 'd'.repeat(40); state.dirty = ' M work.go';
  assert.equal(capture.checkpoint(options).status, 'uncommitted_work');
  assert.equal(state.submits.length, 0);
});
test('new commits do not inherit acceptance and unchanged reports do not revoke it', (t) => {
  const { options, state } = fixture(t);
  capture.begin(options); state.head = 'c'.repeat(40); capture.checkpoint(options);
  state.unit.decision = { kind: 'accepted' }; state.unit.version++;
  capture.checkpoint(options); assert.equal(state.unit.decision.kind, 'accepted');
  state.head = 'd'.repeat(40); capture.checkpoint(options);
  assert.equal(state.unit.decision, null); assert.equal(state.submits.length, 2);
});
test('changed criteria, invalid identities and concurrent receipts fail closed', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  assert.throws(() => capture.begin({ ...options, criteria: 'v2' }), /new task key/);
  state.forged = true; assert.throws(() => capture.checkpoint(options), /identity mismatch/);
  state.forged = false; fs.writeFileSync(`${file}.lock`, '');
  assert.throws(() => capture.checkpoint(options), /already running/);
  assert.equal(state.submits.length, 0);
});
test('no begun goal produces no CLI calls or receipt directory', (t) => {
  const { options, state, file } = fixture(t);
  assert.equal(capture.checkpoint(options).status, 'not_started');
  assert.equal(state.calls.length, 0); assert.equal(fs.existsSync(path.dirname(file)), false);
});
test('the hook and primer are registered, with no session-start capture writes', () => {
  const hooks = JSON.parse(fs.readFileSync(path.join(plugin, 'hooks/hooks.json'))).hooks;
  assert.ok(JSON.stringify(hooks.Stop).includes('stop-ai-work-capture.sh'));
  assert.ok(JSON.stringify(hooks.SessionStart).includes('session-start-ai-work.sh'));
  const primer = fs.readFileSync(path.join(plugin, 'hooks/session-start-ai-work.sh'), 'utf8');
  assert.ok(primer.includes('capture-v1.js" primer')); assert.ok(!primer.includes('capture-v1.js begin'));
  const payload = { session_id: 'capture-test-session', cwd: '/tmp' };
  const call = (action, input) => cp.spawnSync(process.execPath, [path.join(plugin, 'hooks/lib/ai-work-capture-v1.js'), action], { input: typeof input === 'string' ? input : JSON.stringify(input), encoding: 'utf8' });
  const context = JSON.parse(call('primer', payload).stdout).hookSpecificOutput;
  assert.equal(context.hookEventName, 'SessionStart');
  assert.match(context.additionalContext, /captureSessionKey=scv1_[0-9a-f]{64}/);
  assert.match(context.additionalContext, /direct implementation/);
  assert.equal(call('primer', { ...payload, agent_type: 'reviewer' }).stdout, '');
  assert.equal(call('hook', { ...payload, agent_id: 'child' }).stdout, '');
  const malformed = call('hook', 'not-json-sensitive-input');
  assert.equal(malformed.status, 0); assert.match(malformed.stdout, /capture incomplete/);
  assert.ok(!malformed.stdout.includes('sensitive-input'));
  const oversized = call('hook', 'x'.repeat(1024 * 1024 + 1));
  assert.equal(oversized.status, 0); assert.match(oversized.stdout, /capture incomplete/);
});
