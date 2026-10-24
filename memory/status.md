# Status

*Updated 2026-10-23*

## 0.13.0: consumer indexes

- **Released: `v0.13.0` on `82a9805`** (2026-10-23). Any
  plugin can add a composite index on a kind's fields; see
  [indexing.md](indexing.md). The user approved the commit, the version,
  keeping the benchmark (`bench/indexes.cr`) and telling @ipck
  (2026-10-23).
- @ipck was told what the first open of a store does (see
  [coordination.md](coordination.md)).

## 0.12.0: Jargon 0.22

- **Released: `v0.12.0` on `674a781`** (2026-10-23). Jargon moved from `~> 0.16.0` to
  `~> 0.22.1` (it resolves to 0.22.2), validation got stricter, and
  `Registry.register` now raises `InvalidSchema`. The project's MEMORY.md
  ("Jargon 0.22") lists the behavior changes.
- @ipck's check of its databases came back clean before the release (see
  [coordination.md](coordination.md)).
- The user chose to tag `main`, so 0.12.0 already names jargon's new
  source (2026-10-23). ipck can't take it until memo publishes a release
  with the new source too (below).

## Open

- **Jargon's repository moved** from `trans/jargon` to
  `openbohemians/jargon.cr` (the old URL redirects). The user had every
  project's `shard.yml` switched (2026-10-23). shards fails with "ambiguous
  sources" when one build sees jargon under both names, and it reads a
  dependency's `shard.yml` from the version it resolves, not from a local
  checkout.
  - **Switched and pushed:** artistry `674a781`, memo `fa6ed05`, microgpt
    `e657283`, cyclops `5df416f`, transfs `18a4198`, xerp `0e77866`,
    c0-fmt `564ea44`. Each lock keeps its jargon version; only the URL
    changed.
  - **Held, because switching now breaks their install:** ipck (gets
    jargon through released artistry and memo: switch when it takes
    releases of both that use the new source), agpt and agpt-slot-selection
    (lock microgpt at `bdd8e82`, still the old source: switch when they
    next update microgpt's `main`), finfry (through keep's c0 0.10.1: switch
    when it moves to c0 0.11, which no longer depends on jargon).
- **Formatting:** `crystal tool format --check` flags lines older than
  `8496f93`: `src/artistry/artifact.cr`, the `code` parameter's trailing
  comma in `Registry.register`, and two aligned keys in the spec. Left
  alone so far.
