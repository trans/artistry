# Handover Notes

## What is Artistry?

**Artistry = Artifact + Registry**

A SQLite-based "meta" datastore that lets multiple libraries/apps register their data needs and coexist in a single database. Think of it as a plugin system for database records with a unified identity layer.

## Core Design Decisions

### JSON Payload, Not Per-Kind Tables
We chose a single `artifact` table with JSON `data` column rather than creating separate tables per registered kind. This keeps the system dynamic - schemas are runtime data, not compile-time DDL.

### COW by Default
`update()` creates a new version and supersedes the old. This preserves history automatically. Use `update!()` for mutable in-place changes when needed.

### Class-First Was Rejected
We explicitly decided NOT to make this an ORM. Users who want typed wrappers can build thin classes over `Artifact` themselves. Artistry stays focused on the registry/identity/versioning layer.

### Links vs Edges
We went with "link" terminology (not "edge") because of the hyperlink metaphor that inspired the design. The `link` table uses `rel` (relation) to describe the relationship type - avoiding confusion with artifact "kind". The link table is separate from COW versioning - those are different concerns.

### Slugs
Format is `{CODE}{ID}` with no separator, e.g., `E42` not `E:42`. The colon was deemed unnecessary.

### Schema Validation (JSON Schema)
Schemas use a JSON Schema subset (powered by the Jargon library). Validation is always enabled (no opt-out). Schemas control strictness via `additionalProperties: false`. Optional fields and defaults are supported natively.

### Timestamps
All timestamps (`created_at`, `updated_at`) are stored as INTEGER (unix epoch milliseconds) for performance. Convert with `Time.unix_ms(timestamp)` in Crystal or `datetime(ts/1000, 'unixepoch')` in SQL.

### Foreign Key Enforcement
FK constraints are enforced (`PRAGMA foreign_keys = ON`). Link table FKs use `ON DELETE CASCADE` - deleting an artifact automatically removes all links to/from it.

## Tables

| Table | Purpose |
|-------|---------|
| `identity` | Global auto-increment ID, `created_at` |
| `registry` | Kind registrations: `code`, `kind`, `plugin`, `description`, `symbol`, `version` |
| `schema` | Versioned schemas: `code`, `version`, `json`, `hash`, `created_at` |
| `artifact` | All data: `id`, `code`, `version`, `data` (JSON), `hash`, `new_id`, `updated_at` |
| `link` | Cross-references: `from_id`, `to_id`, `rel`, `data` (JSON), `created_at` |
| `tag` | Unique tag names: `id`, `name`, `created_at` |
| `tagging` | Junction: `tag_id`, `artifact_id`, `created_at` |

## Kind Code Allocation

When registering `kind: "event"`, the system assigns the shortest available prefix:
- "E" if available
- "EV" if "E" is taken
- "EVE" if "EV" is taken
- etc.

First-come-first-serve.

## Schema Validation (JSON Schema Subset)

Schemas use a JSON Schema subset via the Jargon library (`Jargon::Validator`). Supported keywords:
`type`, `properties`, `required`, `additionalProperties`, `default`, `enum`, `const`,
`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`,
`minLength`, `maxLength`, `pattern`, `format`, `items`, `minItems`, `maxItems`,
`uniqueItems`, `description`, `$ref`, `$defs`

NOT supported: `allOf`/`anyOf`/`oneOf`/`not`, `if`/`then`/`else`, `patternProperties`, `prefixItems`

```crystal
Artistry::Registry.register(
  kind: "task",
  plugin: "app",
  schema: {
    type: "object",
    properties: {
      title:  {type: "string", minLength: 1},
      count:  {type: "integer", minimum: 0, default: 0},
      status: {type: "string", enum: ["open", "closed"], default: "open"},
      done:   {type: "boolean"},
    },
    required: ["title", "done"],
    additionalProperties: false,
  }
)

# Valid — count defaults to 0, status defaults to "open"
Artistry::Artifact.create("task", {title: "Test", done: false})

# Invalid - wrong type
Artistry::Artifact.create("task", {title: 123, done: false})
# => ValidationError: title: expected String, got Int64

# Invalid - unknown field (additionalProperties: false)
Artistry::Artifact.create("task", {title: "Test", done: false, extra: "x"})
# => ValidationError: extra: additionalProperties is false

# Allow unknown fields (omit additionalProperties or set to true)
```

