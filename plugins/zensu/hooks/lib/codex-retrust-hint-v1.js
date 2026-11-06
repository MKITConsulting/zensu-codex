'use strict';

const RETRUST_HINT = 'If Zensu was just updated: Codex skips a changed or untrusted hook without notice, so open /hooks and trust every Zensu hook; an open chat then re-binds itself to the updated plugin on its next message, and when Zensu reports that it cannot re-bind the chat, start a new one. If the chat does not recover after the re-trust, reopen it: a reopened chat re-binds at its resumed SessionStart. If this repeats, start a new session (the Zensu Session Control SessionStart hook creates this state).';

if (require.main === module) process.stdout.write(RETRUST_HINT);

module.exports = { RETRUST_HINT };
