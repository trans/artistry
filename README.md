# Artistry

**Artifact + Registry** - A SQLite-based datastore that lets disparate libraries and applications register their data needs and coexist harmoniously in a single database.

## Core Concepts

- **Registry** - Plugins register artifact kinds with schemas; each gets a unique short code (E for "event", U for "user", etc.)
- **Unified Identity** - Global auto-increment IDs across all artifacts, addressable via slugs like `E42`
- **JSON Payload** - Flexible schema stored as JSON, with expression indexes for performance
- **COW Versioning** - Updates create new versions by default; full history preserved
- **Links** - Cross-reference any artifact to any other

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  artistry:
    github: transfire/artistry
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
  schema: {title: "string", date: "datetime", priority: "integer"},
  description: "Calendar events",
  index: ["title", "date"]  # creates expression indexes
)
# => "E" (assigned code)
```

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
v1 = Artistry::Artifact.create("event", {title: "Draft"})
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
artifact.updated_at  # => timestamp
```

### Links

```crystal
event = Artistry::Artifact.create("event", {title: "Meeting"})
person = Artistry::Artifact.create("person", {name: "Alice"})

# Create link
Artistry::Link.create(event, person, "organizer")
Artistry::Link.create(event, person, "attendee", {role: "presenter"})

# Query links
Artistry::Link.from(event, "attendee")  # outgoing
Artistry::Link.to(person, "organizer")  # incoming

# Resolve
link = Artistry::Link.from(event).first
link.to  # => the person artifact
```

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
| `identity` | Global ID generator |
| `registry` | Kind registrations (code, kind, plugin) |
| `schema` | Versioned schemas with hash |
| `artifact` | All artifacts (JSON payload, COW tracking) |
| `link` | Cross-artifact references |

## License

MIT
