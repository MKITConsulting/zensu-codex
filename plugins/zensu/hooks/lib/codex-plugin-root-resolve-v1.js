#!/usr/bin/env node
"use strict";

// Immutable exact-session reader v1. Do not add registration behavior here;
// behavioral changes require a new resolve-vN source and installed filename.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const SCHEMA_VERSION = 2;
const SESSION_DOMAIN = Buffer.from("codex-session\0", "utf8");
const HELPER_RELATIVE = path.join("hooks", "lib", "zensu-log.sh");
const MANIFEST_RELATIVE = path.join(".codex-plugin", "plugin.json");
const READER_NAME = "resolve-v1.js";
const MAX_RECORD_BYTES = 64 * 1024;
const MAX_PAYLOAD_BYTES = 1024 * 1024;
const MAX_PENDING_MARKERS = 512;
const MAX_RECOVERY_CLAIMS = 128;
const PENDING_RECLAIM_MS = 60 * 1000;
const WINDOWS = process.platform === "win32";

function die(message) {
  process.stderr.write(`zensu: codex plugin-root resolver: ${message}\n`);
  process.exit(1);
}
function normalizeNativePath(value, windows = WINDOWS) {
  if (!windows) return value;
  return value.replace(/^\/([A-Za-z])(?:\/|$)/, (_match, drive) => `${drive.toUpperCase()}:/`);
}
function sessionKey(sessionId) {
  return crypto.createHash("sha256").update(SESSION_DOMAIN).update(sessionId, "utf8").digest("hex");
}
const sha256File = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
function optionalLstat(target) {
  try { return fs.lstatSync(target); }
  catch (error) { if (error && error.code === "ENOENT") return null; die(`cannot inspect ${path.basename(target)}`); }
}
function lstatNoLink(target, label) {
  const stat = optionalLstat(target);
  if (!stat) die(`${label} is missing`);
  if (stat.isSymbolicLink()) die(`${label} must not be a symlink`);
  return stat;
}
function assertPrivate(stat, label) {
  if (!WINDOWS && (stat.mode & 0o077) !== 0) die(`${label} permissions are not private`);
}
function readSmallRegularFile(target, label, limit = MAX_RECORD_BYTES) {
  const stat = lstatNoLink(target, label);
  if (!stat.isFile() || stat.size <= 0 || stat.size > limit) die(`${label} is not a bounded regular file`);
  return fs.readFileSync(target);
}
function registryPaths() {
  const homeRaw = process.env.HOME || "";
  if (!homeRaw || /[\0\r\n]/.test(homeRaw)) die("HOME is unavailable or unsafe");
  const home = path.resolve(normalizeNativePath(homeRaw));
  const zensu = path.join(home, ".zensu");
  const roots = path.join(zensu, "plugin-roots");
  const codex = path.join(roots, "codex");
  const locks = path.join(codex, ".locks");
  const pending = path.join(codex, ".pending");
  const staging = path.join(codex, ".staging");
  for (const directory of [zensu, roots, codex, locks, pending, staging]) {
    const stat = lstatNoLink(directory, "registry directory");
    if (!stat.isDirectory()) die("registry path is not a directory");
    assertPrivate(stat, "registry directory");
  }
  return { codex, locks, pending, staging, reader: path.join(codex, READER_NAME) };
}
function validateSessionId(value) {
  if (typeof value !== "string" || !value || value.length > 4096 || value.includes("\0")) die("CODEX_THREAD_ID is unavailable or invalid");
  return value;
}
function validatedPluginRoot(rawRoot) {
  if (!rawRoot || /[\0\r\n]/.test(rawRoot)) die("registered plugin root is unsafe");
  let root;
  try { root = fs.realpathSync(normalizeNativePath(rawRoot)); }
  catch (_) { die("registered plugin root is missing"); }
  const stat = lstatNoLink(root, "registered plugin root");
  if (!stat.isDirectory()) die("registered plugin root is not a directory");
  return root;
}
function readManifest(root) {
  const bytes = readSmallRegularFile(path.join(root, MANIFEST_RELATIVE), "plugin manifest");
  let manifest;
  try { manifest = JSON.parse(bytes.toString("utf8")); } catch (_) { die("plugin manifest is invalid JSON"); }
  if (!manifest || Array.isArray(manifest) || manifest.name !== "zensu" || typeof manifest.version !== "string" || !manifest.version) {
    die("plugin manifest identity or version is invalid");
  }
  return manifest;
}
function assertUnlocked(lockPath) {
  const stat = optionalLstat(lockPath);
  if (!stat) return;
  if (stat.isSymbolicLink() || (!stat.isFile() && !stat.isDirectory())) die("session registry lock is unsafe");
  die("session registration is in progress or incomplete");
}
function processAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) {
    if (error && error.code === "ESRCH") return false;
    if (error && error.code === "EPERM") return true;
    die("cannot inspect pending registration owner");
  }
}

