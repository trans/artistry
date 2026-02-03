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
We went with "link" terminology (not "edge") because of the hyperlink metaphor that inspired the design. The `link` table is separate from COW versioning - those are different concerns.

### Slugs
Format is `{CODE}{ID}` with no separator, e.g., `E42` not `E:42`. The colon was deemed unnecessary.

## Tables

| Table | Purpose |
|-------|---------|
| `identity` | Global auto-increment ID, `created_at` |
| `registry` | Kind registrations: `code`, `kind`, `plugin`, `description`, `version` |
| `schema` | Versioned schemas: `code`, `version`, `json`, `hash`, `created_at` |
| `artifact` | All data: `id`, `code`, `version`, `data` (JSON), `hash`, `superseded_by`, `updated_at` |
| `link` | Cross-references: `from_id`, `to_id`, `kind`, `data` (JSON), `created_at` |

## Kind Code Allocation

When registering `kind: "event"`, the system assigns the shortest available prefix:
- "E" if available
- "EV" if "E" is taken
- "EVE" if "EV" is taken
- etc.

First-come-first-serve.

## What's Implemented

- Registration with auto-code assignment
- Schema versioning (bumps version when schema hash changes)
- Expression indexes via `index: ["field1", "field2"]`
- Artifact CRUD
- COW updates with `superseded_by` chain
- Mutable updates via `update!`
- History traversal: `successor`, `latest`, `history`
- Queries: `find(id)`, `find(slug)`, `where(code)`, `where(code, field: value)`
- `include_superseded: true` option for queries
- Links between artifacts with optional data payload

## What's NOT Implemented

- Schema validation (data is not validated against schema on create/update)
- Richer query operators (like, gt, lt, etc.)
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
  index: ["title"]
)

# Create
artifact = Artistry::Artifact.create("event", {title: "Meeting"})

# COW update
new_version = artifact.update({title: "Updated"})

# Mutable update
artifact.update!({title: "Changed"})

# Links
Artistry::Link.create(from, to, "relationship")
Artistry::Link.from(artifact, "relationship")
Artistry::Link.to(artifact, "relationship")
```

## File Structure

```
src/
  artistry.cr         # Main module, open/close DB
  artistry/
    database.cr       # Schema DDL
    registry.cr       # Registration logic
    artifact.cr       # Artifact CRUD, COW, queries
    link.cr           # Cross-references
spec/
  artistry_spec.cr    # 30 specs covering all features
```

## Testing

```bash
crystal spec
```

All tests use in-memory SQLite (`:memory:`).

## Owner's Vision

The user (Thomas Sawyer) is building this for a specific project that needs COW semantics. The hyperlink-style cross-referencing via slugs is central to their mental model. They want it to stay simple and focused - not become a full ORM.
