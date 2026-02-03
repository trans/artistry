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

### Schema Validation
Validation is always enabled (no opt-out). Strict mode is default (unknown fields rejected). Use `strict: false` to allow extra fields. All schema fields are required - no optional fields or defaults (kept simple for now).

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
| `artifact` | All data: `id`, `code`, `version`, `data` (JSON), `hash`, `superseded_by`, `updated_at` |
| `link` | Cross-references: `from_id`, `to_id`, `rel`, `data` (JSON), `created_at` |

## Kind Code Allocation

When registering `kind: "event"`, the system assigns the shortest available prefix:
- "E" if available
- "EV" if "E" is taken
- "EVE" if "EV" is taken
- etc.

First-come-first-serve.

## Schema Validation

Supported types: `string`, `integer`, `float`, `number`, `boolean`, `array`, `object`, `any`

```crystal
Artistry::Registry.register(
  kind: "task",
  plugin: "app",
  schema: {title: "string", count: "integer", done: "boolean"}
)

# Valid
Artistry::Artifact.create("task", {title: "Test", count: 1, done: false})

# Invalid - wrong type
Artistry::Artifact.create("task", {title: 123, ...})
# => ValidationError: title: expected string, got integer

# Invalid - unknown field (strict default)
Artistry::Artifact.create("task", {..., extra: "x"})
# => ValidationError: extra: unknown field

# Allow unknown fields
Artistry::Artifact.create("task", data, strict: false)
```

## What's Implemented

- Registration with auto-code assignment
- Schema versioning (bumps version when schema hash changes)
- Schema validation with type checking
- Expression indexes via `index: ["field1", "field2"]`
- Optional `symbol` field for emoji association with kinds
- Artifact CRUD
- COW updates with `superseded_by` chain
- Mutable updates via `update!`
- History traversal: `successor`, `latest`, `history`
- Queries: `find(id)`, `find(slug)`, `where(code)`, `where(code, field: value)`
- `include_superseded: true` option for queries
- Links between artifacts with optional data payload

## What's NOT Implemented

- Optional fields in schemas (all fields required)
- Default values for schema fields
- Richer query operators (like, gt, lt, etc.)

## TODO: Optional Fields & Defaults

Consider adding support for optional fields and default values. Design discussion notes:

**Possible syntax for defaults** (array format, JSON-compatible):
```crystal
schema: {
  title: "string",              # required
  count: ["integer", 0],        # optional with default
  status: ["string", "draft"]   # optional with default
}
```

**Questions to resolve:**
- Do we need nil/null support, or is "field absent" sufficient?
- Should `?` suffix mean nullable (`"string?"`) or optional?
- Are defaults applied at create time only, or also when field is missing on read?
- Should defaults be stored in the artifact, or computed on access?

Keep it simple - start with defaults only, skip nil support unless needed.
- Full-text search (FTS5)
- Transactions wrapper
- Migration tooling for schema changes
- Soft delete (currently hard delete only)

## API Patterns

```crystal
# Open DB
Artistry.open("path.db")

# Register
Artistry::Registry.register(
  kind: "event",
  plugin: "myapp",
  schema: {title: "string"},
  symbol: "📅",
  index: ["title"]
)

# Create
artifact = Artistry::Artifact.create("event", {title: "Meeting"})

# COW update
new_version = artifact.update({title: "Updated"})

# Mutable update
artifact.update!({title: "Changed"})

# Links
Artistry::Link.create(from, to, "organizer")
Artistry::Link.from(artifact, "organizer")
Artistry::Link.to(artifact, "organizer")
```

## File Structure

```
src/
  artistry.cr         # Main module, open/close DB
  artistry/
    database.cr       # Schema DDL
    validator.cr      # Schema validation
    registry.cr       # Registration logic
    artifact.cr       # Artifact CRUD, COW, queries
    link.cr           # Cross-references
spec/
  artistry_spec.cr    # 45 specs covering all features
```

## Testing

```bash
crystal spec
```

All tests use in-memory SQLite (`:memory:`).

## Owner's Vision

The user (Thomas Sawyer) is building this for a specific project that needs COW semantics. The hyperlink-style cross-referencing via slugs is central to their mental model. They want it to stay simple and focused - not become a full ORM.
