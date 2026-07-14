#!/usr/bin/env node
"use strict";

// Small SessionStart transaction coordinator. It owns the per-session lock and
// publishes a fail-closed tombstone before loading the mutable registrar.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const SCHEMA_VERSION = 2;
const SESSION_DOMAIN = Buffer.from("codex-session\0", "utf8");
const READER_NAME = "resolve-v1.js";
const READER_SOURCE_NAME = "codex-plugin-root-resolve-v1.js";
const REGISTRAR_NAME = "codex-plugin-root-registry.js";
const MAINTENANCE_LOCK_KEY = "registry-maintenance";
const MAX_PAYLOAD_BYTES = 1024 * 1024;
const MAX_ARTIFACT_BYTES = 64 * 1024;
const MAX_PENDING_MARKERS = 512;
const MAX_RECOVERY_CLAIMS = 128;
const PENDING_RECLAIM_MS = 60 * 1000;
const RECOVERY_CLAIM_QUIET_MS = 50;
const WINDOWS = process.platform === "win32";

class RegistryError extends Error {
  constructor(code, message) { super(message); this.failureCode = code; }
}
const fail = (code, message) => { throw new RegistryError(code, message); };
const normalizeNativePath = value => WINDOWS
  ? value.replace(/^\/([A-Za-z])(?:\/|$)/, (_m, drive) => `${drive.toUpperCase()}:/`)
  : value;
const sessionKey = id => crypto.createHash("sha256").update(SESSION_DOMAIN).update(id, "utf8").digest("hex");
const sha256 = data => crypto.createHash("sha256").update(data).digest("hex");
const sleep = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function testBarrier(name) {
  if (process.env.NODE_ENV !== "test" || !process.env.ZENSU_CODEX_BOOTSTRAP_TEST_BARRIER_DIR) return;
  const directory = path.resolve(process.env.ZENSU_CODEX_BOOTSTRAP_TEST_BARRIER_DIR);
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail("INTERNAL", "bootstrap test barrier is unsafe");
  const reached = path.join(directory, `${name}.reached`);
  const release = path.join(directory, `${name}.release`);
  if (!optionalLstat(reached)) fs.writeFileSync(reached, "reached\n", { flag: "wx", mode: 0o600 });
  const deadline = Date.now() + 15000;
  while (!optionalLstat(release)) {
    if (Date.now() >= deadline) fail("INTERNAL", `bootstrap test barrier timed out: ${name}`);
    sleep(20);
  }
}

function selectedTestBarrier(name) {
  if (process.env.ZENSU_CODEX_BOOTSTRAP_TEST_BARRIER_NAME !== name) return;
  testBarrier(name);
}

