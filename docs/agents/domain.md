# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

**Layout: single-context.** One product, one shared domain (rides, groups, points, IOUs, places) across the Flutter app and the Rust server. A single `CONTEXT.md` + `docs/adr/` at the repo root. `PRD.md` at the root is the current design source of truth and glossary until `CONTEXT.md` is filled in.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root, or
- **`CONTEXT-MAP.md`** at the repo root if it exists — it points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo (this repo):

```
/
├── PRD.md                             ← current design source of truth + glossary
├── CONTEXT.md                         ← domain glossary (created lazily)
├── docs/adr/                          ← architectural decisions (created lazily)
│   ├── 0001-....md
│   └── 0002-....md
└── app/  server/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md` (or, until it exists, `PRD.md`). Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (...) — but worth reopening because…_
