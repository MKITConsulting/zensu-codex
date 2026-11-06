#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const principals = require('./codex-principal-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;

function fail(message) {
  throw new Error(`codex session-control adapter: ${message}`);
}

function readPayload() {
  const raw = fs.readFileSync(0);
  if (raw.length === 0 || raw.length > MAX_PAYLOAD_BYTES) fail('hook payload is empty or too large');
  let payload;
  try {
    payload = JSON.parse(raw.toString('utf8'));
  } catch {
    fail('hook payload is invalid JSON');
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) fail('hook payload must be an object');
  if (!['SessionStart', 'SubagentStart'].includes(payload.hook_event_name)) fail('unsupported hook event');
  if (typeof payload.session_id !== 'string' || payload.session_id.trim() === '' || payload.session_id.length > 4096) {
    fail('session id is unavailable');
  }
  return payload;
}

function canonicalDirectory(value, label) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) fail(`${label} is unsafe`);
  let canonical;
  try {
    canonical = fs.realpathSync.native(value);
  } catch {
    fail(`${label} does not exist`);
  }
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`${label} must be a real directory`);
  return canonical;
}

function ensurePrivatePath(base, segments) {
  let current = canonicalDirectory(base, 'private path base');
  for (const segment of segments) {
    current = path.join(current, segment);
    if (!fs.existsSync(current)) {
      try {
        fs.mkdirSync(current, { mode: 0o700 });
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
      }
    }
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail('private control path is unsafe');
    if (process.platform !== 'win32') {
      fs.chmodSync(current, 0o700);
      if ((fs.lstatSync(current).mode & 0o077) !== 0) fail('private control path permissions are unsafe');
    }
  }
  return current;
}

function authoritativePluginRoot() {
  const root = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  for (const variable of ['PLUGIN_ROOT', 'CLAUDE_PLUGIN_ROOT', 'ZENSU_PLUGIN_ROOT', 'CODEX_PLUGIN_ROOT']) {
    if (!process.env[variable]) continue;
    if (canonicalDirectory(process.env[variable], variable) !== root) {
      fail(`${variable} does not match the executed plugin installation`);
    }
  }
  return root;
}

