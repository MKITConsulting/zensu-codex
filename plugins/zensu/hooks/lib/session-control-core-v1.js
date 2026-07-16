'use strict';

const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const SCHEMA = 'zensu.session-control';
const SCHEMA_VERSION = 1;
const WORKFLOW_SCHEMA = 'zensu.workflow-state';
const ATTESTATION_SCHEMA = 'zensu.control-attestation';
const HASH_DOMAIN = Buffer.from('zensu.session-control/v1/session-id\0', 'utf8');
const RUNTIME_DOMAIN = Buffer.from('zensu.session-control/v1/runtime-digest\0', 'utf8');
const SESSION_KEY_RE = /^scv1_([a-f0-9]{64})$/;
const HASH_RE = /^sha256:([a-f0-9]{64})$/;
const HOSTS = new Set(['codex', 'claude']);
const MAX_RUNTIME_FILES = 10000;
const MAX_RUNTIME_FILE_BYTES = 4 * 1024 * 1024;
const MAX_RUNTIME_TOTAL_BYTES = 64 * 1024 * 1024;
const MAX_JSON_BYTES = 1024 * 1024;
const LOCK_STALE_MS = 30000;
const LOCK_TOKEN_RE = /^[a-f0-9]{48}$/;
const LOCK_IDENTITY_RE = /^[a-z0-9._:-]{1,160}$/;
const WORKFLOW_RESERVED_FIELDS = new Set([
  'schema',
  'schema_version',
  'session_id',
  'session_id_hash',
  'workflow_state',
  'revision',
  'last_event',
  'updated_at',
  'actor',
]);

function fail(message) {
  throw new Error(`session-control-v1: ${message}`);
}