function optionalLstat(target) {
  try { return fs.lstatSync(target); }
  catch (error) {
    if (error && error.code === "ENOENT") return null;
    const detail = error && error.code ? ` (${error.code})` : "";
    fail("INTERNAL", `cannot inspect ${path.basename(target)}${detail}`);
  }
}
function checkedArtifact(target, label, kind = "file", limit = MAX_ARTIFACT_BYTES) {
  const stat = optionalLstat(target);
  if (!stat) fail("REGISTRAR_MISSING", `${label} is missing`);
  if (stat.isSymbolicLink()) fail("REGISTRAR_INVALID", `${label} must not be a symlink`);
  if (kind === "directory") {
    if (!stat.isDirectory()) fail("REGISTRAR_INVALID", `${label} is not a directory`);
  } else if (!stat.isFile() || stat.size <= 0 || stat.size > limit) {
    fail("REGISTRAR_INVALID", `${label} is not a bounded regular file`);
  }
  return stat;
}
function assertPrivate(stat, label) {
  if (!WINDOWS && (stat.mode & 0o077) !== 0) fail("INTERNAL", `${label} permissions are not private`);
}
function ensurePrivateDirectory(target) {
  try { fs.mkdirSync(target, { mode: 0o700 }); }
  catch (error) { if (!error || error.code !== "EEXIST") fail("INTERNAL", `cannot create ${target}`); }
  const stat = checkedArtifact(target, "registry directory", "directory");
  try { fs.chmodSync(target, 0o700); } catch (_) { if (!WINDOWS) fail("INTERNAL", "cannot set registry permissions"); }
  assertPrivate(fs.lstatSync(target), "registry directory");
}
function registryPaths() {
  const homeRaw = process.env.HOME || "";
  if (!homeRaw || /[\0\r\n]/.test(homeRaw)) fail("INTERNAL", "HOME is unavailable or unsafe");
  const home = path.resolve(normalizeNativePath(homeRaw));
  const zensu = path.join(home, ".zensu");
  const roots = path.join(zensu, "plugin-roots");
  const codex = path.join(roots, "codex");
  const locks = path.join(codex, ".locks");
  const pending = path.join(codex, ".pending");
  const staging = path.join(codex, ".staging");
  for (const directory of [zensu, roots, codex, locks, pending, staging]) ensurePrivateDirectory(directory);
  return { codex, locks, pending, staging, reader: path.join(codex, READER_NAME) };
}
function atomicPrivateWrite(target, data) {
  const parent = path.dirname(target);
  const parentStat = checkedArtifact(parent, "registry directory", "directory");
  assertPrivate(parentStat, "registry directory");
  const existing = optionalLstat(target);
  if (existing && (existing.isSymbolicLink() || !existing.isFile())) fail("READY_PUBLISH_FAILED", "registry artifact is unsafe");
  const temp = path.join(parent, `.${path.basename(target)}.${process.pid}.${crypto.randomBytes(8).toString("hex")}.tmp`);
  let fd;
  try {
    fd = fs.openSync(temp, "wx", 0o600);
    fs.writeFileSync(fd, data); fs.fsyncSync(fd); fs.closeSync(fd); fd = undefined;
    if (!WINDOWS) fs.chmodSync(temp, 0o600);
    const before = optionalLstat(target);
    if (before && before.isSymbolicLink()) fail("READY_PUBLISH_FAILED", "registry artifact changed to a symlink");
    fs.renameSync(temp, target);
    if (!WINDOWS) fs.chmodSync(target, 0o600);
  } catch (error) {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) {} }
    try { fs.unlinkSync(temp); } catch (_) {}
    if (error instanceof RegistryError) throw error;
    fail("READY_PUBLISH_FAILED", `atomic write failed for ${path.basename(target)}`);
  }
}
function publishImmutableReader(target, data) {
  const validate = () => {
    const stat = checkedArtifact(target, "registry reader");
    assertPrivate(stat, "registry reader");
    if (!fs.readFileSync(target).equals(data)) fail("READER_INCOMPATIBLE", `${READER_NAME} has incompatible bytes`);
  };
  if (optionalLstat(target)) { validate(); return sha256(data); }
  const temp = path.join(path.dirname(target), `.${READER_NAME}.${process.pid}.${crypto.randomBytes(8).toString("hex")}.tmp`);
  let fd;
  try {
    fd = fs.openSync(temp, "wx", 0o600);
    fs.writeFileSync(fd, data); fs.fsyncSync(fd); fs.closeSync(fd); fd = undefined;
    if (!WINDOWS) fs.chmodSync(temp, 0o600);
    try { fs.linkSync(temp, target); }
    catch (error) { if (!error || error.code !== "EEXIST") throw error; validate(); }
    validate();
  } catch (error) {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) {} }
    if (error instanceof RegistryError) throw error;
    fail("READER_PUBLISH_FAILED", "immutable reader publication failed");
  } finally { try { fs.unlinkSync(temp); } catch (_) {} }
  return sha256(data);
}

