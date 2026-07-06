# Goober — agent guide

Goober is a family-only "Uber for golf carts" for a yearly 4th-of-July beach trip. **`PRD.md` is the product + design source of truth — read it before writing code.** `README.md` covers the stack and layout; `pitch.html` is the family-facing vision.

## Agent skills

### Issue tracker

Issues live in the `tdashroy/goober` GitHub repo (via the `gh` CLI); external PRs are **not** a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map 1:1 to identically-named GitHub labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root (created lazily; `PRD.md` is the interim glossary). See `docs/agents/domain.md`.
