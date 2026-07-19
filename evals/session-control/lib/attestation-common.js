'use strict';

const ATTESTATION_PREFIX = '[control-attestation] ';
const path = require('node:path');
const ATTESTATION_FIELDS = Object.freeze([
  'schema',
  'schema_version',
  'host',
  'session_id_hash',
  'resolved_plugin_root',
  'runtime_digest',
  'workflow_state',
  'revision',
  'hook_sequence',
  'reviewer_capabilities',
  'changed_file_hashes',
  'cli_version',
  'plugin_version',
  'source_revision',
  'exit_code',
]);

const HASH_RE = /^sha256:[a-f0-9]{64}$/;

function sanitizeModelText(input) {
  return String(input ?? '')
    .replace(/\r/g, '')
    .replace(/(^|\n)(?=\[control-attestation\]\s)/g, '$1[model-content] ');
}

function canonicalJson(value) {
  return JSON.stringify(value);
}

function controlLine(attestation) {
  return `${ATTESTATION_PREFIX}${canonicalJson(attestation)}`;
}

function strictParse(output) {
  const text = String(output ?? '');
  const matches = [...text.matchAll(/^\[control-attestation\]\s+(\{.*\})$/gm)];
  if (matches.length !== 1) {
    throw new Error(`expected exactly one wrapper-owned control attestation, found ${matches.length}`);
  }
  let value;
  try {
    value = JSON.parse(matches[0][1]);
  } catch (_error) {
    throw new Error('control attestation is not valid JSON');
  }
  if (canonicalJson(value) !== matches[0][1]) {
    throw new Error('control attestation is not canonical single-line JSON');
  }
  return value;
}

function validateShape(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('control attestation must be an object');
  }
  const keys = Object.keys(value);
  if (keys.length !== ATTESTATION_FIELDS.length || keys.some((key, index) => key !== ATTESTATION_FIELDS[index])) {
    throw new Error('control attestation field set or order is invalid');
  }
  if (value.schema !== 'zensu.control-attestation' || value.schema_version !== 1) {
    throw new Error('control attestation schema mismatch');
  }
  if (!['codex', 'claude'].includes(value.host)) throw new Error('host is invalid');
  if (!HASH_RE.test(value.session_id_hash)) throw new Error('session hash is invalid');
  if (typeof value.resolved_plugin_root !== 'string' || !path.isAbsolute(value.resolved_plugin_root)) {
    throw new Error('resolved plugin root is invalid');
  }
  if (!HASH_RE.test(value.runtime_digest)) throw new Error('runtime digest is invalid');
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(value.workflow_state || '')) {
    throw new Error('workflow state is invalid');
  }
  if (!Number.isSafeInteger(value.revision) || value.revision < 1) throw new Error('revision is invalid');
  if (!Array.isArray(value.hook_sequence) || value.hook_sequence.length === 0
      || value.hook_sequence.some((entry) => typeof entry !== 'string' || entry.length === 0)) {
    throw new Error('hook sequence is invalid');
  }
  if (value.reviewer_capabilities !== 'reviewer-readonly-v1') {
    throw new Error('reviewer capability profile is invalid');
  }
  if (!value.changed_file_hashes || typeof value.changed_file_hashes !== 'object'
      || Array.isArray(value.changed_file_hashes)) {
    throw new Error('changed file hashes are invalid');
  }
  const changedKeys = Object.keys(value.changed_file_hashes);
  if ([...changedKeys].sort().join('\0') !== changedKeys.join('\0')) {
    throw new Error('changed file hashes are not sorted');
  }
  for (const [file, hash] of Object.entries(value.changed_file_hashes)) {
    if (!file || file.startsWith('/') || file.includes('..') || !HASH_RE.test(hash)) {
      throw new Error('changed file hash entry is invalid');
    }
  }
  for (const field of ['cli_version', 'plugin_version']) {
    if (typeof value[field] !== 'string' || value[field].trim() === '') throw new Error(`${field} is invalid`);
  }
  if (!HASH_RE.test(value.source_revision || '') || value.source_revision !== value.runtime_digest) {
    throw new Error('source_revision must equal the runtime content digest');
  }
  if (!Number.isSafeInteger(value.exit_code)) throw new Error('exit code is invalid');
  return value;
}

module.exports = {
  ATTESTATION_FIELDS,
  ATTESTATION_PREFIX,
  HASH_RE,
  canonicalJson,
  controlLine,
  sanitizeModelText,
  strictParse,
  validateShape,
};
