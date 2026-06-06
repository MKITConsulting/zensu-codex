# Documentation Guide

How to generate feature/component documentation in Zensu so it is **grounded in
the actual source code**, correctly typed, and useful — not a restatement of
feature metadata.

This is the single source of truth referenced by `agents/zensu-plm.md`,
`skills/implement/SKILL.md`, and `skills/ghost-scan/SKILL.md`. Read it before
creating any wiki page or linked doc.

## What a Zensu doc IS

A Zensu doc explains **real behavior, read from the real source files** — actual
endpoints, function signatures, request/response shapes, config keys, error
codes, data flow. It is written for a specific **audience** and a specific
**doc type** (see below).

`get_doc_generation_context` returns the **map, not the territory**: the feature
title, description, `detectedSourceFiles` paths, security posture, tiers,
journeys, and symbol metadata. It tells you *which* files matter and *what*
security/tier constraints apply. It does **not** contain the source code. You
must open and read those files yourself before writing.

The agent has filesystem access. Reading the real source produces docs that are
*better* than the backend's frontend-only generator (which sees only extracted
symbol metadata, never full source).

## Anti-pattern (forbidden): the metadata dump

The failure this guide exists to prevent: condensing
`get_doc_generation_context` metadata straight into Markdown without reading any
source. It produces generic, templated pages that just re-list feature
attributes — e.g.:

```
## Purpose
<feature.description verbatim>
## Source files
<detectedSourceFiles paths, nothing about what they do>
## Security
Classification: confidential · Security score: 5.5
## Notes / Integrations
Priority high, status planned. Reference docs: …/README.md
```

This is **not documentation** — it is the feature record reformatted. Never
publish it. If you have not opened the source files, you are not ready to write.

## Doc types

Canonical set (8). The **Focus** column is the authoritative description of what
each type must contain — it mirrors the backend doc generator verbatim.

| `doc_type`      | audience            | Focus |
|-----------------|---------------------|-------|
| `user_facing`   | `end_user`          | How end users interact with this feature. Usage examples, prerequisites, step-by-step instructions. |
| `api_reference` | `developer`         | API endpoints, request/response formats, authentication, error codes, integration examples. |
| `tutorial`      | `developer`         | Step-by-step instructions through a concrete task. Prerequisites, expected outcomes, troubleshooting tips. |
| `adr`           | `internal`          | The architectural decision, context, alternatives considered, consequences. ADR format: Status, Context, Decision, Consequences. |
| `release_notes` | `end_user`          | What changed: new features, improvements, bug fixes, breaking changes, migration steps. |
| `internal`      | `internal`          | Architecture decisions, data flow, component interactions, configuration, dependencies, known limitations. |
| `migration_guide` | `developer`       | Breaking changes, step-by-step migration, database migrations, rollback procedures, verification steps. |
| `overview`      | `developer`         | High-level overview of the component/feature: responsibilities, contained features, architecture, API surface. |

Audiences: `end_user`, `developer`, `admin`, `internal`.

Pick the type by what the reader needs. A confidential backend feature usually
warrants `internal` (+ `api_reference` if it exposes endpoints); a user-visible
capability warrants `user_facing`; an architectural choice warrants `adr`.

## Procedure (read-source-first)

1. **Get the map.** Call `get_doc_generation_context` with the `feature_id` and
   the target `doc_type`. Note the `detectedSourceFiles`, symbols, security
   posture, tiers, and journeys.
2. **Read the territory.** Open the source files named in the context (Read /
   Grep). For `api_reference`, find the real route definitions and DTOs; for
   `internal`, trace the data flow across the files; for `user_facing`, find the
   real entry points and config the user touches.
3. **Author, grounded in code.** Write Markdown that cites real symbols,
   signatures, endpoints, and behavior — matched to the doc type's Focus and the
   audience. No invented APIs; if you did not see it in the source, do not claim
   it.
4. **Publish.** `create_wiki_page` with the markdown `content`, `entity_type`,
   `entity_id`, `doc_type`, and `audience`. Then `link_docs` to update the
   feature's docs score. Use `link_docs` alone (no wiki page) only for docs that
   already live in the repo or at an external URL.

## Tools

| Tool | Role |
|------|------|
| `get_doc_generation_context` | Fetch the context (the map). Read the named source before writing. |
| `create_wiki_page` / `update_wiki_page` | Publish authored markdown to the wiki (`content` is the full markdown). |
| `link_docs` | Register a doc (file path / external URL) against a feature; updates the docs score. |

The rich `POST /api/features/{id}/docs/generate` streaming LLM path is
**frontend-only** — it is not exposed as an MCP tool. Agents do not call it;
they self-author from real source per the procedure above.

## Quality checklist

Before publishing, confirm:

- [ ] I opened and read the `detectedSourceFiles` — not just their paths.
- [ ] Content cites real signatures / endpoints / config / behavior from those files.
- [ ] It matches the doc type's Focus and is written for the stated audience.
- [ ] It is not the anti-pattern (a reformatted feature record).
- [ ] `doc_type` and `audience` are from the canonical sets above.
