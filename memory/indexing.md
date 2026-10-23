# Indexing: composite indexes for fast lookups

*Updated 2026-10-24*

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

## Open

- **Who owns an index.** Proposed: an index is identified by its ordered
  field list, and a table records which plugins asked for it. `add_index`
  adds a claim and creates the index if needed; `drop_index` removes only
  the caller's claim, and the index goes with its last claim. That gives no
  duplicate indexes and no consumer breaking another's lookups. Awaiting
  the user's choice (2026-10-24).
- **`PRAGMA optimize`** on registering an index and on close, so the
  planner has statistics. Verify that it analyzes expression indexes.
- **Todo, later:** lookups combining tags with fields. Tags live in
  `tagging`, outside the JSON, which is the one place a key table like
  datadungeon's would help. Not needed now (the user, 2026-10-24).
