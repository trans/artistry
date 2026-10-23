# Status

*Updated 2026-10-23*

## 0.12.0: Jargon 0.22

- **Committed in `8496f93`, not tagged.** Jargon moved from `~> 0.16.0` to
  `~> 0.22.1` (it resolves to 0.22.2), validation got stricter, and
  `Registry.register` now raises `InvalidSchema`. The project's MEMORY.md
  ("Jargon 0.22") lists the behavior changes.
- The user said to commit and bump the version but not tag yet
  (2026-10-23). The only thing tagging was waiting on, @ipck's check of its
  databases, came back clean that day (see [coordination.md](coordination.md)).
  So `v0.12.0` waits only on the user's go-ahead.
- `main` (`8496f93`, `183a05f`) was not pushed as of 2026-10-23.

## Open

- **Jargon's repository moved** from `trans/jargon` to
  `openbohemians/jargon.cr`. The old URL redirects, and every project of the
  user's that depends on jargon, artistry included, still says
  `github: trans/jargon`. Switch them all at once, or not at all: a project
  that pulls jargon in under both names (ipck does, through artistry and
  memo) fails `shards install` with "ambiguous sources".
- **Formatting:** `crystal tool format --check` flags lines older than
  `8496f93`: `src/artistry/artifact.cr`, the `code` parameter's trailing
  comma in `Registry.register`, and two aligned keys in the spec. Left
  alone so far.