function parseLockBytes(bytes) {
  let owner;
  try { owner = JSON.parse(bytes.toString("utf8")); } catch (_) { return null; }
  if (!owner || owner.schemaVersion !== 1 || !Number.isSafeInteger(owner.pid) || owner.pid <= 0 ||
      typeof owner.token !== "string" || !/^[a-f0-9]{64}$/.test(owner.token) ||
      typeof owner.createdAt !== "string") return null;
  return owner;
}
function lockSnapshot(lockPath) {
  const stat = optionalLstat(lockPath);
  if (!stat) return null;
  if (stat.isSymbolicLink()) fail("INTERNAL", "session registry lock is unsafe");
  if (stat.isDirectory()) {
    const names = fs.readdirSync(lockPath);
    if (names.some(name => name !== "owner.json")) fail("INTERNAL", "legacy session lock contains unexpected content");
    let owner = null;
    const ownerPath = path.join(lockPath, "owner.json");
    if (names.includes("owner.json")) {
      const ownerStat = fs.lstatSync(ownerPath);
      if (!ownerStat.isSymbolicLink() && ownerStat.isFile() && ownerStat.size > 0 && ownerStat.size <= 4096) {
        owner = parseLockBytes(fs.readFileSync(ownerPath));
      }
    }
    let stale = !owner && Date.now() - stat.mtimeMs >= 60000;
    if (owner) {
      try { process.kill(owner.pid, 0); }
      catch (error) {
        if (error && error.code === "ESRCH") stale = true;
        else if (!error || error.code !== "EPERM") fail("INTERNAL", "cannot inspect legacy session lock owner");
      }
    }
    return { stat, legacyDirectory: true, stale };
  }
  if (!stat.isFile() || stat.size <= 0 || stat.size > 4096) {
    return { stat, bytes: null, owner: null, stale: Date.now() - stat.mtimeMs >= 2000 };
  }
  const bytes = fs.readFileSync(lockPath);
  const owner = parseLockBytes(bytes);
  let stale = !owner && Date.now() - stat.mtimeMs >= 2000;
  if (owner) {
    try { process.kill(owner.pid, 0); }
    catch (error) {
      if (error && error.code === "ESRCH") stale = true;
      else if (!error || error.code !== "EPERM") fail("INTERNAL", "cannot inspect session lock owner");
    }
  }
  return { stat, bytes, owner, stale };
}
function publishLock(lockPath, owner) {
  // Publication staging deliberately does not inherit the canonical target
  // prefix. Recovery-claim scanners can therefore enumerate only complete
  // `<recovery>.reclaim.<pid>.<token>` artifacts without mistaking a bounded
  // writer temp for a malformed claim.
  const temp = path.join(path.dirname(lockPath), `.lock-publish.${process.pid}.${crypto.randomBytes(8).toString("hex")}.tmp`);
  let fd;
  try {
    fd = fs.openSync(temp, "wx", 0o600);
    fs.writeFileSync(fd, `${JSON.stringify(owner)}\n`); fs.fsyncSync(fd); fs.closeSync(fd); fd = undefined;
    if (!WINDOWS) fs.chmodSync(temp, 0o600);
    if (lockPath.includes(".recovery.reclaim.")) selectedTestBarrier("claim-publication-staged");
    fs.linkSync(temp, lockPath);
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) {} }
    try { fs.unlinkSync(temp); } catch (_) {}
  }
}
function removeStaleLock(lockPath, snapshot) {
  if (snapshot.legacyDirectory) {
    const names = fs.readdirSync(lockPath);
    if (names.some(name => name !== "owner.json")) fail("INTERNAL", "legacy session lock changed during recovery");
    if (names.includes("owner.json")) fs.unlinkSync(path.join(lockPath, "owner.json"));
    fs.rmdirSync(lockPath);
    return;
  }
  const stat = fs.lstatSync(lockPath);
  if (!stat.isFile() || stat.isSymbolicLink()) fail("INTERNAL", "stale session lock changed type during recovery");
  const bytes = fs.readFileSync(lockPath);
  if (snapshot.bytes && !bytes.equals(snapshot.bytes)) fail("INTERNAL", "stale session lock changed during recovery");
  fs.unlinkSync(lockPath);
}

function recoveryClaimPrefix(recoveryPath) {
  return `${path.basename(recoveryPath)}.reclaim.`;
}