function requireText(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} must be a non-empty string`);
  }
  return value;
}

function requireHost(host) {
  requireText(host, 'host');
  if (!HOSTS.has(host)) {
    fail(`unsupported host "${host}"`);
  }
  return host;
}

function sessionIdHash(sessionId) {
  const value = requireText(sessionId, 'session id');
  const keyMatch = SESSION_KEY_RE.exec(value);
  if (keyMatch) {
    return `sha256:${keyMatch[1]}`;
  }
  const hashMatch = HASH_RE.exec(value);
  if (hashMatch) {
    return value;
  }
  const digest = crypto.createHash('sha256').update(HASH_DOMAIN).update(value, 'utf8').digest('hex');
  return `sha256:${digest}`;
}

function sessionKey(sessionId) {
  const value = requireText(sessionId, 'session id');
  const keyMatch = SESSION_KEY_RE.exec(value);
  if (keyMatch) {
    return value;
  }
  return `scv1_${sessionIdHash(value).slice('sha256:'.length)}`;
}

function canonicalDirectory(input, label) {
  const value = requireText(input, label);
  if (/[\0\r\n]/.test(value)) {
    fail(`${label} is unsafe`);
  }
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

function ensureDescendantDirectory(baseInput, targetInput) {
  const base = canonicalDirectory(baseInput, 'directory base');
  const requestedBase = path.resolve(baseInput);
  const requestedTarget = path.resolve(targetInput);
  const target = isInside(requestedBase, requestedTarget)
    ? path.join(base, path.relative(requestedBase, requestedTarget))
    : requestedTarget;
  if (!isInside(base, target)) {
    fail('directory target escapes its trusted base');
  }
  const relative = path.relative(base, target);
  let current = base;
  if (relative === '') {
    return current;
  }
  for (const part of relative.split(path.sep)) {
    current = path.join(current, part);
    if (!fs.existsSync(current)) {
      try {
        fs.mkdirSync(current, { mode: 0o700 });
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
      }
    }
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) {
      fail(`symlink directory rejected: ${current}`);
    }
    if (!stat.isDirectory()) {
      fail(`expected directory: ${current}`);
    }
  }
  return current;
}

function sameFileIdentity(left, right) {
  if (!left || !right) return false;
  const inodeKnown = left.ino !== 0 && right.ino !== 0;
  if (inodeKnown) return left.dev === right.dev && left.ino === right.ino;
  return left.birthtimeMs === right.birthtimeMs && left.mode === right.mode;
}

function readRegularFileSnapshot(
  file,
  maxBytes = MAX_JSON_BYTES,
  missingAllowed = false,
  allowMultipleLinks = false,
) {
  const noFollow = Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
  let descriptor;
  let pathBefore = null;
  const parent = path.dirname(file);
  const parentBefore = fs.lstatSync(parent);
  if (parentBefore.isSymbolicLink() || !parentBefore.isDirectory()) {
    fail(`unsafe parent directory: ${parent}`);
  }
  try {
    // O_NOFOLLOW is not available on every Windows Node build. In that case,
    // bracket open() with lstat/fstat identity checks instead of trusting the
    // path lookup performed before the descriptor exists.
    if (noFollow === 0) {
      try {
        pathBefore = fs.lstatSync(file);
      } catch (error) {
        if (missingAllowed && error.code === 'ENOENT') return null;
        throw error;
      }
      if (pathBefore.isSymbolicLink()) fail(`symlink file rejected: ${file}`);
    }
    try {
      descriptor = fs.openSync(file, fs.constants.O_RDONLY | noFollow);
    } catch (error) {
      if (missingAllowed && error.code === 'ENOENT') return null;
      if (error.code === 'ELOOP' || error.code === 'EMLINK') {
        fail(`symlink file rejected: ${file}`);
      }
      if (error.code === 'ENOENT') fail(`missing file: ${file}`);
      throw error;
    }

    const before = fs.fstatSync(descriptor);
    if (!before.isFile()) fail(`not a regular file: ${file}`);
    if (!allowMultipleLinks && before.nlink > 1) fail(`multi-linked file rejected: ${file}`);
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
    } catch (error) {
      if (error.code === 'ENOENT') fail(`file path changed while reading: ${file}`);
      throw error;
    }
    if (pathAfter.isSymbolicLink() || !sameFileIdentity(after, pathAfter)) {
      fail(`file path changed while reading: ${file}`);
    }
    const parentAfter = fs.lstatSync(parent);
    if (
      parentAfter.isSymbolicLink()
      || !parentAfter.isDirectory()
      || !sameFileIdentity(parentBefore, parentAfter)
    ) {
      fail(`parent directory changed while reading: ${file}`);
    }
    return { data, stat: after };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function readRegularFile(file, maxBytes = MAX_JSON_BYTES) {
  return readRegularFileSnapshot(file, maxBytes).data;
}

function readJson(file) {
  const data = readRegularFile(file);
  try {
    return JSON.parse(data.toString('utf8'));
  } catch {
    fail(`invalid JSON: ${file}`);
  }
}

function manifestPath(pluginRoot, host) {
  const manifestDirectory = requireHost(host) === 'codex' ? '.codex-plugin' : '.claude-plugin';
  return path.join(pluginRoot, manifestDirectory, 'plugin.json');
}

function pluginMetadata(pluginRootInput, host) {
  const pluginRoot = canonicalDirectory(pluginRootInput, 'plugin root');
  const file = manifestPath(pluginRoot, host);
  if (!fs.existsSync(file)) {
    fail(`host-specific plugin manifest is missing: ${file}`);
  }
  const manifest = readJson(file);
  if (manifest.name !== 'zensu') {
    fail('plugin manifest must identify zensu');
  }
  requireText(manifest.version, 'plugin version');
  return { pluginRoot, manifest, manifestFile: file };
}

function localManifestEntry(pluginRoot, value, label) {
  const raw = requireText(value, label)
    .replace(/^\$\{(?:CLAUDE_|CODEX_)?PLUGIN_ROOT\}/, pluginRoot);
  const candidate = path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(pluginRoot, raw);
  if (!isInside(pluginRoot, candidate)) {
    fail(`${label} escapes plugin root`);
  }
  if (!fs.existsSync(candidate)) {
    fail(`${label} is missing: ${candidate}`);
  }
  return candidate;
}

function manifestRuntimeEntries(pluginRoot, host, manifest) {
  const entries = new Set([manifestPath(pluginRoot, host)]);
  for (const directory of ['hooks', 'agents', 'skills', 'docs', 'templates']) {
    const candidate = path.join(pluginRoot, directory);
    if (fs.existsSync(candidate)) {
      entries.add(candidate);
    }
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
    if (manifest[field] !== undefined) {
      addReferences(manifest[field], `plugin manifest ${field}`);
    }
  }

  // MCP manifests activate executable plugin runtime outside hooks/agents/skills.
  // Include the launcher scripts and their lockfile-backed metadata so an active
  // session detects changes to every byte that can affect the launched server.
  if (manifest.mcpServers !== undefined) {
    for (const relative of ['scripts', 'mcp-runtime/package.json', 'mcp-runtime/package-lock.json']) {
      const candidate = path.join(pluginRoot, relative);
      if (fs.existsSync(candidate)) entries.add(candidate);
    }
  }
  return [...entries];
}

function collectRuntimeFiles(pluginRoot, host, manifest) {
  const entries = manifestRuntimeEntries(pluginRoot, host, manifest);

  const files = new Map();
  const visit = (candidate) => {
    const stat = fs.lstatSync(candidate);
    if (stat.isSymbolicLink()) {
      fail(`runtime symlink rejected: ${candidate}`);
    }
    if (stat.isFile()) {
      if (stat.size > MAX_RUNTIME_FILE_BYTES) {
        fail(`runtime file exceeds size limit: ${candidate}`);
      }
      const relative = path.relative(pluginRoot, candidate).split(path.sep).join('/');
      files.set(relative, { file: candidate, size: stat.size });
      if (files.size > MAX_RUNTIME_FILES) {
        fail('runtime file count exceeds limit');
      }
      return;
    }
    if (!stat.isDirectory()) {
      fail(`unsupported runtime entry: ${candidate}`);
    }
    const children = fs.readdirSync(candidate).sort();
    for (const child of children) {
      visit(path.join(candidate, child));
    }
  };

  for (const entry of entries) {
    visit(entry);
  }
  return [...files.values()].sort((left, right) => {
    const a = path.relative(pluginRoot, left.file).split(path.sep).join('/');
    const b = path.relative(pluginRoot, right.file).split(path.sep).join('/');
    return a.localeCompare(b);
  });
}

function computeRuntimeDigest(pluginRootInput, hostInput) {
  const host = requireHost(hostInput);
  const { pluginRoot, manifest } = pluginMetadata(pluginRootInput, host);
  const files = collectRuntimeFiles(pluginRoot, host, manifest);
  const digest = crypto.createHash('sha256').update(RUNTIME_DOMAIN);
  let totalBytes = 0;
  for (const entry of files) {
    totalBytes += entry.size;
    if (totalBytes > MAX_RUNTIME_TOTAL_BYTES) {
      fail('runtime assets exceed total size limit');
    }
    const relative = path.relative(pluginRoot, entry.file).split(path.sep).join('/');
    const content = readRegularFile(entry.file, MAX_RUNTIME_FILE_BYTES);
    if (content.length !== entry.size) {
      fail(`runtime file changed during digest: ${entry.file}`);
    }
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

function nowIso() {
  return new Date().toISOString();
}

function buildContext(options) {
  const host = requireHost(options.host);
  const projectRoot = canonicalDirectory(options.projectRoot, 'project root');
  const { pluginRoot, manifest } = pluginMetadata(options.pluginRoot, host);
  const pluginData = canonicalDirectory(options.pluginData, 'plugin data');
  const createdAt = options.createdAt || nowIso();
  if (!Number.isFinite(Date.parse(createdAt))) {
    fail('createdAt must be an ISO-compatible timestamp');
  }
  if (Object.prototype.hasOwnProperty.call(options, 'sourceRevision')
      || Object.prototype.hasOwnProperty.call(options, 'sourceRevisionAuthority')) {
    fail('source revision overrides are unsupported; source_revision is the runtime content digest');
  }
  // Compute the runtime identity exactly once. Session provenance is always
  // content-addressed; Git identity belongs only in wrapper-owned evidence.
  const runtimeDigest = computeRuntimeDigest(pluginRoot, host);

  return {
    schema: SCHEMA,
    schema_version: SCHEMA_VERSION,
    host,
    session_id_hash: sessionIdHash(options.sessionId),
    project_root: projectRoot,
    plugin_root: pluginRoot,
    plugin_data: pluginData,
    plugin_version: manifest.version,
    source_revision: runtimeDigest,
    runtime_digest: runtimeDigest,
    created_at: createdAt,
    principal_profiles: {
      main: 'main-v1',
      reviewer: 'reviewer-readonly-v1',
      host: 'host-profile-v1',
    },
  };
}

function validateContext(context, expectedHost) {
  if (!context || typeof context !== 'object' || Array.isArray(context)) {
    fail('context record must be an object');
  }
  if (context.schema !== SCHEMA || context.schema_version !== SCHEMA_VERSION) {
    fail('context schema mismatch');
  }
  requireHost(context.host);
  if (expectedHost && context.host !== expectedHost) {
    fail('context host mismatch');
  }
  if (!HASH_RE.test(context.session_id_hash || '')) {
    fail('context session hash is invalid');
  }
  if (
    !context.principal_profiles
    || context.principal_profiles.main !== 'main-v1'
    || context.principal_profiles.reviewer !== 'reviewer-readonly-v1'
    || context.principal_profiles.host !== 'host-profile-v1'
  ) {
    fail('context principal profiles are invalid');
  }
  for (const field of ['project_root', 'plugin_root', 'plugin_data', 'plugin_version', 'runtime_digest', 'created_at', 'source_revision']) {
    requireText(context[field], `context ${field}`);
  }
  canonicalDirectory(context.project_root, 'context project root');
  canonicalDirectory(context.plugin_root, 'context plugin root');
  canonicalDirectory(context.plugin_data, 'context plugin data');
  if (!HASH_RE.test(context.runtime_digest)) {
    fail('context runtime digest is invalid');
  }
  if (!HASH_RE.test(context.source_revision) || context.source_revision !== context.runtime_digest) {
    fail('context source revision must equal its runtime content digest');
  }
  return context;
}

function contextRecordFile(recordsDir, sessionId) {
  return path.join(recordsDir, `${sessionKey(sessionId)}.json`);
}

function sleep(milliseconds) {
  const buffer = new SharedArrayBuffer(4);
  Atomics.wait(new Int32Array(buffer), 0, 0, milliseconds);
}

function processStartIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null;
  try {
    if (process.platform === 'linux') {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
      const commandEnd = stat.lastIndexOf(')');
      if (commandEnd < 0) return null;
      const fields = stat.slice(commandEnd + 2).trim().split(/\s+/);
      const startTicks = fields[19];
      if (!startTicks || !/^\d+$/.test(startTicks)) return null;
      let bootId = 'unknown-boot';
      try {
        bootId = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
      } catch {
        // startTicks is still stronger than PID-only ownership on Linux.
      }
      const identity = `linux:${bootId}:${startTicks}`;
      return LOCK_IDENTITY_RE.test(identity) ? identity : null;
    }
    if (process.platform !== 'win32') {
      const started = execFileSync('ps', ['-p', String(pid), '-o', 'lstart='], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: 1000,
      }).trim();
      if (!started) return null;
      return `${process.platform}:${crypto.createHash('sha256').update(started).digest('hex')}`;
    }
  } catch {
    // A platform or permission that cannot expose process start identity falls
    // back to conservative PID liveness. It never treats uncertainty as dead.
  }
  return null;
}

let ownProcessStartIdentity;
function currentProcessStartIdentity() {
  if (ownProcessStartIdentity === undefined) {
    ownProcessStartIdentity = processStartIdentity(process.pid) || null;
  }
  return ownProcessStartIdentity;
}

function lockOwner(file) {
  let snapshot = null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      snapshot = readRegularFileSnapshot(file, 4096, true, true);
      break;
    } catch (error) {
      if (!/file (?:path )?changed while reading|missing file/i.test(error.message)) throw error;
      try {
        fs.lstatSync(file);
      } catch (statError) {
        if (statError.code === 'ENOENT') return null;
        throw statError;
      }
    }
  }
  if (!snapshot) {
    // Lock artifacts are intentionally short-lived. A generation that changes
    // throughout all descriptor reads is treated as contended, never stale;
    // createOwnedArtifact() still prevents entry while its path exists.
    return null;
  }
  let owner = null;
  try {
    owner = JSON.parse(snapshot.data.toString('utf8'));
  } catch {
    // Corrupt artifacts fail closed while fresh and can only be reclaimed
    // after the stale threshold using inode identity below.
  }
  if (
    !owner
    || !Number.isSafeInteger(owner.pid)
    || owner.pid <= 0
    || typeof owner.token !== 'string'
    || !LOCK_TOKEN_RE.test(owner.token)
    || !Number.isFinite(Date.parse(owner.created_at || ''))
    || (
      owner.process_start_identity !== undefined
      && owner.process_start_identity !== null
      && (
        typeof owner.process_start_identity !== 'string'
        || !LOCK_IDENTITY_RE.test(owner.process_start_identity)
      )
    )
  ) owner = null;
  return { stat: snapshot.stat, owner };
}

function processIsAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function sameArtifact(left, right) {
  if (!left || !right) return false;
  if (!sameFileIdentity(left.stat, right.stat)) return false;
  if (left.owner && right.owner && left.owner.token !== right.owner.token) return false;
  if (Boolean(left.owner) !== Boolean(right.owner)) return false;
  return left.stat.size === right.stat.size;
}

function removeArtifactIfSame(file, snapshot) {
  let current;
  try {
    current = lockOwner(file);
  } catch {
    return false;
  }
  if (!sameArtifact(current, snapshot)) return false;
  const quarantine = path.join(
    path.dirname(file),
    `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(24).toString('hex')}.quarantine`,
  );
  try {
    fs.renameSync(file, quarantine);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return false;
  }
  const quarantined = lockOwner(quarantine);
  if (!sameArtifact(quarantined, snapshot)) {
    // rename() may have moved a replacement that won after the first identity
    // check. Restore it with a no-clobber hard link and never delete it.
    try {
      fs.linkSync(quarantine, file);
      fs.unlinkSync(quarantine);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      fail('lock replacement race could not be restored safely');
    }
    return false;
  }
  fs.unlinkSync(quarantine);
  return true;
}

function createOwnedArtifact(file, kind) {
  const directory = path.dirname(file);
  const token = crypto.randomBytes(24).toString('hex');
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${token}.candidate`);
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, JSON.stringify({
      pid: process.pid,
      token,
      kind,
      created_at: nowIso(),
      process_start_identity: currentProcessStartIdentity(),
    }));
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.linkSync(temporary, file);
    const snapshot = lockOwner(file);
    if (!snapshot || !snapshot.owner || snapshot.owner.token !== token) {
      fail('new lock identity could not be verified');
    }
    return snapshot;
  } catch (error) {
    if (error.code === 'EEXIST') return null;
    throw error;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try {
      fs.unlinkSync(temporary);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
}

function artifactIsStale(snapshot) {
  if (!snapshot) return false;
  if (!snapshot.owner) {
    return Date.now() - snapshot.stat.mtimeMs > LOCK_STALE_MS;
  }
  if (!processIsAlive(snapshot.owner.pid)) return true;
  if (snapshot.owner.process_start_identity) {
    const actual = snapshot.owner.pid === process.pid
      ? currentProcessStartIdentity()
      : processStartIdentity(snapshot.owner.pid);
    if (actual && actual !== snapshot.owner.process_start_identity) return true;
  }
  return false;
}

function reclaimStaleArtifact(file) {
  const snapshot = lockOwner(file);
  if (!artifactIsStale(snapshot)) return false;
  return removeArtifactIfSame(file, snapshot);
}

function withRecoverySentinel(lockDirectory, key, callback) {
  const recoveryFile = path.join(lockDirectory, `.${key}.recovery`);
  let recovery = null;
  for (let attempt = 0; attempt < 500; attempt += 1) {
    if (fs.existsSync(recoveryFile)) reclaimStaleArtifact(recoveryFile);
    recovery = createOwnedArtifact(recoveryFile, 'recovery');
    if (recovery) break;
    sleep(20);
  }
  if (!recovery) fail('timed out acquiring recovery sentinel');
  try {
    return callback();
  } finally {
    if (!removeArtifactIfSame(recoveryFile, recovery)) {
      fail('recovery sentinel ownership changed');
    }
  }
}

function recoverStaleLock(lockDirectory, key, lockFile) {
  return withRecoverySentinel(lockDirectory, key, () => {
    const current = lockOwner(lockFile);
    if (artifactIsStale(current) && !removeArtifactIfSame(lockFile, current)) {
      fail('stale lock identity changed during recovery');
    }
  });
}

function releaseOwnedLock(lockDirectory, key, lockFile, acquired) {
  return withRecoverySentinel(lockDirectory, key, () => {
    const current = lockOwner(lockFile);
    if (!sameArtifact(current, acquired)) {
      fail('lock ownership changed before release');
    }
    if (!removeArtifactIfSame(lockFile, acquired)) {
      fail('lock identity changed during release');
    }
  });
}

function withFileLock(lockDirectory, key, callback) {
  const directory = canonicalDirectory(lockDirectory, 'lock directory');
  if (!/^[a-zA-Z0-9._-]{1,160}$/.test(key)) fail('lock key has an invalid format');
  if (typeof callback !== 'function') fail('lock callback must be a function');
  const lockFile = path.join(directory, `.${key}.lock`);
  const recoveryFile = path.join(directory, `.${key}.recovery`);
  let acquired;
  for (let attempt = 0; attempt < 500; attempt += 1) {
    if (fs.existsSync(recoveryFile)) {
      reclaimStaleArtifact(recoveryFile);
      sleep(20);
      continue;
    }
    acquired = createOwnedArtifact(lockFile, 'lock');
    if (acquired) {
      // A recovery owner may have won immediately after our pre-check. Do not
      // enter the critical section until that generation has completed.
      if (!fs.existsSync(recoveryFile)) break;
      releaseOwnedLock(directory, key, lockFile, acquired);
      acquired = undefined;
    } else {
      recoverStaleLock(directory, key, lockFile);
    }
    sleep(20);
  }
  if (!acquired) {
    fail('timed out acquiring per-session lock');
  }
  try {
    return callback();
  } finally {
    releaseOwnedLock(directory, key, lockFile, acquired);
  }
}

function contextComparable(context) {
  return {
    schema: context.schema,
    schema_version: context.schema_version,
    host: context.host,
    session_id_hash: context.session_id_hash,
    project_root: context.project_root,
    plugin_root: context.plugin_root,
    plugin_data: context.plugin_data,
    plugin_version: context.plugin_version,
    source_revision: context.source_revision,
    runtime_digest: context.runtime_digest,
    principal_profiles: context.principal_profiles,
  };
}

function registerContext(options) {
  const pluginData = canonicalDirectory(options.pluginData, 'plugin data');
  const recordsDir = ensureDescendantDirectory(options.pluginData, options.recordsDir);
  const locksDir = ensureDescendantDirectory(pluginData, path.join(path.dirname(recordsDir), 'locks'));
  const key = sessionKey(options.sessionId);
  const file = contextRecordFile(recordsDir, key);

  return withFileLock(locksDir, key, () => {
    if (fs.existsSync(file)) {
      const existing = validateContext(readJson(file), options.host);
      const expected = buildContext({ ...options, createdAt: existing.created_at });
      if (JSON.stringify(contextComparable(existing)) !== JSON.stringify(contextComparable(expected))) {
        fail('immutable session context mismatch');
      }
      return existing;
    }

    const context = buildContext(options);
    atomicCreateJson(file, context);
    return context;
  });
}

function readContext(options) {
  const recordsDirInput = requireText(options.recordsDir, 'records directory');
  if (!fs.existsSync(recordsDirInput)) {
    fail('context record directory is missing');
  }
  const recordsDir = canonicalDirectory(recordsDirInput, 'records directory');
  const file = contextRecordFile(recordsDir, options.sessionId);
  const context = validateContext(readJson(file), options.expectedHost);
  if (context.session_id_hash !== sessionIdHash(options.sessionId)) {
    fail('context session hash mismatch');
  }
  const currentDigest = computeRuntimeDigest(context.plugin_root, context.host);
  if (currentDigest !== context.runtime_digest) {
    fail('context runtime digest mismatch');
  }
  const { manifest } = pluginMetadata(context.plugin_root, context.host);
  if (manifest.version !== context.plugin_version) {
    fail('context plugin version mismatch');
  }
  return context;
}

function renderMainContext(contextInput) {
  const context = validateContext(contextInput);
  return [
    '[zensu-session-context]',
    `schema_version=${context.schema_version}`,
    `host=${context.host}`,
    `session_id_hash=${context.session_id_hash}`,
    `project_root=${JSON.stringify(context.project_root)}`,
    `plugin_root=${JSON.stringify(context.plugin_root)}`,
    `runtime_digest=${context.runtime_digest}`,
    'principal=main-v1',
  ].join(' ');
}

function renderReviewerContext(contextInput) {
  const context = validateContext(contextInput);
  return [
    '[zensu-reviewer-context]',
    `schema_version=${context.schema_version}`,
    `host=${context.host}`,
    `session_id_hash=${context.session_id_hash}`,
    `project_root=${JSON.stringify(context.project_root)}`,
    `plugin_root=${JSON.stringify(context.plugin_root)}`,
    `runtime_digest=${context.runtime_digest}`,
    'principal=reviewer-readonly-v1.',
    'The reviewer must not write, spawn, mutate workflow state, invoke mutating control or MCP tools, or impersonate main.',
  ].join(' ');
}

function renderHostContext(contextInput) {
  const context = validateContext(contextInput);
  return [
    '[zensu-host-context]',
    `schema_version=${context.schema_version}`,
    `host=${context.host}`,
    `project_root=${JSON.stringify(context.project_root)}`,
    `runtime_digest=${context.runtime_digest}`,
    'principal=host-profile-v1.',
    'No session selector or installed plugin path is disclosed to this neutral principal.',
    'This neutral agent must not use shell/control tools, access Session Control or workflow-root state, spawn another agent, or claim main-v1.',
  ].join(' ');
}

function workflowStateDirectory(projectRootInput) {
  const projectRoot = canonicalDirectory(projectRootInput, 'project root');
  const zensuDirectory = ensureDescendantDirectory(projectRoot, path.join(projectRoot, '.zensu'));
  return ensureDescendantDirectory(zensuDirectory, path.join(zensuDirectory, 'state'));
}

function resolveWorkflowStateDirectory(options) {
  if (options.stateDirectory !== undefined) {
    fail('workflow state directory overrides are unsupported');
  }
  return workflowStateDirectory(options.projectRoot);
}

function workflowStateFile(projectRoot, sessionId) {
  return path.join(
    workflowStateDirectory(projectRoot),
    `tdd-phase-${sessionKey(sessionId)}.json`,
  );
}

function validateWorkflowToken(value, label) {
  requireText(value, label);
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(value)) {
    fail(`${label} has an invalid format`);
  }
  return value;
}

