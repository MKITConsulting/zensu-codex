'use strict';

// Local, content-addressed recovery contract shared with `zensu ai-work recover`.
// Only the active session's lock owner may archive. Archives are never replayed
// by Stop and contain the exact receipt bytes, including unknown future fields.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function isLegacy(state) { return !!state && (!state.scope || !state.scope.taskScope); }
function directory(dir) {
  try { fs.mkdirSync(dir, { mode: 0o700 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  const st = fs.lstatSync(dir);
  if (!st.isDirectory() || st.isSymbolicLink()) throw new Error('Unsafe recovery archive directory');
}
function bytes(file) {
  const st = fs.lstatSync(file);
  if (!st.isFile() || st.isSymbolicLink() || st.size > 98304) throw new Error('Unsafe recovery archive receipt');
  const fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const opened = fs.fstatSync(fd);
    if (opened.dev !== st.dev || opened.ino !== st.ino) throw new Error('Recovery archive receipt changed');
    const raw = fs.readFileSync(fd);
    if (raw.length > 98304) throw new Error('Unsafe recovery archive receipt');
    return raw;
  } finally { fs.closeSync(fd); }
}
function archive(file) {
  const raw = bytes(file);
  const digest = crypto.createHash('sha256').update(raw).digest('hex');
  const parent = path.join(path.dirname(file), 'recovery');
  directory(parent);
  const dir = path.join(parent, path.basename(file, '.json'));
  directory(dir);
  const target = path.join(dir, digest + '.json');
  try {
    if (!bytes(target).equals(raw)) throw new Error('Recovery archive collision; active receipt retained');
    return digest;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const tmp = path.join(dir, '.receipt-' + crypto.randomUUID() + '.tmp');
  try {
    fs.writeFileSync(tmp, raw, { mode: 0o600, flag: 'wx' });
    // Windows FlushFileBuffers requires a writable handle.
    const fd = fs.openSync(tmp, 'r+');
    try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    // No overwrite, and no partial final file after a process interruption.
    fs.linkSync(tmp, target);
  } finally { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); }
  return digest;
}

module.exports = { isLegacy, archive };