## What's Implemented

- Registration with auto-code assignment
- Schema versioning (bumps version when schema hash changes)
- JSON Schema validation (via Jargon) with type checking, constraints, defaults
- Expression indexes via `index: ["field1", "field2"]`
- Optional `symbol` field for emoji association with kinds
- Artifact CRUD
- COW updates with `new_id` chain
- Mutable updates via `update!`
- History traversal: `successor`, `latest`, `history`
- Queries: `find(id)`, `find(slug)`, `where(code)`, `where(code, field: value)`
- `include_superseded: true` option for queries
- Links between artifacts with optional data payload
- Tags with normalized two-table design (tag + tagging junction)
- Transactions via `Artistry.transaction { |art| }` with context object (fiber-safe)

## Tags (Implemented)

Normalized two-table design:
- `tag` table: `id`, `name` (UNIQUE), `created_at` — each string stored once
- `tagging` junction table: `tag_id`, `artifact_id` (composite PK), `created_at` — CASCADE both directions
- No namespaces (flat names, convention-based if needed)
- `Tag.tag/untag/sync` for tagging, `Tag.for/artifacts/artifacts_any/artifacts_all` for queries

## Transactions (Implemented)

`Artistry.transaction` yields a `Transaction` context object with delegated API shortcuts:
`art.create`, `art.find`, `art.where`, `art.tag`, `art.untag`, `art.sync_tags`, `art.tags_for`,
`art.link`, `art.unlink`, `art.links_from`, `art.links_to`, `art.rollback`, `art.commit`.

Internally uses a fiber-keyed hash (`@@tx_connections`) to pin each fiber's operations to a single
DB connection. All internal code uses `Artistry.conn` (returns tx connection or pool). Class methods
also work inside the block and participate in the same transaction. Auto-commits on success,
auto-rollbacks on exception. `DB::Rollback` for silent rollback.

## What's NOT Implemented

- Richer query operators (like, gt, lt, etc.)
- Full-text search (FTS5)
- Migration tooling for schema changes
- Soft delete (currently hard delete only)

## API Patterns

```crystal
# Open DB
Artistry.open("path.db")

# Register with JSON Schema
Artistry::Registry.register(
  kind: "event",
  plugin: "myapp",
  schema: {
    type: "object",
    properties: {
      title: {type: "string", minLength: 1},
      date:  {type: "string", format: "date"},
    },
    required: ["title"],
  },
  symbol: "📅",
  index: ["title"]
)

# Create (defaults applied automatically)
artifact = Artistry::Artifact.create("event", {title: "Meeting"})

# COW update
new_version = artifact.update({title: "Updated"})

# Mutable update
artifact.update!({title: "Changed"})

# Links
Artistry::Link.create(from, to, "organizer")
Artistry::Link.from(artifact, "organizer")
Artistry::Link.to(artifact, "organizer")

# Tags
Artistry::Tag.tag(artifact, "security")
Artistry::Tag.untag(artifact, "security")
Artistry::Tag.sync(artifact, ["v2", "released"])
Artistry::Tag.for(artifact)
Artistry::Tag.artifacts("security")
Artistry::Tag.artifacts_any(["security", "mvp"])
Artistry::Tag.artifacts_all(["security", "mvp"])

# Transactions
Artistry.transaction do |art|
  event = art.create("event", {title: "Meeting"})
  person = art.create("person", {name: "Alice"})
  art.link(event, person, "organizer")
  art.tag(event, "important")
  art.rollback if some_condition
end
```

## File Structure

```
src/
  artistry.cr         # Main module, open/close DB
  artistry/
    database.cr       # Schema DDL
    validator.cr      # JSON Schema validation (via Jargon)
    registry.cr       # Registration logic
    artifact.cr       # Artifact CRUD, COW, queries
    link.cr           # Cross-references
    tag.cr            # Tags (normalized two-table)
    transaction.cr    # Transaction context (delegation)
spec/
  artistry_spec.cr    # 92 specs covering all features
```

## Testing

```bash
crystal spec
```

All tests use in-memory SQLite (`:memory:`).

## Owner's Vision

The user (Thomas Sawyer) is building this for a specific project that needs COW semantics. The hyperlink-style cross-referencing via slugs is central to their mental model. They want it to stay simple and focused - not become a full ORM.