const WORKFLOW_BOOLEAN_EXTENSIONS = [
  'active',
  'vanilla',
  'implComplete',
  'chainDone',
  'codeReviewDone',
  'selfReviewFixed',
  'workflowActive',
];

const WORKFLOW_INTEGER_EXTENSIONS = [
  'reviewRound',
  'stopBlocks',
];

function validateWorkflowString(value, label, allowEmpty = false) {
  if (
    typeof value !== 'string'
    || (!allowEmpty && value.length === 0)
    || /[\u0000-\u001f\u007f]/.test(value)
  ) {
    fail(`${label} is invalid`);
  }
  return value;
}

function validateWorkflowExtensions(state) {
  for (const field of WORKFLOW_BOOLEAN_EXTENSIONS) {
    if (Object.prototype.hasOwnProperty.call(state, field) && typeof state[field] !== 'boolean') {
      fail(`workflow extension ${field} must be boolean`);
    }
  }

  for (const field of WORKFLOW_INTEGER_EXTENSIONS) {
    if (
      Object.prototype.hasOwnProperty.call(state, field)
      && (!Number.isSafeInteger(state[field]) || state[field] < 0 || state[field] > 1000000)
    ) {
      fail(`workflow extension ${field} must be a bounded non-negative integer`);
    }
  }

  if (Object.prototype.hasOwnProperty.call(state, 'phase')) {
    validateWorkflowString(state.phase, 'workflow phase');
  }
  if (Object.prototype.hasOwnProperty.call(state, 'step_id')) {
    validateWorkflowString(state.step_id, 'workflow step_id', true);
  }

  if (Object.prototype.hasOwnProperty.call(state, 'history')) {
    if (!Array.isArray(state.history)) fail('workflow history must be an array');
    for (const [index, entry] of state.history.entries()) {
      if (
        !entry
        || typeof entry !== 'object'
        || Array.isArray(entry)
        || (Object.getPrototypeOf(entry) !== Object.prototype && Object.getPrototypeOf(entry) !== null)
      ) {
        fail(`workflow history entry ${index} must be an object`);
      }
      validateWorkflowString(entry.step, `workflow history entry ${index} step`, true);
      validateWorkflowString(entry.phase, `workflow history entry ${index} phase`);
      if (Object.prototype.hasOwnProperty.call(entry, 'ts')) {
        if (typeof entry.ts !== 'string' || !Number.isFinite(Date.parse(entry.ts))) {
          fail(`workflow history entry ${index} timestamp is invalid`);
        }
      }
      if (Object.prototype.hasOwnProperty.call(entry, 'reason') && typeof entry.reason !== 'string') {
        fail(`workflow history entry ${index} reason must be a string`);
      }
    }
  }

  for (const field of ['workflowTools', 'bypasses']) {
    if (!Object.prototype.hasOwnProperty.call(state, field)) continue;
    if (!Array.isArray(state[field])) fail(`workflow extension ${field} must be an array`);
    for (const [index, value] of state[field].entries()) {
      validateWorkflowString(value, `workflow extension ${field}[${index}]`);
    }
  }
}

