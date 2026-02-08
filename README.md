# Artistry

**Artifact + Registry** - A SQLite-based datastore that lets disparate libraries and applications register their data needs and coexist harmoniously in a single database.

## Core Concepts

- **Registry** - Plugins register artifact kinds with schemas; each gets a unique short code (E for "event", U for "user", etc.)
- **Unified Identity** - Global auto-increment IDs across all artifacts, addressable via slugs like `E42`
- **JSON Payload** - Flexible schema stored as JSON, with expression indexes for performance
- **Schema Validation** - Type checking on create and update (strict by default)
- **COW Versioning** - Updates create new versions by default; full history preserved
- **Links** - Cross-reference any artifact to any other with typed relations (auto-deleted with CASCADE)

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  artistry:
    github: trans/artistry
```

Then run `shards install`.

## Usage

### Setup

```crystal
require "artistry"

# Open database (creates tables if needed)
Artistry.open("myapp.db")
```

### Register Artifact Kinds

```crystal
Artistry::Registry.register(
  kind: "event",
  plugin: "myapp",
  schema: {title: "string", date: "string", priority: "integer"},
  description: "Calendar events",
  symbol: "📅",                 # optional emoji for display
  index: ["title", "date"]      # creates expression indexes
)
# => "E" (assigned code)
```

### Schema Types

Supported types for schema validation:

| Type | Description |
|------|-------------|
| `"string"` | JSON string |
| `"integer"` | JSON integer |
| `"float"` | JSON float |
| `"number"` | integer or float |
| `"boolean"` | JSON boolean |
| `"array"` | JSON array |
| `"object"` | JSON object |
| `"any"` | any value (skip type check) |

All schema fields are required. Unknown fields are rejected by default (strict mode).

### Create Artifacts

```crystal
event = Artistry::Artifact.create("event", {
  title: "Team Meeting",
  date: "2025-06-15T10:00:00Z",
  priority: 1
})

event.slug       # => "E1"
event.id         # => 1
event["title"]   # => "Team Meeting" (as JSON::Any)
```

### Validation

```crystal
# Invalid type - raises ValidationError
Artistry::Artifact.create("event", {title: 123, ...})
# => ValidationError: title: expected string, got integer

# Unknown field - rejected by default
Artistry::Artifact.create("event", {title: "Test", ..., extra: "x"})
# => ValidationError: extra: unknown field

# Allow unknown fields with strict: false
Artistry::Artifact.create("event", data, strict: false)
```

### Query

```crystal
# By ID
Artistry::Artifact.find(1)

# By slug
Artistry::Artifact.find("E1")

# By kind
Artistry::Artifact.where("E")

# With conditions
Artistry::Artifact.where("E", priority: 1)
```

### Update (COW - default)

Creates a new version, supersedes the old:

```crystal
v1 = Artistry::Artifact.create("event", {title: "Draft", ...})
v2 = v1.update({title: "Final"})

v1.superseded?   # => true
v2.current?      # => true
v1.successor     # => v2
v2.history       # => [v1, v2]
```

### Update (Mutable)

Modifies in place:

```crystal
artifact.update!({title: "Changed"})
artifact.updated_at  # => unix milliseconds (Int64)
```

### Links

Links use `rel` (relation) to describe the relationship type:

```crystal
event = Artistry::Artifact.create("event", {title: "Meeting", ...})
person = Artistry::Artifact.create("person", {name: "Alice"})

# Create link with relation type
Artistry::Link.create(event, person, "organizer")
Artistry::Link.create(event, person, "attendee", {role: "presenter"})

# Query links by relation
Artistry::Link.from(event, "attendee")  # outgoing
Artistry::Link.to(person, "organizer")  # incoming

# Resolve linked artifacts
link = Artistry::Link.from(event).first
link.to   # => the person artifact
link.rel  # => "attendee"
```

### Tags

Tags are normalized — each unique tag string is stored once, then linked to artifacts via a junction table.

```crystal
# Tag an artifact
Artistry::Tag.tag(event, "security")
Artistry::Tag.tag(event, "mvp")

# Get tags for an artifact
Artistry::Tag.for(event)  # => [Tag("mvp"), Tag("security")]

# Find artifacts by tag
Artistry::Tag.artifacts("security")

# OR query - artifacts with any of the tags
Artistry::Tag.artifacts_any(["security", "mvp"])

# AND query - artifacts with all of the tags
Artistry::Tag.artifacts_all(["security", "mvp"])

# Replace all tags at once
Artistry::Tag.sync(event, ["v2", "released"])

# Remove a tag
Artistry::Tag.untag(event, "mvp")
```

### Transactions

Wrap multiple operations in a transaction for atomicity. The block yields a transaction context with convenient shortcuts:

```crystal
Artistry.transaction do |art|
  event = art.create("event", {title: "Meeting"})
  person = art.create("person", {name: "Alice"})
  art.link(event, person, "organizer")
  art.tag(event, "important")
end
# Auto-commits on success, auto-rollbacks on exception
```

The transaction context provides: `create`, `find`, `where`, `tag`, `untag`, `sync_tags`, `tags_for`, `link`, `unlink`, `links_from`, `links_to`, `rollback`, `commit`.

Call `art.rollback` for explicit rollback, or raise `DB::Rollback` for a silent rollback (no exception propagated). Class methods (`Artistry::Artifact.create`, etc.) also work inside the block and participate in the same transaction.

### Versioning Queries

```crystal
# Current versions only (default)
Artistry::Artifact.where("E")

# Include superseded versions
Artistry::Artifact.where("E", include_superseded: true)
```

## Tables

| Table | Purpose |
|-------|---------|
| `identity` | Global ID generator with `created_at` |
| `registry` | Kind registrations (`code`, `kind`, `plugin`, `description`, `symbol`, `version`) |
| `schema` | Versioned schemas with JSON and hash |
| `artifact` | All artifacts (JSON payload, COW tracking via `new_id`) |
| `link` | Cross-artifact references (`from_id`, `to_id`, `rel`, `data`) - CASCADE delete |
| `tag` | Unique tag names (`id`, `name`) |
| `tagging` | Junction table linking tags to artifacts - CASCADE delete both directions |

## Technical Notes

- **Timestamps**: All `created_at`/`updated_at` fields are unix epoch milliseconds (Int64). Convert with `Time.unix_ms(ts)` in Crystal.
- **Foreign Keys**: FK constraints are enforced. Link and tagging FKs use `ON DELETE CASCADE` - deleting an artifact removes its links and taggings; deleting a tag removes its taggings.

## License

MIT
