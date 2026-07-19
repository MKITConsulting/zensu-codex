#!/usr/bin/env node
'use strict';

// Stable Session Control reader ABI v3 for Codex model-side commands. This file
// is create-exclusively published under ~/.zensu/session-control/codex/v3 and
// remains byte-stable for the lifetime of reader ABI v3. The immutable context
// record intentionally retains Session Control schema_version=1; reader ABI and
// record schema versions are independent.

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const HASH_DOMAIN = Buffer.from('zensu.session-control/v1/session-id\0', 'utf8');
const RUNTIME_DOMAIN = Buffer.from('zensu.session-control/v1/runtime-digest\0', 'utf8');
const MAX_JSON_BYTES = 1024 * 1024;
const MAX_RUNTIME_FILE_BYTES = 4 * 1024 * 1024;
const MAX_RUNTIME_TOTAL_BYTES = 64 * 1024 * 1024;
const MAX_RUNTIME_FILES = 10000;

function fail(message) {
  throw new Error(`session-control reader-abi-v3: ${message}`);
}

function requireText(value, label) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) {
    fail(`${label} is unavailable or unsafe`);
  }
  return value;
}

function canonicalDirectory(value, label) {
  requireText(value, label);
  let canonical;
  try {
    canonical = fs.realpathSync.native(value);
  } catch {
    fail(`${label} does not exist`);
  }
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail(`${label} must be a real directory`);
  }
  return canonical;
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function sameFileIdentity(left, right) {
  if (!left || !right) return false;
  const inodeKnown = left.ino !== 0 && right.ino !== 0;
  if (inodeKnown) return left.dev === right.dev && left.ino === right.ino;
  return left.birthtimeMs === right.birthtimeMs && left.mode === right.mode;
}

