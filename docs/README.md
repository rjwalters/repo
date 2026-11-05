# docs/

Design and review records for this repository. These are deliberate records,
not user documentation, and they are **not installed** into consumer repos
(`docs/` is outside the installed surface). Usage documentation lives in the
top-level [`README.md`](../README.md) and in `commands/` / `skills/`.

| Record | Purpose | Issue | Status |
| --- | --- | --- | --- |
| [`guard-confinement-review.md`](guard-confinement-review.md) | Owner review of the gf180-opamp evidence handoff: classifies 29 inert synthetic cases against the canonical destructive-command guard (`hooks/repo/guard-destructive.sh`). A review record only; it authorizes no guard, hook, settings or CI change. | #692 | Historical (point-in-time review) |
| [`remote-exec-provenance.md`](remote-exec-provenance.md) | Requirement → owner → gap map for remote-execution provenance (SHA pinning, dirty-tree refusal, output stamping) across `/repo:remote` and 2run. | #681 | Current, partially landed (`/repo:remote` step 5 shipped in #697; other increments remain proposals) |

Status meanings: **current** records still track live work; **historical**
records describe a past point in time and are kept for reference.