function liveRecoveryClaims(recoveryPath) {
  const directory = path.dirname(recoveryPath);
  const prefix = recoveryClaimPrefix(recoveryPath);
  const names = fs.readdirSync(directory).filter(name => name.startsWith(prefix));
  if (names.length > MAX_RECOVERY_CLAIMS) fail("INTERNAL", "too many session lock recovery claims");
  const live = [];
  for (const name of names) {
    const identity = /^([0-9]+)\.([a-f0-9]{64})$/.exec(name.slice(prefix.length));
    if (!identity) fail("INTERNAL", "session lock recovery claim name is invalid");
    const claimPath = path.join(directory, name);
    const stat = checkedArtifact(claimPath, "session lock recovery claim", "file", 4096);
    assertPrivate(stat, "session lock recovery claim");
    const bytes = fs.readFileSync(claimPath);
    const owner = parseLockBytes(bytes);
    if (!owner || owner.pid !== Number(identity[1]) || owner.token !== identity[2]) {
      fail("INTERNAL", "session lock recovery claim identity is invalid");
    }
    if (processAlive(owner.pid)) {
      live.push({ path: claimPath, name, owner });
      continue;
    }
    // Claim paths contain an unguessable token and are never reused. Re-read
    // the exact bytes before unlinking so a stale claimant cannot delete a
    // different artifact even if the directory changes concurrently.
    let latest;
    try { latest = fs.readFileSync(claimPath); }
    catch (error) { if (error && error.code === "ENOENT") continue; throw error; }
    if (!latest.equals(bytes)) fail("INTERNAL", "session lock recovery claim changed during cleanup");
    try { fs.unlinkSync(claimPath); }
    catch (error) { if (!error || error.code !== "ENOENT") fail("INTERNAL", "cannot remove stale recovery claim"); }
  }
  return live;
}

function acquireRecoveryClaim(recoveryPath, deadline) {
  const token = crypto.randomBytes(32).toString("hex");
  const owner = { schemaVersion: 1, pid: process.pid, token, createdAt: new Date().toISOString() };
  const claimPath = `${recoveryPath}.reclaim.${process.pid}.${token}`;
  let published = false;
  for (;;) {
    const live = liveRecoveryClaims(recoveryPath);
    if (!published) {
      if (live.length) {
        if (Date.now() >= deadline) fail("INTERNAL", "timed out waiting for recovery-claim election");
        sleep(25);
        continue;
      }
      try { publishLock(claimPath, owner); published = true; }
      catch (error) {
        if (!error || error.code !== "EEXIST") fail("INTERNAL", "cannot publish session lock recovery claim");
      }
      // A contender that observed the directory just before this publication
      // may publish late. Keep our claim visible and allow it to join the same
      // deterministic election before acting.
      sleep(RECOVERY_CLAIM_QUIET_MS);
      continue;
    }
    const contenders = liveRecoveryClaims(recoveryPath).sort((a, b) => a.name.localeCompare(b.name));
    if (!contenders.some(candidate => candidate.path === claimPath)) {
      fail("INTERNAL", "session lock recovery claim disappeared");
    }
    if (contenders[0].path === claimPath) return { path: claimPath, token };
    releaseLock({ path: claimPath, token });
    published = false;
    if (Date.now() >= deadline) fail("INTERNAL", "timed out waiting for recovery-claim election");
    sleep(25);
  }
}

function acquireRecoveryGuard(recoveryPath, deadline) {
  const token = crypto.randomBytes(32).toString("hex");
  const owner = { schemaVersion: 1, pid: process.pid, token, createdAt: new Date().toISOString() };
  for (;;) {
    try {
      publishLock(recoveryPath, owner);
      return { path: recoveryPath, token };
    } catch (error) {
      if (!error || error.code !== "EEXIST") fail("INTERNAL", "cannot publish session lock recovery guard");
    }
    const snapshot = lockSnapshot(recoveryPath);
    if (!snapshot) continue;
    if (!snapshot.stale) {
      if (Date.now() >= deadline) fail("INTERNAL", "timed out waiting for session lock recovery");
      sleep(25);
      continue;
    }
    selectedTestBarrier("recovery-guard-snapshot");
    const claim = acquireRecoveryClaim(recoveryPath, deadline);
    try {
      const latest = lockSnapshot(recoveryPath);
      if (latest && !latest.stale) {
        if (Date.now() >= deadline) fail("INTERNAL", "timed out waiting for replaced recovery guard");
        continue;
      }
      if (latest) removeStaleLock(recoveryPath, latest);
      try {
        publishLock(recoveryPath, owner);
        return { path: recoveryPath, token };
      } catch (error) {
        if (!error || error.code !== "EEXIST") fail("INTERNAL", "cannot replace stale session lock recovery guard");
      }
    } finally {
      releaseLock(claim);
    }
  }
}