function stampWorkflowState(
  input,
  sessionId,
  workflowStateInput,
  eventInput,
  updatedAtInput,
  authoritativePreviousRevision,
) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    fail('workflow state must be an object');
  }
  const workflowState = validateWorkflowToken(workflowStateInput, 'workflow state');
  const event = validateWorkflowToken(eventInput, 'workflow event');
  const hash = sessionIdHash(sessionId);
  if (input.revision !== undefined && (!Number.isSafeInteger(input.revision) || input.revision < 0)) {
    fail('workflow revision is invalid');
  }
  const previousRevision = authoritativePreviousRevision === undefined
    ? (input.revision || 0)
    : authoritativePreviousRevision;
  if (!Number.isSafeInteger(previousRevision) || previousRevision < 0) {
    fail('workflow revision is invalid');
  }
  if (previousRevision === Number.MAX_SAFE_INTEGER) {
    fail('workflow revision overflow');
  }
  const updatedAt = updatedAtInput || nowIso();
  if (!Number.isFinite(Date.parse(updatedAt))) {
    fail('updatedAt must be an ISO-compatible timestamp');
  }
  const extension = {};
  for (const [field, value] of Object.entries(input)) {
    if (!WORKFLOW_RESERVED_FIELDS.has(field)) extension[field] = value;
  }
  const next = {
    ...extension,
    schema: WORKFLOW_SCHEMA,
    schema_version: SCHEMA_VERSION,
    session_id_hash: hash,
    workflow_state: workflowState,
    revision: previousRevision + 1,
    last_event: event,
    updated_at: updatedAt,
    actor: 'main-v1',
  };
  return validateWorkflowState(next, sessionId);
}

