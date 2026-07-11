# add-feature (eval fixture)

A minimal Node.js project used by the `$zensu-tdd` reference eval. Empty on
purpose — the agent implements the requested feature under TDD.

- **Test runner:** `node --test` (built-in). Tests live under `test/*.test.js`.
- **Source:** CommonJS modules under `src/`.
- Keep changes scoped to the requested feature; run the tests to prove green.
