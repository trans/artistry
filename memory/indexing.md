# Indexing: composite indexes for fast lookups

*Updated 2026-10-24*

**Built, not yet committed** (2026-10-24): `Registry.add_index`,
`drop_index`, `indexes`; `register(index:)` taking a field or an ordered
list; the `kind_index` table; migrations on open; `Artistry.optimize`.
The project's MEMORY.md ("Indexes (0.13)") and README describe it.

The user asked whether datadungeon's consumer-defined indexes would suit
artistry (2026-10-24). datadungeon keeps one ordered key string per asset
in an `asset_keys` table and range-scans it by prefix. It needs that
because its tags are one row per tag, and a composite index needs the
values in one row. Artistry's data is already one JSON row, so SQLite can
build the same ordered index itself, as a composite expression index
(`json_extract` of each field, in order), partial on the kind's code and
`new_id IS NULL`, and keep it up to date on every write.

## Measurements

200k artifacts plus 20k superseded versions, modeled on datadungeon's
voice-line benchmark: voice (20 values), bit (50k), beat (5), fmt (1% wav).
Median time to fetch the matching ids.

| Lookup | Single-field indexes (today) | With ANALYZE | Composite | Key table |
|---|---|---|---|---|
| voice+bit+beat | 19 ms (planner picked `beat`) | 0.01 ms | 0.001-0.008 ms | 0.001 ms |
| voice + fmt=wav | 1.7 ms | 1.6 ms | 0.36 ms | 10.5 ms |
| voice alone (10k rows) | 5.2 ms | 5.6 ms | 0.58 ms | 7.8 ms |
| bit alone (not leading) | 0.007 ms | 0.007 ms | 58 ms; 0.014 ms with ANALYZE (skip-scan) | can't |

With no index, every lookup takes about 58 ms. `register(index:)`'s
single-field indexes are used (SQLite matches the partial index once
`code = ?` is bound), but SQLite uses one per query, and with no
statistics it can pick a poor one. Artistry never runs ANALYZE.
The benchmark was a scratch script (not kept yet): it built a store
through the public API, then timed raw SQL under each set of indexes.

## Decided

- Any consumer can add an index on any kind, not just the kind's plugin
  (the user, 2026-10-24).
- Index current versions only (`new_id IS NULL`): queries with
  `include_superseded: true` scan (the user, 2026-10-24).

- **Ownership: shared indexes with recorded claims** (the user chose this
  over a shared pool and per-consumer indexes, 2026-10-24). An index is
  identified by its ordered field list; `kind_index` records which plugins
  asked for it; it goes with its last claim. No duplicates, and no consumer
  breaks another's lookups.

## Found while building

- `PRAGMA optimize` analyzes never-analyzed tables even on a fresh
  connection, in about 10 ms at 220k rows. Its sampled statistics are rough
  (2001 rows a value where the truth is 11k-110k) but rank fields well
  enough. Artistry runs it on open (0x10002) and close.
- **`idx_artifact_new_id` was a trap once statistics exist.** It indexed
  every row, so the statistics put `new_id IS NULL` at about 11 rows (rows
  per distinct value), though it matches nearly every row; the planner then
  read every current artifact. It now covers superseded rows only (`WHERE
  new_id IS NOT NULL`), which still serves the successor lookup.
- End to end at 220k rows: opening an old store converted four per-field
  indexes into claims and rebuilt `idx_artifact_new_id` in 684 ms (once);
  a four-field `add_index` took 194 ms; `Artifact.where` on leading fields
  took 0.02-0.03 ms, `bit` alone 0.06 ms.

## Open

- **Todo, later:** lookups combining tags with fields. Tags live in
  `tagging`, outside the JSON, which is the one place a key table like
  datadungeon's would help. Not needed now (the user, 2026-10-24).