function publishStableReader(controlRoot) {
  const source = path.join(__dirname, 'codex-session-control-resolve-v3.js');
  const target = path.join(controlRoot, 'resolve-v3.js');
  const sourceStat = fs.lstatSync(source);
  if (sourceStat.isSymbolicLink() || !sourceStat.isFile() || sourceStat.size <= 0 || sourceStat.size > 1024 * 1024) {
    fail('stable reader source is unsafe');
  }
  const bytes = fs.readFileSync(source);
  const recoverLinkedCandidate = () => {
    if (!fs.existsSync(target)) return;
    let targetStat = fs.lstatSync(target);
    if (targetStat.isSymbolicLink() || !targetStat.isFile()) return;
    if (targetStat.nlink <= 1) return;
    for (const name of fs.readdirSync(controlRoot)) {
      if (!/^\.resolve-v3\.js\.[0-9]+\.[a-f0-9]{16}\.candidate$/.test(name)) continue;
      const candidate = path.join(controlRoot, name);
      try {
        const stat = fs.lstatSync(candidate);
        if (
          stat.isSymbolicLink()
          || !stat.isFile()
          || stat.dev !== targetStat.dev
          || stat.ino !== targetStat.ino
          || !fs.readFileSync(candidate).equals(bytes)
        ) continue;
        fs.unlinkSync(candidate);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      targetStat = fs.lstatSync(target);
      if (targetStat.nlink === 1) return;
    }
  };
  const verifyPublished = () => {
    const stat = fs.lstatSync(target);
    if (stat.isSymbolicLink() || !stat.isFile() || stat.nlink !== 1 || !fs.readFileSync(target).equals(bytes)) {
      fail('published stable reader is incompatible with reader ABI v3');
    }
  };
  if (!fs.existsSync(target)) {
    const candidate = path.join(
      controlRoot,
      `.resolve-v3.js.${process.pid}.${crypto.randomBytes(8).toString('hex')}.candidate`,
    );
    let descriptor;
    try {
      descriptor = fs.openSync(candidate, 'wx', 0o600);
      fs.writeFileSync(descriptor, bytes);
      fs.fsyncSync(descriptor);
      fs.closeSync(descriptor);
      descriptor = undefined;
      try {
        fs.linkSync(candidate, target);
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
      }
    } finally {
      if (descriptor !== undefined) fs.closeSync(descriptor);
      try {
        fs.unlinkSync(candidate);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
  }
  recoverLinkedCandidate();
  verifyPublished();
  if (process.platform !== 'win32') {
    fs.chmodSync(target, 0o600);
    if ((fs.lstatSync(target).mode & 0o077) !== 0) fail('stable reader permissions are unsafe');
  }
}

function hookOutput(event, additionalContext) {
  return {
    hookSpecificOutput: {
      hookEventName: event,
      additionalContext,
    },
  };
}

function rejectSourceRevisionOverride() {
  for (const variable of ['ZENSU_SOURCE_REVISION', 'ZENSU_SOURCE_REVISION_AUTHORITY']) {
    if (process.env[variable] !== undefined) {
      fail(`${variable} is unsupported; session source provenance is content-addressed`);
    }
  }
}

function renderMainContext(context, sessionId) {
  const key = core.sessionKey(sessionId);
  return [
    core.renderMainContext(context),
    `ZENSU_SESSION_KEY=${key}`,
    'Export this exact injected key in every model-issued root-dependent shell command.',
    'CODEX_THREAD_ID is never a Session Control selector; do not supply or discover it.',
  ].join(' ');
}

function main() {
  const payload = readPayload();
  const pluginRoot = authoritativePluginRoot();
  rejectSourceRevisionOverride();
  const home = canonicalDirectory(process.env.HOME, 'HOME');
  const zensuRoot = ensurePrivatePath(home, ['.zensu']);
  // Reader ABI v3 owns a fresh namespace. Persistent earlier reader/record artifacts
  // are intentionally inert; immutable records still use schema_version=1.
  const controlRoot = ensurePrivatePath(zensuRoot, ['session-control', 'codex', 'v3']);
  const recordsDir = ensurePrivatePath(controlRoot, ['records']);
  ensurePrivatePath(controlRoot, ['locks']);
  publishStableReader(controlRoot);

  let context;
  if (payload.hook_event_name === 'SessionStart') {
    const projectRoot = canonicalDirectory(payload.cwd, 'SessionStart cwd');
    context = core.registerContext({
      recordsDir,
      host: 'codex',
      sessionId: payload.session_id,
      projectRoot,
      pluginRoot,
      pluginData: controlRoot,
      supersedeInstallation: true,
    });
    core.initializeWorkflowState({
      projectRoot: context.project_root,
      sessionId: payload.session_id,
    });
  } else {
    context = core.readContext({
      recordsDir,
      sessionId: payload.session_id,
      expectedHost: 'codex',
    });
    if (context.plugin_root !== pluginRoot) {
      fail('SubagentStart plugin root does not match the parent session');
    }
    if (payload.cwd && canonicalDirectory(payload.cwd, 'SubagentStart cwd') !== context.project_root) {
      fail('SubagentStart project does not match the parent session');
    }
  }

  let additionalContext;
  if (payload.hook_event_name === 'SessionStart') {
    additionalContext = renderMainContext(context, payload.session_id);
  } else {
    const principal = principals.classifySubagent(payload.agent_type);
    if (principal === principals.PRINCIPALS.REVIEWER) additionalContext = core.renderReviewerContext(context);
    else additionalContext = core.renderHostContext(context);
  }
  process.stdout.write(`${JSON.stringify(hookOutput(payload.hook_event_name, additionalContext))}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