function recoverSessionLock(lockPath, recoveryPath, owner, deadline) {
  const recovery = acquireRecoveryGuard(recoveryPath, deadline);
  try {
    const latest = lockSnapshot(lockPath);
    if (latest && !latest.stale) return false;
    if (latest) removeStaleLock(lockPath, latest);
    try {
      publishLock(lockPath, owner);
      return true;
    } catch (error) {
      if (!error || error.code !== "EEXIST") fail("INTERNAL", "cannot publish recovered session lock");
      return false;
    }
  } finally {
    releaseLock(recovery);
  }
}

function acquireLock(locks, key) {
  const lockPath = path.join(locks, `${key}.lock`);
  const recoveryPath = `${lockPath}.recovery`;
  const deadline = Date.now() + 30000;
  const token = crypto.randomBytes(32).toString("hex");
  const owner = { schemaVersion: 1, pid: process.pid, token, createdAt: new Date().toISOString() };
  for (;;) {
    const recoveryClaims = liveRecoveryClaims(recoveryPath);
    if (recoveryClaims.length) {
      if (Date.now() >= deadline) fail("INTERNAL", "timed out waiting for session lock recovery claim");
      sleep(25);
      continue;
    }
    const recoverySnapshot = lockSnapshot(recoveryPath);
    if (recoverySnapshot) {
      if (!recoverySnapshot.stale) {
        if (Date.now() >= deadline) fail("INTERNAL", "timed out waiting for session lock recovery");
        sleep(25);
        continue;
      }
      if (recoverSessionLock(lockPath, recoveryPath, owner, deadline)) return { path: lockPath, token };
      continue;
    }
    try {
      publishLock(lockPath, owner);
      return { path: lockPath, token };
    } catch (error) {
      if (!error || error.code !== "EEXIST") {
        if (error instanceof RegistryError) throw error;
        fail("INTERNAL", "cannot acquire session registry lock");
      }
    }
    const snapshot = lockSnapshot(lockPath);
    if (!snapshot) continue;
    if (snapshot.stale) {
      testBarrier("lock-recovery-snapshot");
      if (recoverSessionLock(lockPath, recoveryPath, owner, deadline)) return { path: lockPath, token };
      continue;
    }
    if (Date.now() >= deadline) fail("INTERNAL", "timed out waiting for session registry lock");
    sleep(25);
  }
}
function releaseLock(lock) {
  const snapshot = lockSnapshot(lock.path);
  if (!snapshot || !snapshot.owner || snapshot.owner.pid !== process.pid || snapshot.owner.token !== lock.token) {
    fail("INTERNAL", "session registry lock ownership changed");
  }
  fs.unlinkSync(lock.path);
}
function validateSessionId(value) {
  if (typeof value !== "string" || !value || value.length > 4096 || value.includes("\0")) fail("INTERNAL", "SessionStart session_id is invalid");
  return value;
}
function readPayload() {
  let raw;
  try { raw = fs.readFileSync(0); } catch (_) { fail("INTERNAL", "SessionStart payload is unreadable"); }
  if (!raw.length || raw.length > MAX_PAYLOAD_BYTES) fail("INTERNAL", "SessionStart payload size is invalid");
  try { return { raw, payload: JSON.parse(raw.toString("utf8")) }; }
  catch (_) { fail("INTERNAL", "SessionStart payload is invalid JSON"); }
}

