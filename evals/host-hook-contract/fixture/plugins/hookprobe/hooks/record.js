'use strict';

const fs = require('node:fs');
const path = require('node:path');

const event = process.argv[2] || 'unknown';
const label = process.argv[3] || null;
const out = process.env.PROBE_DIR || '';

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

function parseMode() {
  try {
    return JSON.parse(process.env.PROBE_MODE || '{}');
  } catch {
    return {};
  }
}

function nextCount(name) {
  if (!out) return 1;
  const file = path.join(out, `count-${name}`);
  let n = 0;
  try {
    n = Number(fs.readFileSync(file, 'utf8')) || 0;
  } catch {
    n = 0;
  }
  n += 1;
  fs.writeFileSync(file, String(n));
  return n;
}

function emitShape(shape, marker, eventName) {
  switch (shape) {
    case 'decision-block':
      process.stdout.write(`${JSON.stringify({ decision: 'block', reason: marker })}\n`);
      return 0;
    case 'exit2':
      process.stderr.write(`${marker}\n`);
      return 2;
    case 'continue-false':
      process.stdout.write(`${JSON.stringify({ continue: false, stopReason: marker })}\n`);
      return 0;
    case 'system-message':
      process.stdout.write(`${JSON.stringify({ continue: true, systemMessage: marker })}\n`);
      return 0;
    case 'deny-json':
      process.stdout.write(`${JSON.stringify({
        hookSpecificOutput: {
          hookEventName: eventName,
          permissionDecision: 'deny',
          permissionDecisionReason: marker,
        },
      })}\n`);
      return 0;
    default:
      return 0;
  }
}

function toolNameOf(payload) {
  if (!payload || typeof payload !== 'object') return '';
  return String(payload.tool_name || '');
}

function answer(mode, payload) {
  const context = mode.context || {};
  if (event === 'SessionStart' && context.sessionStart) {
    process.stdout.write(`${JSON.stringify({
      hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: context.sessionStart },
    })}\n`);
    return 0;
  }
  if (event === 'UserPromptSubmit' && context.userPromptSubmit) {
    process.stdout.write(`${JSON.stringify({
      hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: context.userPromptSubmit },
    })}\n`);
    return 0;
  }
  if (event === 'PreToolUse' && mode.deny) {
    const name = toolNameOf(payload);
    if (![].concat(mode.deny.tool || []).includes(name)) return 0;
    if (mode.deny.scope === 'subagent' && !(payload && payload.agent_id)) return 0;
    return emitShape(mode.deny.via === 'exit2' ? 'exit2' : 'deny-json', `${mode.deny.marker} ${name}`, 'PreToolUse');
  }
  if (event === 'Stop' && mode.stop) {
    const n = nextCount('stop-shape');
    return n < 3 ? emitShape(mode.stop.shape, `${mode.stop.marker} stop invocation ${n}: keep working.`, 'Stop') : 0;
  }
  if (event === 'SubagentStop' && mode.subagentStop) {
    const n = nextCount('subagent-stop-shape');
    return n <= (mode.subagentStop.times || 2) ? emitShape(mode.subagentStop.shape, `${mode.subagentStop.marker} invocation ${n}: keep working.`, 'SubagentStop') : 0;
  }
  return 0;
}

const raw = readStdin();
let payload;
try {
  payload = JSON.parse(raw);
} catch {
  payload = { unparsed: raw.slice(0, 4000) };
}
const seq = nextCount(`event-${event}${label ? `-${label}` : ''}`);

if (out) {
  const dir = path.join(out, 'hooks');
  fs.mkdirSync(dir, { recursive: true });
  const record = {
    event,
    label,
    seq,
    at: (performance.timeOrigin + performance.now()).toFixed(3),
    pid: process.pid,
    cwd: process.cwd(),
    argv: process.argv.slice(2),
    script: __filename,
    env: process.env,
    payload,
  };
  const file = path.join(dir, `${record.at}-${process.pid}-${event}${label ? `-${label}` : ''}.json`);
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(record));
  fs.renameSync(temporary, file);
}

process.exitCode = label ? 0 : answer(parseMode(), payload);
