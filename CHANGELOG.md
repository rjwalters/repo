# Changelog

## 0.2.0 (2026-07-15)

- Add `repo:all` — umbrella command that runs the full hygiene pass in order
  (audit → tidy → update-tools → reset), each stage report-first. Excludes
  `repo:remote` since it provisions paid infrastructure.

## 0.1.0 (2026-07-14)

Initial release.

- Skills: `repo:help`, `repo:audit`, `repo:reset`, `repo:tidy`, `repo:remote`,
  `repo:update-tools`, `repo:branches`, `repo:gitignore`, `repo:links`,
  `repo:orphans`, `repo:readme`
- `install.sh` / `uninstall.sh` following the Anvil/Loom consumer-repo pattern
  (namespaced `.claude/` copies, marker-bounded CLAUDE.md block, install metadata)
- Hygiene skills ported from an internal monorepo and generalized to work in
  any git repository