function validateOwnPendingMarker(paths, raw) {
  const supplied = process.env.ZENSU_CODEX_PENDING_MARKER || "";
  const ownerPid = Number(process.env.ZENSU_CODEX_PENDING_OWNER_PID || "");
  const marker = path.resolve(normalizeNativePath(supplied));
  if (!supplied || path.dirname(marker) !== paths.pending ||
      !Number.isSafeInteger(ownerPid) || ownerPid <= 0 ||
      !new RegExp(`^attempt\\.${ownerPid}\\.[0-9]+\\.[0-9]+\\.json$`).test(path.basename(marker))) {
    fail("INTERNAL", "pending registration marker identity is invalid");
  }
  const stat = checkedArtifact(marker, "pending registration marker", "file", MAX_PAYLOAD_BYTES);
  assertPrivate(stat, "pending registration marker");
  if (!fs.readFileSync(marker).equals(raw)) fail("INTERNAL", "pending registration marker bytes changed");
  return marker;
}
function processAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) {
    if (error && error.code === "ESRCH") return false;
    if (error && error.code === "EPERM") return true;
    fail("INTERNAL", "cannot inspect pending registration owner");
  }
}
function pendingIdentity(name) {
  const match = /^attempt\.([0-9]+)\.([0-9]+)\.([0-9]+)\.json$/.exec(name);
  return match ? { pid: Number(match[1]), nonceA: match[2], nonceB: match[3] } : null;
}
function pendingOwner(name) {
  const identity = pendingIdentity(name);
  return identity ? identity.pid : 0;
}
function expectedStagingName(name) {
  const identity = pendingIdentity(name);
  return identity ? `payload.${identity.pid}.${identity.nonceA}.${identity.nonceB}.json` : "";
}
function reclaimablePending(name, stat) {
  const pid = pendingOwner(name);
  return pid > 0 && Date.now() - stat.mtimeMs >= PENDING_RECLAIM_MS && !processAlive(pid);
}

function stagedCaptureIdentity(paths, markerName, markerPayload) {
  const identity = pendingIdentity(markerName);
  const stagingName = expectedStagingName(markerName);
  if (!identity || !markerPayload || markerPayload.schemaVersion !== 1 || markerPayload.state !== "capturing" ||
      markerPayload.ownerPid !== identity.pid || markerPayload.stagingName !== stagingName ||
      typeof markerPayload.createdAt !== "string") {
    return { sessionId: null, stagePath: stagingName ? path.join(paths.staging, stagingName) : null, stageBytes: null };
  }
  const stagePath = path.join(paths.staging, stagingName);
  const stat = optionalLstat(stagePath);
  if (!stat || stat.isSymbolicLink() || !stat.isFile() || stat.size <= 0 || stat.size > MAX_PAYLOAD_BYTES) {
    return { sessionId: null, stagePath, stageBytes: null };
  }
  assertPrivate(stat, "staged SessionStart payload");
  const stageBytes = fs.readFileSync(stagePath);
  let payload;
  try { payload = JSON.parse(stageBytes.toString("utf8")); } catch (_) { return { sessionId: null, stagePath, stageBytes }; }
  try { return { sessionId: validateSessionId(payload && payload.session_id), stagePath, stageBytes }; }
  catch (_) { return { sessionId: null, stagePath, stageBytes }; }
}

function removeExactFile(target, expectedBytes, label) {
  if (!target) return;
  const stat = optionalLstat(target);
  if (!stat) return;
  if (stat.isSymbolicLink() || !stat.isFile()) fail("INTERNAL", `${label} changed type before cleanup`);
  const bytes = fs.readFileSync(target);
  if (expectedBytes && !bytes.equals(expectedBytes)) fail("INTERNAL", `${label} changed before cleanup`);
  try { fs.unlinkSync(target); } catch (_) { fail("INTERNAL", `cannot remove ${label}`); }
}

function invalidatePriorRecords(paths, keepRecordPath) {
  for (const name of fs.readdirSync(paths.codex)) {
    if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
    const target = path.join(paths.codex, name);
    if (target === keepRecordPath) continue;
    const stat = optionalLstat(target);
    if (!stat) continue;
    if (stat.isSymbolicLink() || !stat.isFile()) fail("INTERNAL", "prior session record is unsafe");
    try { fs.unlinkSync(target); } catch (_) { fail("INTERNAL", "cannot invalidate prior session record"); }
  }
}