function validateWorkflowState(state, sessionId) {
  if (
    !state
    || typeof state !== 'object'
    || Array.isArray(state)
    || state.schema !== WORKFLOW_SCHEMA
    || state.schema_version !== SCHEMA_VERSION
  ) {
    fail('workflow state schema mismatch');
  }
  if (state.session_id_hash !== sessionIdHash(sessionId)) {
    fail('workflow session hash mismatch');
  }
  if (!Number.isSafeInteger(state.revision) || state.revision < 1) {
    fail('workflow revision is invalid');
  }
  validateWorkflowToken(state.workflow_state, 'workflow state');
  validateWorkflowToken(state.last_event, 'workflow event');
  if (typeof state.updated_at !== 'string' || !Number.isFinite(Date.parse(state.updated_at))) {
    fail('workflow updated_at is invalid');
  }
  if (state.actor !== 'main-v1') {
    fail('workflow actor is invalid');
  }
  if (Object.prototype.hasOwnProperty.call(state, 'session_id')) {
    fail('raw session identifier is forbidden in workflow state');
  }
  validateWorkflowExtensions(state);
  return state;
}

function atomicWriteJson(file, value) {
  if (fs.existsSync(file)) {
    const existing = fs.lstatSync(file);
    if (existing.isSymbolicLink()) fail('symlink state file rejected');
    if (!existing.isFile()) fail('non-regular state file rejected');
    if (existing.nlink > 1) fail('multi-linked state file rejected');
  }
  const temporary = path.join(
    path.dirname(file),
    `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`,
  );
  const parent = path.dirname(file);
  const parentBefore = fs.lstatSync(parent);
  if (parentBefore.isSymbolicLink() || !parentBefore.isDirectory()) {
    fail(`unsafe state parent directory: ${parent}`);
  }
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    const parentAtCommit = fs.lstatSync(parent);
    if (
      parentAtCommit.isSymbolicLink()
      || !parentAtCommit.isDirectory()
      || !sameFileIdentity(parentBefore, parentAtCommit)
    ) {
      fail(`state parent directory changed before commit: ${file}`);
    }
    fs.renameSync(temporary, file);
    const parentAfter = fs.lstatSync(parent);
    if (!sameFileIdentity(parentBefore, parentAfter)) {
      fail(`state parent directory changed during commit: ${file}`);
    }
  } finally {
    if (descriptor !== undefined) {
      fs.closeSync(descriptor);
    }
    try {
      fs.unlinkSync(temporary);
    } catch {
      // The successful rename removes the temporary path.
    }
  }
}