function readRegularFileSnapshot(file, maxBytes = MAX_JSON_BYTES) {
  const noFollow = Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
  let descriptor;
  let pathBefore = null;
  try {
    // Windows Node builds without O_NOFOLLOW use lstat/fstat identity checks
    // around open(). POSIX hosts reject a final-component symlink in open().
    if (noFollow === 0) {
      try {
        pathBefore = fs.lstatSync(file);
      } catch {
        fail(`missing file: ${file}`);
      }
      if (pathBefore.isSymbolicLink()) fail(`symlink file rejected: ${file}`);
    }
    try {
      descriptor = fs.openSync(file, fs.constants.O_RDONLY | noFollow);
    } catch (error) {
      if (error.code === 'ELOOP' || error.code === 'EMLINK') {
        fail(`symlink file rejected: ${file}`);
      }
      if (error.code === 'ENOENT') fail(`missing file: ${file}`);
      throw error;
    }
    const before = fs.fstatSync(descriptor);
    if (!before.isFile()) fail(`not a regular file: ${file}`);
    if (before.size > maxBytes) fail(`file exceeds size limit: ${file}`);
    if (pathBefore && !sameFileIdentity(pathBefore, before)) {
      fail(`file identity changed while opening: ${file}`);
    }

    const data = Buffer.alloc(before.size);
    let offset = 0;
    while (offset < data.length) {
      const read = fs.readSync(descriptor, data, offset, data.length - offset, null);
      if (read === 0) fail(`file changed while reading: ${file}`);
      offset += read;
    }

    const after = fs.fstatSync(descriptor);
    if (
      !sameFileIdentity(before, after)
      || before.size !== after.size
      || before.mtimeMs !== after.mtimeMs
      || before.ctimeMs !== after.ctimeMs
    ) {
      fail(`file changed while reading: ${file}`);
    }
    let pathAfter;
    try {
      pathAfter = fs.lstatSync(file);
    } catch {
      fail(`file path changed while reading: ${file}`);
    }
    if (pathAfter.isSymbolicLink() || !sameFileIdentity(after, pathAfter)) {
      fail(`file path changed while reading: ${file}`);
    }
    return { data, stat: after };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function readRegularFile(file, maxBytes = MAX_JSON_BYTES) {
  return readRegularFileSnapshot(file, maxBytes).data;
}

function privateDirectory(file) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch {
    fail('missing directory');
  }
  if (stat.isSymbolicLink()) {
    fail('directory must not be a symlink');
  }
  if (!stat.isDirectory()) fail('expected a directory');
  if (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) {
    fail('directory permissions are not private');
  }
  return stat;
}

function sessionSelector() {
  const key = requireText(process.env.ZENSU_SESSION_KEY, 'ZENSU_SESSION_KEY');
  const match = /^scv1_([a-f0-9]{64})$/.exec(key);
  if (!match) fail('ZENSU_SESSION_KEY has an invalid format');
  return { key, hash: match[1] };
}

function readJson(file, label, requirePrivate = true) {
  const snapshot = readRegularFileSnapshot(file);
  if (snapshot.data.length === 0) fail(`${label} must not be empty`);
  if (requirePrivate && process.platform !== 'win32' && (snapshot.stat.mode & 0o077) !== 0) {
    fail(`${label} permissions are not private`);
  }
  try {
    return JSON.parse(snapshot.data.toString('utf8'));
  } catch {
    fail(`${label} contains invalid JSON`);
  }
}

function manifestPath(pluginRoot) {
  return path.join(pluginRoot, '.codex-plugin', 'plugin.json');
}

function localManifestEntry(pluginRoot, value, label) {
  const raw = requireText(value, label)
    .replace(/^\$\{(?:CLAUDE_|CODEX_)?PLUGIN_ROOT\}/, pluginRoot);
  const candidate = path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(pluginRoot, raw);
  if (!isInside(pluginRoot, candidate)) fail(`${label} escapes plugin root`);
  if (!fs.existsSync(candidate)) fail(`${label} is missing: ${candidate}`);
  return candidate;
}

function manifestRuntimeEntries(pluginRoot, manifest) {
  const entries = new Set([manifestPath(pluginRoot)]);
  for (const directory of ['hooks', 'agents', 'skills', 'docs', 'templates']) {
    const candidate = path.join(pluginRoot, directory);
    if (fs.existsSync(candidate)) entries.add(candidate);
  }
  for (const file of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
    const candidate = path.join(pluginRoot, file);
    if (fs.existsSync(candidate)) entries.add(candidate);
  }

  const addReferences = (value, label) => {
    if (typeof value === 'string') {
      entries.add(localManifestEntry(pluginRoot, value, label));
      return;
    }
    if (Array.isArray(value)) {
      value.forEach((entry, index) => addReferences(entry, `${label}[${index}]`));
    }
  };
  for (const field of ['hooks', 'agents', 'skills', 'mcpServers']) {
    if (manifest[field] !== undefined) addReferences(manifest[field], `plugin manifest ${field}`);
  }

  if (manifest.mcpServers !== undefined) {
    for (const relative of ['scripts', 'mcp-runtime/package.json', 'mcp-runtime/package-lock.json']) {
      const candidate = path.join(pluginRoot, relative);
      if (fs.existsSync(candidate)) entries.add(candidate);
    }
  }
  return [...entries];
}

function collectRuntimeFiles(pluginRoot, manifest) {
  const files = new Map();
  const visit = (candidate) => {
    const stat = fs.lstatSync(candidate);
    if (stat.isSymbolicLink()) fail('runtime symlink rejected');
    if (stat.isFile()) {
      if (stat.size > MAX_RUNTIME_FILE_BYTES) fail('runtime file exceeds size limit');
      const relative = path.relative(pluginRoot, candidate).split(path.sep).join('/');
      files.set(relative, { file: candidate, size: stat.size });
      if (files.size > MAX_RUNTIME_FILES) fail('runtime file count exceeds limit');
      return;
    }
    if (!stat.isDirectory()) fail('unsupported runtime entry');
    for (const child of fs.readdirSync(candidate).sort()) {
      visit(path.join(candidate, child));
    }
  };
  for (const entry of manifestRuntimeEntries(pluginRoot, manifest)) visit(entry);
  return [...files.values()].sort((left, right) => {
    const a = path.relative(pluginRoot, left.file).split(path.sep).join('/');
    const b = path.relative(pluginRoot, right.file).split(path.sep).join('/');
    return a.localeCompare(b);
  });
}

function runtimeDigest(pluginRoot, manifest) {
  const digest = crypto.createHash('sha256').update(RUNTIME_DOMAIN);
  const files = collectRuntimeFiles(pluginRoot, manifest);
  let total = 0;
  for (const entry of files) {
    total += entry.size;
    if (total > MAX_RUNTIME_TOTAL_BYTES) fail('runtime assets exceed total size limit');
    const relative = path.relative(pluginRoot, entry.file).split(path.sep).join('/');
    const content = readRegularFile(entry.file, MAX_RUNTIME_FILE_BYTES);
    if (content.length !== entry.size) fail(`runtime file changed during digest: ${entry.file}`);
    digest.update(String(Buffer.byteLength(relative)), 'utf8');
    digest.update('\0');
    digest.update(relative, 'utf8');
    digest.update('\0');
    digest.update(String(content.length), 'utf8');
    digest.update('\0');
    digest.update(content);
    digest.update('\0');
  }
  return `sha256:${digest.digest('hex')}`;
}

function validateRecord(record, expectedHash, controlRoot) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) fail('record is not an object');
  if (record.schema !== 'zensu.session-control' || record.schema_version !== 1 || record.host !== 'codex') {
    fail('record schema or host mismatch');
  }
  if (record.session_id_hash !== `sha256:${expectedHash}`) fail('record session hash mismatch');
  if (
    !record.principal_profiles
    || record.principal_profiles.main !== 'main-v1'
    || record.principal_profiles.reviewer !== 'reviewer-readonly-v1'
    || record.principal_profiles.host !== 'host-profile-v1'
  ) {
    fail('record principal profiles are invalid');
  }
  const projectRoot = canonicalDirectory(record.project_root, 'record project root');
  const pluginRoot = canonicalDirectory(record.plugin_root, 'record plugin root');
  const pluginData = canonicalDirectory(record.plugin_data, 'record plugin data');
  if (projectRoot !== record.project_root || pluginRoot !== record.plugin_root || pluginData !== record.plugin_data) {
    fail('record paths are not canonical');
  }
  if (pluginData !== controlRoot) fail('record control root mismatch');
  const manifest = readJson(manifestPath(pluginRoot), 'plugin manifest', false);
  if (manifest.name !== 'zensu' || manifest.version !== record.plugin_version) {
    fail('plugin manifest identity or version mismatch');
  }
  if (!/^sha256:[a-f0-9]{64}$/.test(record.runtime_digest || '')) {
    fail('record runtime digest is invalid');
  }
  const actualRuntimeDigest = runtimeDigest(pluginRoot, manifest);
  if (actualRuntimeDigest !== record.runtime_digest) {
    fail('record runtime digest mismatch');
  }
  if (!/^sha256:[a-f0-9]{64}$/.test(record.source_revision || '')
      || record.source_revision !== actualRuntimeDigest) {
    fail('record source revision must equal the runtime content digest');
  }
  return record;
}

