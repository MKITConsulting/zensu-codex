'use strict';

const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');
const { fileURLToPath } = require('node:url');

const CORE_BASENAME = 'session-control-core-v1.js';
const PROBED = Symbol('workflow-state-access-probe');
const TWO_PATH_CALLS = new Set(['rename', 'link', 'symlink', 'copyFile', 'cp']);
const MUTATING_CALLS = new Set([
  'appendFile',
  'chmod',
  'chown',
  'copyFile',
  'cp',
  'createWriteStream',
  'lchmod',
  'lchown',
  'link',
  'lutimes',
  'mkdir',
  'mkdtemp',
  'rename',
  'rm',
  'rmdir',
  'symlink',
  'truncate',
  'unlink',
  'utimes',
  'writeFile',
]);
const WRITE_FLAGS = fs.constants.O_WRONLY
  | fs.constants.O_RDWR
  | fs.constants.O_CREAT
  | fs.constants.O_TRUNC
  | fs.constants.O_APPEND;

const appendReport = fs.appendFileSync;
const nativeRealpath = fs.realpathSync.native;
const reportFile = process.env.ZENSU_PROBE_REPORT || '';
const scope = [];
const accesses = [];
const cores = [];
const faults = [];
const watched = [];

for (const root of String(process.env.ZENSU_PROBE_ROOTS || '').split(path.delimiter).filter(Boolean)) {
  const spellings = [path.resolve(root)];
  try {
    spellings.push(nativeRealpath(root));
  } catch (error) {
    faults.push(`watched root ${root} cannot be resolved: ${error.message}`);
  }
  for (const spelling of spellings) {
    const prefix = path.join(spelling, '.zensu').toLowerCase();
    if (!watched.includes(prefix)) watched.push(prefix);
  }
}
if (watched.length === 0) faults.push('ZENSU_PROBE_ROOTS names no project root');

function callName(name) {
  return name.replace(/^promises\./, '').replace(/\.native$/, '').replace(/Sync$/, '');
}

function pathOf(value) {
  if (typeof value === 'string') return value;
  if (Buffer.isBuffer(value)) return value.toString('utf8');
  if (value instanceof URL) return fileURLToPath(value);
  return null;
}

function isWatched(candidate) {
  const resolved = path.resolve(candidate).toLowerCase();
  return watched.some((prefix) => resolved === prefix || resolved.startsWith(`${prefix}${path.sep}`));
}

function mutates(name, args) {
  const call = callName(name);
  if (MUTATING_CALLS.has(call)) return true;
  if (call !== 'open') return false;
  const flags = args[1];
  if (typeof flags === 'number') return (flags & WRITE_FLAGS) !== 0;
  return typeof flags === 'string' && /[wax+]/.test(flags);
}

function record(name, args) {
  const count = TWO_PATH_CALLS.has(callName(name)) ? 2 : 1;
  const paths = [];
  for (const value of args.slice(0, count)) {
    const candidate = pathOf(value);
    if (candidate !== null && isWatched(candidate)) paths.push(path.resolve(candidate));
  }
  if (paths.length > 0) accesses.push({ call: name, paths, mutating: mutates(name, args), scope: [...scope] });
}

function wrapFunctions(owner, prefix) {
  for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(owner))) {
    if (typeof descriptor.value !== 'function' || /^[A-Z_]/.test(key) || descriptor.value[PROBED]) continue;
    const original = descriptor.value;
    const name = `${prefix}${key}`;
    const probed = function probedFileSystemCall(...args) {
      record(name, args);
      return original.apply(this, args);
    };
    for (const property of Reflect.ownKeys(original)) {
      if (!Object.prototype.hasOwnProperty.call(probed, property)) {
        Object.defineProperty(probed, property, Object.getOwnPropertyDescriptor(original, property));
      }
    }
    probed[PROBED] = true;
    try {
      owner[key] = probed;
    } catch (error) {
      faults.push(`${name} cannot be probed: ${error.message}`);
    }
  }
}

function wrapCore(file, exported) {
  if (!exported || typeof exported !== 'object') return;
  let wrapped = false;
  for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(exported))) {
    if (typeof descriptor.value !== 'function' || descriptor.value[PROBED]) continue;
    const original = descriptor.value;
    const scoped = function scopedCoreExport(...args) {
      scope.push(key);
      try {
        return original.apply(this, args);
      } finally {
        scope.pop();
      }
    };
    scoped[PROBED] = true;
    try {
      exported[key] = scoped;
      wrapped = true;
    } catch (error) {
      faults.push(`core export ${key} cannot be probed: ${error.message}`);
    }
  }
  if (wrapped && !cores.includes(file)) cores.push(file);
}

wrapFunctions(fs, '');
wrapFunctions(fs.realpathSync, 'realpathSync.');
wrapFunctions(fs.realpath, 'realpath.');
wrapFunctions(fs.promises, 'promises.');

const load = Module.prototype.require;
Module.prototype.require = function probedRequire(...args) {
  const exported = load.apply(this, args);
  for (const [file, cached] of Object.entries(require.cache)) {
    if (path.basename(file) === CORE_BASENAME) wrapCore(file, cached.exports);
  }
  return exported;
};

process.on('exit', () => {
  if (!reportFile) return;
  const line = { pid: process.pid, main: process.argv[1] || null, watched, cores, faults, accesses };
  appendReport(reportFile, `${JSON.stringify(line)}\n`);
});