function atomicCreateJson(file, value) {
  const parent = path.dirname(file);
  const parentBefore = fs.lstatSync(parent);
  if (parentBefore.isSymbolicLink() || !parentBefore.isDirectory()) {
    fail(`unsafe immutable-record parent directory: ${parent}`);
  }
  const temporary = path.join(
    parent,
    `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.candidate`,
  );
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    const parentAtCommit = fs.lstatSync(parent);
    if (!sameFileIdentity(parentBefore, parentAtCommit)) {
      fail(`immutable-record parent changed before commit: ${file}`);
    }
    try {
      // link(2) is an atomic no-clobber publication on the same filesystem.
      // Unlike rename(2), it cannot replace a planted symlink or another
      // session-start writer's already-published immutable record.
      fs.linkSync(temporary, file);
    } catch (error) {
      if (error.code === 'EEXIST') fail(`immutable record already exists: ${file}`);
      throw error;
    }
    fs.unlinkSync(temporary);
    const parentAfterCommit = fs.lstatSync(parent);
    if (!sameFileIdentity(parentBefore, parentAfterCommit)) {
      fail(`immutable-record parent changed during commit: ${file}`);
    }
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try {
      fs.unlinkSync(temporary);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  const final = fs.lstatSync(file);
  if (!final.isFile() || final.isSymbolicLink() || final.nlink !== 1) {
    fail(`immutable record final identity is unsafe: ${file}`);
  }
}

function mutateWorkflowState(options, mutation) {
  const actor = options.actor || 'main-v1';
  if (actor !== 'main-v1') {
    fail(`principal "${actor}" is denied workflow mutation`);
  }
  if (typeof mutation !== 'function') fail('workflow mutation must be a function');
  const workflowState = validateWorkflowToken(options.workflowState, 'workflow state');
  const event = validateWorkflowToken(options.event, 'workflow event');
  const key = sessionKey(options.sessionId);
  const stateDirectory = resolveWorkflowStateDirectory(options);
  const file = path.join(stateDirectory, `tdd-phase-${key}.json`);

  return withFileLock(stateDirectory, `state-${key}`, () => {
    if (!fs.existsSync(file)) {
      fail('project-bound workflow baseline is missing');
    }
    const previous = validateWorkflowState(readJson(file), key);
    const previousRevision = previous.revision;
    if (
      options.expectedRevision !== undefined
      && (!Number.isSafeInteger(options.expectedRevision) || options.expectedRevision !== previousRevision)
    ) {
      fail(`stale workflow revision (expected ${options.expectedRevision}, current ${previousRevision})`);
    }
    const draft = mutation(JSON.parse(JSON.stringify(previous)));
    if (!draft || typeof draft !== 'object' || Array.isArray(draft)) {
      fail('workflow mutation must return an object');
    }
    const next = stampWorkflowState(
      draft,
      key,
      workflowState,
      event,
      options.updatedAt,
      previousRevision,
    );
    validateWorkflowState(next, key);
    atomicWriteJson(file, next);
    return next;
  });
}

function initializeWorkflowState(options) {
  const key = sessionKey(options.sessionId);
  const stateDirectory = workflowStateDirectory(options.projectRoot);
  const file = path.join(stateDirectory, `tdd-phase-${key}.json`);
  return withFileLock(stateDirectory, `state-${key}`, () => {
    if (fs.existsSync(file)) return validateWorkflowState(readJson(file), key);
    const initial = stampWorkflowState({
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
    }, key, 'idle', 'session-start', undefined, 0);
    atomicWriteJson(file, initial);
    return initial;
  });
}

function transitionWorkflowState(options) {
  return mutateWorkflowState(options, (state) => state);
}

function resetReviewBudget(options) {
  if (!Number.isSafeInteger(options.expectedRevision) || options.expectedRevision < 1) {
    fail('review budget reset requires an exact expectedRevision');
  }
  return mutateWorkflowState({
    projectRoot: options.projectRoot,
    sessionId: options.sessionId,
    actor: options.actor,
    expectedRevision: options.expectedRevision,
    workflowState: 'review_rearmed',
    event: 'review-budget-reset',
  }, (state) => {
    if (state.active !== true || state.implComplete !== true) {
      fail('review budget reset requires an active completed implementation');
    }
    state.reviewRound = 0;
    state.stopBlocks = 0;
    state.chainDone = false;
    state.codeReviewDone = false;
    state.selfReviewFixed = false;
    return state;
  });
}

function readWorkflowState(options) {
  if (options.stateDirectory !== undefined) {
    fail('workflow state directory overrides are unsupported');
  }
  const file = workflowStateFile(options.projectRoot, options.sessionId);
  return validateWorkflowState(readJson(file), options.sessionId);
}

function sortedObject(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    fail('changedFileHashes must be an object');
  }
  const entries = [];
  for (const key of Object.keys(input).sort()) {
    const value = input[key];
    if (typeof value !== 'string' || !HASH_RE.test(value)) {
      fail(`invalid changed file hash for ${key}`);
    }
    entries.push([key, value]);
  }
  // Object.fromEntries uses CreateDataProperty, so a legitimate file named
  // "__proto__" remains an own data property instead of invoking the legacy
  // Object.prototype setter and disappearing from the attestation.
  return Object.fromEntries(entries);
}

