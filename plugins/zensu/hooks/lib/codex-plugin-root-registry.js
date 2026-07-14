#!/usr/bin/env node
"use strict";

// Mutable registration policy. Transaction coordination and immutable-reader
// publication live in codex-plugin-root-bootstrap.js; resolution lives in the
// separately versioned codex-plugin-root-resolve-v1.js source artifact.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const HELPER_RELATIVE = path.join("hooks", "lib", "zensu-log.sh");
const MANIFEST_RELATIVE = path.join(".codex-plugin", "plugin.json");
const MAX_ARTIFACT_BYTES = 64 * 1024;
const WINDOWS = process.platform === "win32";

class RegistrationError extends Error {
  constructor(failureCode, message) { super(message); this.failureCode = failureCode; }
}
const fail = (code, message) => { throw new RegistrationError(code, message); };
function normalizeNativePath(value, windows = WINDOWS) {
  if (!windows) return value;
  return value.replace(/^\/([A-Za-z])(?:\/|$)/, (_match, drive) => `${drive.toUpperCase()}:/`);
}
function lstatRegular(target, label, failureCode, limit = MAX_ARTIFACT_BYTES) {
  let stat;
  try { stat = fs.lstatSync(target); } catch (_) { fail(failureCode, `${label} is missing`); }
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size <= 0 || stat.size > limit) {
    fail(failureCode, `${label} is not a bounded regular file`);
  }
  return stat;
}
function validatedPluginRoot(rawRoot) {
  if (!rawRoot || /[\0\r\n]/.test(rawRoot)) fail("ROOT_INVALID", "plugin root is unavailable or unsafe");
  let root;
  try { root = fs.realpathSync(normalizeNativePath(rawRoot)); }
  catch (_) { fail("ROOT_INVALID", "plugin root does not exist"); }
  const stat = fs.lstatSync(root);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail("ROOT_INVALID", "plugin root is not a real directory");
  return root;
}
function authoritativePluginRoot() {
  const root = validatedPluginRoot(path.resolve(__dirname, "..", ".."));
  for (const name of ["PLUGIN_ROOT", "CLAUDE_PLUGIN_ROOT", "ZENSU_PLUGIN_ROOT", "CODEX_PLUGIN_ROOT"]) {
    const supplied = process.env[name];
    if (!supplied) continue;
    if (validatedPluginRoot(supplied) !== root) fail("ROOT_ENV_MISMATCH", `${name} does not match the executed plugin installation`);
  }
  return root;
}
function readManifest(root) {
  const manifestPath = path.join(root, MANIFEST_RELATIVE);
  lstatRegular(manifestPath, "plugin manifest", "MANIFEST_INVALID");
  let manifest;
  try { manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")); }
  catch (_) { fail("MANIFEST_INVALID", "plugin manifest is invalid JSON"); }
  if (!manifest || Array.isArray(manifest) || manifest.name !== "zensu" ||
      typeof manifest.version !== "string" || !manifest.version) {
    fail("MANIFEST_INVALID", "plugin manifest identity or version is invalid");
  }
  return manifest;
}

function testBarrier() {
  if (process.env.NODE_ENV !== "test" || !process.env.ZENSU_CODEX_TEST_BARRIER_DIR) return;
  const directory = path.resolve(process.env.ZENSU_CODEX_TEST_BARRIER_DIR);
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail("INTERNAL", "test barrier is unsafe");
  fs.writeFileSync(path.join(directory, "registrar.reached"), "reached\n", { flag: "wx", mode: 0o600 });
  const release = path.join(directory, "registrar.release");
  const deadline = Date.now() + 15000;
  const wait = new Int32Array(new SharedArrayBuffer(4));
  while (!fs.existsSync(release)) {
    if (Date.now() >= deadline) fail("INTERNAL", "test barrier timed out");
    Atomics.wait(wait, 0, 0, 20);
  }
}

function prepareRegistration({ payload }) {
  testBarrier();
  const root = authoritativePluginRoot();
  const manifest = readManifest(root);
  const helper = path.join(root, HELPER_RELATIVE);
  lstatRegular(helper, "zensu-log helper", "HELPER_INVALID", 2 * 1024 * 1024);
  return {
    pluginRoot: root,
    pluginVersion: manifest.version,
    helperPath: HELPER_RELATIVE.split(path.sep).join("/"),
    helperSha256: crypto.createHash("sha256").update(fs.readFileSync(helper)).digest("hex"),
    sessionCwd: typeof payload.cwd === "string" ? payload.cwd.slice(0, 16384) : ""
  };
}

module.exports = { normalizeNativePath, prepareRegistration };