function stagedCaptureSessionId(stagingDir, markerName, markerPayload, ownerPid) {
  const nameMatch = /^attempt\.[0-9]+\.([0-9]+)\.([0-9]+)\.json$/.exec(markerName);
  const expectedName = nameMatch ? `payload.${ownerPid}.${nameMatch[1]}.${nameMatch[2]}.json` : "";
  if (!expectedName || !markerPayload || markerPayload.schemaVersion !== 1 || markerPayload.state !== "capturing" ||
      markerPayload.ownerPid !== ownerPid || markerPayload.stagingName !== expectedName ||
      typeof markerPayload.createdAt !== "string") return null;
  const target = path.join(stagingDir, expectedName);
  const stat = optionalLstat(target);
  if (!stat || stat.isSymbolicLink() || !stat.isFile() || stat.size <= 0 || stat.size > MAX_PAYLOAD_BYTES) return null;
  assertPrivate(stat, "staged SessionStart payload");
  let payload;
  try { payload = JSON.parse(fs.readFileSync(target, "utf8")); } catch (_) { return null; }
  if (!payload || typeof payload.session_id !== "string" || !payload.session_id ||
      payload.session_id.length > 4096 || payload.session_id.includes("\0")) return null;
  return payload.session_id;
}

function assertNoPendingRegistration(pendingDir, stagingDir, sessionId) {
  const names = fs.readdirSync(pendingDir);
  if (names.length > MAX_PENDING_MARKERS) die("too many pending registration markers");
  for (const name of names) {
    const nameMatch = /^attempt\.([0-9]+)\.[0-9]+\.[0-9]+\.json$/.exec(name);
    if (!nameMatch) die("pending registration marker name is invalid");
    const marker = path.join(pendingDir, name);
    const stat = lstatNoLink(marker, "pending registration marker");
    assertPrivate(stat, "pending registration marker");
    const ownerPid = Number(nameMatch[1]);
    const reclaimable = stat.isFile() && Date.now() - stat.mtimeMs >= PENDING_RECLAIM_MS && !processAlive(ownerPid);
    if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_PAYLOAD_BYTES) {
      if (reclaimable) continue;
      die("pending registration marker is not a bounded regular file");
    }
    const bytes = fs.readFileSync(marker);
    let payload;
    try { payload = JSON.parse(bytes.toString("utf8")); }
    catch (_) { die("pending registration identity is indeterminate"); }
    if (payload && payload.state === "capturing" && payload.ownerPid === ownerPid) {
      if (!reclaimable) die("SessionStart payload capture is in progress or incomplete");
      const stagedSessionId = stagedCaptureSessionId(stagingDir, name, payload, ownerPid);
      if (stagedSessionId === null) die("interrupted SessionStart payload identity is indeterminate");
      if (stagedSessionId === sessionId) die("session registration is pending or previously failed");
      continue;
    }
    if (!payload || typeof payload.session_id !== "string" || !payload.session_id || payload.session_id.length > 4096 || payload.session_id.includes("\0")) {
      die("pending registration identity is invalid");
    }
    if (payload.session_id === sessionId) die("session registration is pending or previously failed");
  }
}

function parseLockOwner(bytes) {
  let owner;
  try { owner = JSON.parse(bytes.toString("utf8")); } catch (_) { return null; }
  if (!owner || owner.schemaVersion !== 1 || !Number.isSafeInteger(owner.pid) || owner.pid <= 0 ||
      typeof owner.token !== "string" || !/^[a-f0-9]{64}$/.test(owner.token) ||
      typeof owner.createdAt !== "string") return null;
  return owner;
}

