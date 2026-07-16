#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const CONTENTION_SESSION = 'zensu-session-control-concurrency-contention-v1';

function canonicalDirectory(input, label) {
  const directory = fs.realpathSync.native(input);
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory`);
  return directory;
}

function readJson(file) {
  const stat = fs.lstatSync(file);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size === 0) throw new Error(`invalid ledger file: ${file}`);
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function verify(ledgerInput, pluginRootInput, expectedCount = 12, width = 4) {
  const ledger = canonicalDirectory(ledgerInput, 'concurrency ledger');
  const pluginRoot = canonicalDirectory(pluginRootInput, 'plugin root');
  const core = require(path.join(pluginRoot, 'hooks', 'lib', 'session-control-core-v1.js'));
  const participantRoot = canonicalDirectory(path.join(ledger, 'participants'), 'participant ledger');
  const participantFiles = fs.readdirSync(participantRoot).filter((name) => name.endsWith('.json')).sort();
  if (participantFiles.length !== expectedCount) {
    throw new Error(`expected ${expectedCount} successful contention participants, found ${participantFiles.length}`);
  }
  const participants = participantFiles.map((name) => readJson(path.join(participantRoot, name)));
  const uniqueSessions = new Set(participants.map((entry) => entry.session_id_hash));
  const slots = participants.map((entry) => entry.slot).sort((a, b) => a - b);
  const contentionHashes = new Set(participants.map((entry) => entry.contention_session_hash));
  const runtimeDigests = new Set(participants.map((entry) => entry.contention_runtime_digest));
  if (uniqueSessions.size !== expectedCount) throw new Error('fresh-session participant hashes are not unique');
  if (slots.some((slot, index) => slot !== index + 1)) throw new Error('contention participant slots are incomplete');
  if (contentionHashes.size !== 1 || runtimeDigests.size !== 1) throw new Error('participants did not share one immutable context');
  for (let wave = 0; wave < expectedCount / width; wave += 1) {
    if (participants.filter((entry) => entry.wave === wave).length !== width) {
      throw new Error(`contention wave ${wave} does not contain ${width} participants`);
    }
  }
  const records = canonicalDirectory(path.join(ledger, 'shared-plugin-data', 'records'), 'shared records');
  const recordEntries = fs.readdirSync(records);
  const expectedRecord = `${core.sessionKey(CONTENTION_SESSION)}.json`;
  if (recordEntries.length !== 1 || recordEntries[0] !== expectedRecord) {
    throw new Error(`expected exactly one shared immutable record, found ${recordEntries.join(',')}`);
  }
  const context = core.readContext({ recordsDir: records, sessionId: CONTENTION_SESSION, expectedHost: 'codex' });
  if (context.session_id_hash !== [...contentionHashes][0] || context.runtime_digest !== [...runtimeDigests][0]) {
    throw new Error('shared record does not match all participant receipts');
  }
  const persisted = fs.readFileSync(path.join(records, expectedRecord), 'utf8');
  if (persisted.includes(CONTENTION_SESSION)) throw new Error('raw contention session id leaked to the record');
  return {
    participants: expectedCount,
    unique_sessions: uniqueSessions.size,
    contention_waves: expectedCount / width,
    shared_records: 1,
    contention_session_hash: context.session_id_hash,
    runtime_digest: context.runtime_digest,
  };
}

module.exports = { CONTENTION_SESSION, verify };

if (require.main === module) {
  try {
    const result = verify(process.argv[2], process.argv[3], Number(process.argv[4] || 12), Number(process.argv[5] || 4));
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