function cleanupStaleStaging(paths) {
  const names = fs.readdirSync(paths.staging);
  if (names.length > MAX_PENDING_MARKERS * 2) fail("INTERNAL", "too many staged registration artifacts");
  const referenced = new Set();
  for (const markerName of fs.readdirSync(paths.pending)) {
    if (!pendingIdentity(markerName)) continue;
    const markerPath = path.join(paths.pending, markerName);
    const stat = optionalLstat(markerPath);
    if (!stat || stat.isSymbolicLink() || !stat.isFile() || stat.size <= 0 || stat.size > MAX_PAYLOAD_BYTES) continue;
    try {
      const payload = JSON.parse(fs.readFileSync(markerPath, "utf8"));
      if (payload && payload.state === "capturing" && payload.stagingName === expectedStagingName(markerName)) {
        referenced.add(payload.stagingName);
      }
    } catch (_) {}
  }
  for (const name of names) {
    if (referenced.has(name)) continue;
    const match = /^(?:payload|provisional)\.([0-9]+)\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\.(?:json|tmp)$/.exec(name);
    if (!match) continue;
    const target = path.join(paths.staging, name);
    const stat = optionalLstat(target);
    if (!stat || stat.isSymbolicLink() || !stat.isFile() || Date.now() - stat.mtimeMs < PENDING_RECLAIM_MS || processAlive(Number(match[1]))) continue;
    removeExactFile(target, fs.readFileSync(target), "stale staged registration artifact");
  }
}

function completePendingRegistration(paths, marker, raw, sessionId, keepRecordPath) {
  const names = fs.readdirSync(paths.pending);
  if (names.length > MAX_PENDING_MARKERS) fail("INTERNAL", "too many pending registration markers");
  const targetedRemovals = [];
  const broadRemovals = [];
  for (const name of names) {
    if (!pendingIdentity(name)) continue;
    const candidate = path.join(paths.pending, name);
    const stat = optionalLstat(candidate);
    if (!stat || stat.isSymbolicLink() || !stat.isFile() || stat.size <= 0 || stat.size > MAX_PAYLOAD_BYTES) {
      continue;
    }
    const bytes = fs.readFileSync(candidate);
    if (candidate === marker) {
      if (!bytes.equals(raw)) fail("INTERNAL", "pending registration marker changed before completion");
      targetedRemovals.push({ marker: candidate, markerBytes: bytes, stagePath: null, stageBytes: null });
      continue;
    }
    let pendingPayload;
    try { pendingPayload = JSON.parse(bytes.toString("utf8")); }
    catch (_) {
      if (reclaimablePending(name, stat)) broadRemovals.push({ marker: candidate, markerBytes: bytes, stagePath: null, stageBytes: null });
      continue;
    }
    if (pendingPayload && pendingPayload.state === "capturing") {
      if (!reclaimablePending(name, stat)) continue;
      const capture = stagedCaptureIdentity(paths, name, pendingPayload);
      const removal = { marker: candidate, markerBytes: bytes, stagePath: capture.stagePath, stageBytes: capture.stageBytes };
      if (capture.sessionId === sessionId) targetedRemovals.push(removal);
      else if (capture.sessionId === null) broadRemovals.push(removal);
      continue;
    }
    let pendingSessionId = null;
    try { pendingSessionId = validateSessionId(pendingPayload && pendingPayload.session_id); } catch (_) {}
    if (pendingSessionId === null) {
      if (reclaimablePending(name, stat)) broadRemovals.push({ marker: candidate, markerBytes: bytes, stagePath: null, stageBytes: null });
      continue;
    }
    if (pendingSessionId === sessionId && !processAlive(pendingOwner(name))) {
      targetedRemovals.push({ marker: candidate, markerBytes: bytes, stagePath: null, stageBytes: null });
    }
  }
  if (broadRemovals.length) {
    // An interrupted pre-capture transaction has no trustworthy session
    // identity. Keep its global guard until every older record is gone; only
    // the successfully published current record is safe to retain.
    invalidatePriorRecords(paths, keepRecordPath);
  }
  for (const removal of [...broadRemovals, ...targetedRemovals]) {
    removeExactFile(removal.stagePath, removal.stageBytes, "staged SessionStart payload");
    removeExactFile(removal.marker, removal.markerBytes, "pending registration marker");
  }
  if (optionalLstat(marker)) fail("INTERNAL", "pending registration marker could not be cleared");
  cleanupStaleStaging(paths);
}

