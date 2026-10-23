'use strict';

// Explicit work goals, not session surveillance. No transcripts, code, diffs,
// credentials or local paths leave this process. A Stop is never acceptance.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const core = require('./session-control-core-v1.js');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;

function text(value, max) {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/.test(value);
}
function execute(command, args, cwd) {
  const env = { ...process.env };
  // Git hooks may export discovery variables belonging to another checkout.
  for (const key of Object.keys(env)) if (key.startsWith('GIT_')) delete env[key];
  const r = cp.spawnSync(command, args, { cwd, env, encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024, windowsHide: true });
  if (r.error || r.status !== 0) throw new Error(`${command === 'git' ? 'Git' : 'CLI'} capture operation failed; capture is incomplete. Check personal OAuth login, permissions, server compatibility and connection, then retry the same task.`);
  return r.stdout.trim();
}
function cli(args, cwd) {
  const value = JSON.parse(execute('zensu', ['ai-work', ...args], cwd));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid capture response');
  return value;
}
function location(workspace, session, create = false) {
  if (!text(workspace, 4096) || !/^scv1_[0-9a-f]{64}$/.test(session)) throw new Error('A bound workspace and Session Control key are required');
  const root = fs.realpathSync(workspace);
  const gitDir = execute('git', ['rev-parse', '--absolute-git-dir'], root);
  const dir = path.join(gitDir, 'zensu-ai-work-v1');
  if (fs.existsSync(dir) && fs.lstatSync(dir).isSymbolicLink()) throw new Error('Unsafe capture directory');
  if (create) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return { root, dir, file: path.join(dir, `${session}.json`) };
}
function read(file) {
  if (!fs.existsSync(file)) return null;
  const st = fs.lstatSync(file);
  if (!st.isFile() || st.isSymbolicLink() || st.size > 32768) throw new Error('Unsafe capture state');
  const s = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (s.schema !== 1 || !UUID.test(s.id) || !text(s.task, 160) || !text(s.title, 160) || !text(s.criteria, 160) || !text(s.apiUrl, 2048) || !SHA.test(s.startHead)) throw new Error('Invalid capture state');
  if (s.pending && (!UUID.test(s.pending.id) || !Number.isInteger(s.pending.expectedVersion) || s.pending.expectedVersion < 1 || !/^commit:(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(s.pending.artifactRef) || s.pending.criteriaVersion !== s.criteria)) throw new Error('Invalid pending submission');
  return s;
}
function save(file, state) {
  const tmp = `${file}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state) + '\n', { flag: 'wx', mode: 0o600 });
  fs.renameSync(tmp, file);
}
function lock(file, fn) {
  const lockPath = `${file}.lock`;
  let fd;
  try { fd = fs.openSync(lockPath, 'wx', 0o600); } catch { throw new Error('Capture already running; retry after it finishes. A crash may leave a lock requiring inspection.'); }
  try { return fn(); } finally { fs.closeSync(fd); fs.unlinkSync(lockPath); }
}
function start(s, root) {
  const context = cli(['context'], root);
  if (context.apiUrl !== s.apiUrl) throw new Error('Capture host changed; restore the original host or begin a new task');
  // Replay the declaration before every report. The server rejects a changed
  // authenticated subject even if the replacement login is an administrator.
  const result = cli(['start', '--id', s.id, '--title', s.title], root);
  if (result.id !== s.id) throw new Error('Capture start identity mismatch');
}
function detail(s, root) {
  const d = cli(['get', s.id], root);
  if (d.id !== s.id || !Number.isInteger(d.version) || d.version < 1 || !UUID.test(d.reportingUserId) || !UUID.test(d.organizationId)) throw new Error('Capture detail identity mismatch');
  if (s.user && (s.user !== d.reportingUserId || s.organization !== d.organizationId)) throw new Error('Capture account changed');
  if (d.result && (!UUID.test(d.result.id) || typeof d.result.artifactRef !== 'string')) throw new Error('Invalid captured result');
  const review = new URL(d.reviewUrl);
  if (!['http:', 'https:'].includes(review.protocol) || review.username || review.password || review.searchParams.get('unit') !== s.id || (d.result && review.searchParams.get('result') !== d.result.id)) throw new Error('Invalid review link');
  s.user = d.reportingUserId; s.organization = d.organizationId;
  return d;
}
function begin(options) {
  const { root, file } = location(options.workspace, options.session, true);
  if (!text(options.task, 160) || !text(options.title, 160) || !text(options.criteria, 160)) throw new Error('Task, objective and criteria version are required');
  return lock(file, () => {
    let s = read(file);
    if (s && s.task === options.task && (s.title !== options.title || s.criteria !== options.criteria)) throw new Error('A task retry must keep its objective and criteria version; use a new task key for a changed goal');
    if (!s || s.task !== options.task) {
      if (s && s.pending) throw new Error('Previous submission is still pending; retry it before starting another task');
      const head = execute('git', ['rev-parse', 'HEAD'], root);
      if (!SHA.test(head)) throw new Error('A committed starting revision is required');
      const context = cli(['context'], root);
      if (!text(context.apiUrl, 2048)) throw new Error('Invalid capture host');
      s = { schema: 1, id: crypto.randomUUID(), task: options.task, title: options.title, criteria: options.criteria, apiUrl: context.apiUrl, startHead: head };
      // Persist before the first request, including on a lost response.
      save(file, s);
    }
    start(s, root);
    const d = detail(s, root); save(file, s);
    return { status: 'recording', id: s.id, reviewUrl: d.reviewUrl };
  });
}
function checkpoint(options) {
  const { root, file } = location(options.workspace, options.session);
  if (!fs.existsSync(file)) return { status: 'not_started' };
  return lock(file, () => {
    const s = read(file);
    start(s, root);
    let d = detail(s, root);
    if (!s.pending) {
      const head = execute('git', ['rev-parse', 'HEAD'], root);
      if (!SHA.test(head)) throw new Error('Invalid commit revision');
      if (execute('git', ['status', '--porcelain', '--untracked-files=normal'], root)) return { status: 'uncommitted_work', id: s.id };
      if (head === s.startHead) return { status: 'no_new_commit', id: s.id };
      if (d.result && d.result.artifactRef === `commit:${head}` && d.result.criteriaVersion === s.criteria) return { status: 'already_submitted', id: s.id, reviewUrl: d.reviewUrl };
      s.pending = { id: crypto.randomUUID(), expectedVersion: d.version, artifactRef: `commit:${head}`, criteriaVersion: s.criteria };
      save(file, s);
    }
    const p = s.pending;
    const result = cli(['submit', s.id, '--event-id', p.id, '--expected-version', String(p.expectedVersion), '--artifact', p.artifactRef, '--criteria-version', p.criteriaVersion], root);
    if (result.id !== p.id) throw new Error('Submission identity mismatch');
    delete s.pending; save(file, s);
    d = detail(s, root);
    return { status: 'submitted_for_review', id: s.id, reviewUrl: d.reviewUrl };
  });
}

function main(argv) {
  const [action, ...args] = argv;
  if (action === 'hook' || action === 'primer') {
    const chunks = [], buffer = Buffer.alloc(4096);
    let bytes = 0, size;
    while ((size = fs.readSync(0, buffer, 0, buffer.length, null)) > 0) {
      bytes += size;
      if (bytes > 1024 * 1024) throw new Error('Oversized hook input');
      chunks.push(Buffer.from(buffer.subarray(0, size)));
    }
    const payload = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
    if (payload.agent_id || payload.agent_type || !payload.session_id || !payload.cwd) return;
    const session = core.sessionKey(payload.session_id);
    if (action === 'primer') {
      const protocol = path.resolve(__dirname, '../../docs/ai-work-capture.md');
      const additionalContext = `Zensu AI work capture: captureSessionKey=${session}. For an authorized implementation task, read ${protocol} and automatically begin one explicit work goal through the typed CLI helper. This also applies to direct implementation without the Zensu review workflow. Do not begin for greetings, read-only questions or session startup alone. Capture uses personal CLI OAuth, independently of Pulse. The Stop hook submits new clean commits for review. It never accepts a result. Surface capture failures and the exact review link; never claim an agent report or merged PR is a human acceptance.`;
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext } }) + '\n');
      return;
    }
    const result = checkpoint({ workspace: payload.cwd, session });
    if (result.status === 'not_started') return;
    process.stdout.write(`Zensu AI work capture: ${JSON.stringify(result)}. Submission does not accept a result.\n`);
    return;
  }
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--workspace', '--session', '--task', '--title', '--criteria'].includes(args[i]) || args[i + 1] === undefined || Object.hasOwn(options, args[i].slice(2))) throw new Error('Invalid capture arguments');
    options[args[i].slice(2)] = args[i + 1];
  }
  if (!['begin', 'checkpoint'].includes(action)) throw new Error('Use begin or checkpoint; decisions are only available in the web application');
  process.stdout.write(JSON.stringify(action === 'begin' ? begin(options) : checkpoint(options)) + '\n');
}
if (require.main === module) {
  try { main(process.argv.slice(2)); } catch (e) {
    // Never replay server bodies, CLI stderr or hook input into the agent context.
    const output = process.argv[2] === 'hook' ? process.stdout : process.stderr;
    output.write('Zensu AI work capture incomplete. No acceptance was recorded. Check personal OAuth login, capture state, permissions and connectivity; retry the same task.\n');
    process.exitCode = process.argv[2] === 'hook' ? 0 : 1;
  }
}
module.exports = { begin, checkpoint, main };
