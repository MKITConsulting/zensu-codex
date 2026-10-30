'use strict';

const RETRUST_HINT = 'If Zensu was just updated: Codex skips a changed or untrusted hook without notice, so open /hooks and trust every Zensu hook (the Zensu Session Control SessionStart hook creates this state), then start a new session.';

if (require.main === module) process.stdout.write(RETRUST_HINT);

module.exports = { RETRUST_HINT };