function createAttestation(options) {
  const context = validateContext(options.context);
  const state = validateWorkflowState(options.state, context.session_id_hash);
  if (
    !Array.isArray(options.hookSequence)
    || options.hookSequence.length === 0
    || options.hookSequence.some((entry) => typeof entry !== 'string' || entry.trim() === '')
  ) {
    fail('hookSequence must be a non-empty array of strings');
  }
  if (!Number.isSafeInteger(options.exitCode)) {
    fail('exitCode must be an integer');
  }
  if (Object.prototype.hasOwnProperty.call(options, 'sourceRevision')
      || Object.prototype.hasOwnProperty.call(options, 'sourceRevisionAuthority')) {
    fail('sourceRevision/sourceRevisionAuthority overrides are unsupported in attestations');
  }
  return {
    schema: ATTESTATION_SCHEMA,
    schema_version: SCHEMA_VERSION,
    host: context.host,
    session_id_hash: context.session_id_hash,
    resolved_plugin_root: context.plugin_root,
    runtime_digest: context.runtime_digest,
    workflow_state: state.workflow_state,
    revision: state.revision,
    hook_sequence: [...options.hookSequence],
    reviewer_capabilities: options.reviewerCapabilities === context.principal_profiles.reviewer
      ? options.reviewerCapabilities
      : fail('reviewerCapabilities must match the immutable reviewer profile'),
    changed_file_hashes: sortedObject(options.changedFileHashes),
    cli_version: requireText(options.cliVersion, 'cliVersion'),
    plugin_version: options.pluginVersion === undefined || options.pluginVersion === context.plugin_version
      ? context.plugin_version
      : fail('pluginVersion must match the immutable context'),
    source_revision: context.source_revision,
    exit_code: options.exitCode,
  };
}

function parseOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (!token.startsWith('--')) {
      fail(`unexpected argument "${token}"`);
    }
    const name = token.slice(2);
    const value = args[index + 1];
    if (value === undefined || value.startsWith('--')) {
      fail(`missing value for --${name}`);
    }
    options[name] = value;
    index += 1;
  }
  return options;
}

function runCli(argv) {
  const [command, ...rest] = argv;
  if (command === 'session-key') {
    if (rest.length !== 1) fail('session-key expects exactly one value');
    process.stdout.write(`${sessionKey(rest[0])}\n`);
    return;
  }
  const options = parseOptions(rest);
  if (command === 'runtime-digest') {
    process.stdout.write(`${computeRuntimeDigest(options['plugin-root'], options.host)}\n`);
    return;
  }
  if (command === 'resolve' || command === 'render-main' || command === 'render-reviewer' || command === 'render-host') {
    const context = readContext({
      recordsDir: options['records-dir'],
      sessionId: options['session-id'],
      expectedHost: options.host,
    });
    if (command === 'resolve') {
      const field = requireText(options.field, 'field');
      if (!Object.prototype.hasOwnProperty.call(context, field) || typeof context[field] === 'object') {
        fail('unsupported context field');
      }
      process.stdout.write(`${context[field]}\n`);
    } else {
      const rendered = command === 'render-main'
        ? renderMainContext(context)
        : command === 'render-reviewer'
          ? renderReviewerContext(context)
          : renderHostContext(context);
      process.stdout.write(`${rendered}\n`);
    }
    return;
  }
  if (command === 'transition') {
    const state = transitionWorkflowState({
      projectRoot: options['project-root'],
      sessionId: options['session-id'],
      workflowState: options['workflow-state'],
      event: options.event,
      actor: options.actor,
      expectedRevision: options['expected-revision'] === undefined ? undefined : Number(options['expected-revision']),
    });
    process.stdout.write(`${JSON.stringify(state)}\n`);
    return;
  }
  fail('unknown command');
}

module.exports = {
  SCHEMA,
  SCHEMA_VERSION,
  WORKFLOW_SCHEMA,
  ATTESTATION_SCHEMA,
  sessionIdHash,
  sessionKey,
  computeRuntimeDigest,
  buildContext,
  registerContext,
  readContext,
  renderMainContext,
  renderReviewerContext,
  renderHostContext,
  stampWorkflowState,
  initializeWorkflowState,
  mutateWorkflowState,
  transitionWorkflowState,
  resetReviewBudget,
  readWorkflowState,
  createAttestation,
  withFileLock,
  atomicWriteJson,
  atomicCreateJson,
};

if (require.main === module) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