function assertNoRecoveryClaims(locksDir, key) {
  const prefix = `${key}.lock.recovery.reclaim.`;
  const names = fs.readdirSync(locksDir).filter(name => name.startsWith(prefix));
  if (names.length > MAX_RECOVERY_CLAIMS) die("too many session lock recovery claims");
  for (const name of names) {
    const identity = /^([0-9]+)\.([a-f0-9]{64})$/.exec(name.slice(prefix.length));
    if (!identity) die("session lock recovery claim name is invalid");
    const target = path.join(locksDir, name);
    const bytes = readSmallRegularFile(target, "session lock recovery claim", 4096);
    assertPrivate(fs.lstatSync(target), "session lock recovery claim");
    const owner = parseLockOwner(bytes);
    if (!owner || owner.pid !== Number(identity[1]) || owner.token !== identity[2]) {
      die("session lock recovery claim identity is invalid");
    }
    die("session lock recovery is in progress or incomplete");
  }
}

function resolve() {
  const sessionId = validateSessionId(process.env.CODEX_THREAD_ID);
  const key = sessionKey(sessionId);
  const paths = registryPaths();
  assertNoRecoveryClaims(paths.locks, key);
  assertNoPendingRegistration(paths.pending, paths.staging, sessionId);
  let executingReader;
  try { executingReader = fs.realpathSync(__filename); } catch (_) { die("executing registry reader is unavailable"); }
  let installedReader;
  try { installedReader = fs.realpathSync(paths.reader); } catch (_) { die("registry reader is missing"); }
  if (executingReader !== installedReader) die("resolution must execute the stable registry reader");
  const readerStat = lstatNoLink(paths.reader, "registry reader");
  if (!readerStat.isFile() || readerStat.size <= 0 || readerStat.size > MAX_RECORD_BYTES) die("registry reader is not bounded");
  assertPrivate(readerStat, "registry reader");

  const lockPath = path.join(paths.locks, `${key}.lock`);
  const recoveryPath = `${lockPath}.recovery`;
  assertUnlocked(recoveryPath);
  assertUnlocked(lockPath);
  const recordPath = path.join(paths.codex, `${key}.json`);
  const firstBytes = readSmallRegularFile(recordPath, "session registry record");
  assertPrivate(fs.lstatSync(recordPath), "session registry record");
  let record;
  try { record = JSON.parse(firstBytes.toString("utf8")); } catch (_) { die("session registry record is invalid JSON"); }
  if (!record || Array.isArray(record) || record.schemaVersion !== SCHEMA_VERSION ||
      record.recordType !== "codex-plugin-root" || record.host !== "codex" || record.state !== "ready") {
    die("session registry record is not ready");
  }
  if (record.sessionId !== sessionId || record.sessionKey !== key) die("session registry identity mismatch");
  if (record.helperPath !== HELPER_RELATIVE.split(path.sep).join("/")) die("session registry helper path mismatch");
  if (record.readerName !== READER_NAME || !/^[a-f0-9]{64}$/.test(record.readerSha256 || "")) die("session registry reader binding is invalid");
  if (!/^[a-f0-9]{64}$/.test(record.helperSha256 || "")) die("session registry helper hash is invalid");
  if (sha256File(executingReader) !== record.readerSha256) die("registry reader integrity mismatch");

  const root = validatedPluginRoot(record.pluginRoot);
  if (root !== record.pluginRoot) die("registered plugin root is no longer canonical");
  const manifest = readManifest(root);
  if (manifest.version !== record.pluginVersion) die("registered plugin version changed");
  const helper = path.join(root, HELPER_RELATIVE);
  const helperStat = lstatNoLink(helper, "zensu-log helper");
  if (!helperStat.isFile() || helperStat.size <= 0 || helperStat.size > 2 * 1024 * 1024) die("zensu-log helper is not bounded");
  if (sha256File(helper) !== record.helperSha256) die("zensu-log helper integrity mismatch");

  // A registrar may have started after the first read. Require both the lock
  // and exact record bytes to remain unchanged across the full validation.
  assertUnlocked(lockPath);
  assertUnlocked(recoveryPath);
  assertNoRecoveryClaims(paths.locks, key);
  assertNoPendingRegistration(paths.pending, paths.staging, sessionId);
  const secondBytes = readSmallRegularFile(recordPath, "session registry record");
  if (!secondBytes.equals(firstBytes)) die("session registry record changed during resolution");
  process.stdout.write(root);
}

if (require.main === module) resolve();
module.exports = { normalizeNativePath, sessionKey };