function renderMain(record) {
  return [
    '[zensu-session-context]',
    'schema_version=1',
    'host=codex',
    `session_id_hash=${record.session_id_hash}`,
    `project_root=${JSON.stringify(record.project_root)}`,
    `plugin_root=${JSON.stringify(record.plugin_root)}`,
    `runtime_digest=${record.runtime_digest}`,
    'principal=main-v1',
  ].join(' ');
}

function renderReviewer(record) {
  return [
    '[zensu-reviewer-context]',
    'schema_version=1',
    'host=codex',
    `session_id_hash=${record.session_id_hash}`,
    `project_root=${JSON.stringify(record.project_root)}`,
    `plugin_root=${JSON.stringify(record.plugin_root)}`,
    `runtime_digest=${record.runtime_digest}`,
    'principal=reviewer-readonly-v1.',
    'The reviewer must not write, spawn, mutate workflow state, invoke mutating control or MCP tools, or impersonate main.',
  ].join(' ');
}

function parseMode(argv) {
  if (argv.length === 0 || (argv.length === 1 && argv[0] === '--root')) return { mode: 'root' };
  if (argv.length === 1 && argv[0] === '--context') return { mode: 'context' };
  if (argv.length === 1 && argv[0] === '--review-context') return { mode: 'review-context' };
  if (argv.length === 2 && argv[0] === '--field') return { mode: 'field', field: argv[1] };
  fail('usage: resolve-v3.js [--root|--context|--review-context|--field NAME]');
}

function main() {
  const mode = parseMode(process.argv.slice(2));
  const home = canonicalDirectory(process.env.HOME, 'HOME');
  const controlRoot = path.join(home, '.zensu', 'session-control', 'codex', 'v3');
  privateDirectory(path.join(home, '.zensu'));
  privateDirectory(path.join(home, '.zensu', 'session-control'));
  privateDirectory(path.join(home, '.zensu', 'session-control', 'codex'));
  privateDirectory(controlRoot);
  const records = path.join(controlRoot, 'records');
  privateDirectory(records);

  const selector = sessionSelector();
  const record = validateRecord(
    readJson(path.join(records, `${selector.key}.json`), 'session context record'),
    selector.hash,
    fs.realpathSync.native(controlRoot),
  );

  if (mode.mode === 'root') process.stdout.write(`${record.plugin_root}\n`);
  else if (mode.mode === 'context') process.stdout.write(`${renderMain(record)}\n`);
  else if (mode.mode === 'review-context') process.stdout.write(`${renderReviewer(record)}\n`);
  else {
    const allowed = new Set([
      'host',
      'session_id_hash',
      'project_root',
      'plugin_root',
      'plugin_version',
      'runtime_digest',
      'source_revision',
    ]);
    if (!allowed.has(mode.field) || typeof record[mode.field] !== 'string') fail('unsupported context field');
    process.stdout.write(`${record[mode.field]}\n`);
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