function main() {
  const { raw, payload } = readPayload();
  const sessionId = validateSessionId(payload && payload.session_id);
  const key = sessionKey(sessionId);
  const paths = registryPaths();
  const pendingMarker = validateOwnPendingMarker(paths, raw);
  const recordPath = path.join(paths.codex, `${key}.json`);
  const attemptId = crypto.randomBytes(32).toString("hex");
  const base = { schemaVersion: SCHEMA_VERSION, recordType: "codex-plugin-root", host: "codex", sessionId, sessionKey: key, attemptId };
  let complete = false;
  let maintenanceReleased = false;
  // Every registrar takes the global lock before its exact-session lock and
  // holds it through ready publication plus pending cleanup. A broad cleanup
  // can therefore invalidate only records that predate its own transaction;
  // no distinct-session registrar can publish a record in the deletion window.
  const maintenanceLock = acquireLock(paths.locks, MAINTENANCE_LOCK_KEY);
  try {
    const lock = acquireLock(paths.locks, key);
    let readyPublished = false;
    let lockReleased = false;
    try {
      atomicPrivateWrite(recordPath, `${JSON.stringify({ ...base, state: "registering", startedAt: new Date().toISOString() }, null, 2)}\n`);
      const registrarPath = path.join(__dirname, REGISTRAR_NAME);
      checkedArtifact(registrarPath, "registry registrar");
      let registrar;
      try { registrar = require(registrarPath); } catch (_) { fail("REGISTRAR_INVALID", "registry registrar cannot be loaded"); }
      if (!registrar || typeof registrar.prepareRegistration !== "function") fail("REGISTRAR_INVALID", "registry registrar API is invalid");
      const prepared = registrar.prepareRegistration({ payload, sessionId, sessionKey: key });
      const readerSourcePath = path.join(__dirname, READER_SOURCE_NAME);
      checkedArtifact(readerSourcePath, "registry reader source");
      const readerData = fs.readFileSync(readerSourcePath);
      const readerSha256 = publishImmutableReader(paths.reader, readerData);
      const ready = { ...base, state: "ready", ...prepared, readerName: READER_NAME, readerSha256, registeredAt: new Date().toISOString() };
      atomicPrivateWrite(recordPath, `${JSON.stringify(ready, null, 2)}\n`);
      readyPublished = true;
    } catch (error) {
      const code = error instanceof RegistryError ? error.failureCode : (error && error.failureCode) || "INTERNAL";
      try {
        atomicPrivateWrite(recordPath, `${JSON.stringify({ ...base, state: "failed", failureCode: code, failedAt: new Date().toISOString() }, null, 2)}\n`);
      } catch (_) {}
      const message = error && error.message ? error.message : String(error);
      process.stderr.write(`zensu: codex plugin-root registry: ${message}\n`);
    } finally {
      try { releaseLock(lock); lockReleased = true; }
      catch (error) { process.stderr.write(`zensu: codex plugin-root registry: ${error.message}\n`); }
    }
    if (readyPublished && lockReleased) {
      try { completePendingRegistration(paths, pendingMarker, raw, sessionId, recordPath); complete = true; }
      catch (error) { process.stderr.write(`zensu: codex plugin-root registry: ${error.message}\n`); }
    }
  } finally {
    try { releaseLock(maintenanceLock); maintenanceReleased = true; }
    catch (error) { process.stderr.write(`zensu: codex plugin-root registry: ${error.message}\n`); }
  }
  if (!complete || !maintenanceReleased) process.exitCode = 1;
}

try { main(); }
catch (error) {
  process.stderr.write(`zensu: codex plugin-root registry: ${error.message || String(error)}\n`);
  process.exit(1);
}

module.exports = { normalizeNativePath, sessionKey };
