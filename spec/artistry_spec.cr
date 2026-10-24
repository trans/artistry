require "./spec_helper"

# Helper to build a simple object schema
def simple_schema(props : NamedTuple, required : Array(String) = props.keys.map(&.to_s).to_a)
  {
    type:       "object",
    properties: props,
    required:   required,
  }
end

# The SQLite indexes on the artifact table
def artifact_indexes : Array(String)
  Artistry.db.query_all("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'artifact'", as: String)
end

# A query's plan, a line per step
def query_plan(sql : String, args : Array(DB::Any)) : String
  steps = [] of String
  Artistry.db.query("EXPLAIN QUERY PLAN #{sql}", args: args) do |rs|
    rs.each { rs.read; rs.read; rs.read; steps << rs.read(String) }
  end
  steps.join("\n")
end

describe Artistry do
  around_each do |example|
    Artistry.open(":memory:") do
      example.run
    end
  end

  describe "open with existing connection" do
    it "uses a borrowed DB connection" do
      db = DB.open("sqlite3:%3Amemory%3A")
      db.exec("PRAGMA foreign_keys = ON")
      Artistry.open(db)

      code = Artistry::Registry.register(
        kind: "event", plugin: "test",
        schema: simple_schema({title: {type: "string"}}))
      artifact = Artistry::Artifact.create(code, {title: "Test"})
      artifact["title"].as_s.should eq("Test")

      Artistry.close
      # Borrowed connection should still be open after Artistry.close
      db.scalar("SELECT 1").should eq(1)
    ensure
      db.try &.close
    end
  end

  describe Artistry::Registry do
    it "registers a new kind and assigns shortest code" do
      code = Artistry::Registry.register(
        kind: "event",
        plugin: "memo",
        schema: simple_schema({title: {type: "string"}})
      )
      code.should eq("E")
    end

    it "assigns longer code when short one is taken" do
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {type: "object"})
      code = Artistry::Registry.register(kind: "entry", plugin: "blog", schema: {type: "object"})
      code.should eq("EN")
    end

    it "finds registration by code" do
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {type: "object"})
      reg = Artistry::Registry.find("E")
      reg.should_not be_nil
      reg.not_nil!.kind.should eq("event")
      reg.not_nil!.plugin.should eq("memo")
    end

    it "finds registration by plugin and kind" do
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {type: "object"})
      reg = Artistry::Registry.find("memo", "event")
      reg.should_not be_nil
      reg.not_nil!.code.should eq("E")
    end

    it "bumps version when schema changes" do
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {v: 1})
      reg1 = Artistry::Registry.find("E").not_nil!
      reg1.version.should eq(1)

      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {v: 2})
      reg2 = Artistry::Registry.find("E").not_nil!
      reg2.version.should eq(2)
    end

    describe "indexes" do
      line_schema = simple_schema({voice: {type: "string"}, bit: {type: "string"}, beat: {type: "string"}})

      it "creates the indexes register asks for: a field, or fields in order" do
        Artistry::Registry.register(kind: "event", plugin: "memo", schema: {type: "object"}, index: ["title", ["date", "place"]])
        indexes = Artistry::Registry.indexes("event")
        indexes.map { |i| {i.fields, i.plugins} }.should eq([{["date", "place"], ["memo"]}, {["title"], ["memo"]}])
        indexes.each { |i| artifact_indexes.should contain(i.name) }
      end

      it "lets any plugin add one, shared with others asking for the same fields" do
        Artistry::Registry.register(kind: "line", plugin: "speech", schema: line_schema)
        mine = Artistry::Registry.add_index("line", %w[bit beat voice], plugin: "cattacula")
        theirs = Artistry::Registry.add_index("L", %w[bit beat voice], plugin: "Overlore")
        theirs.name.should eq(mine.name)
        theirs.plugins.should eq(["cattacula", "overlore"])
        artifact_indexes.count(mine.name).should eq(1)
      end

      it "keeps an index until the last plugin that asked for it drops it" do
        Artistry::Registry.register(kind: "line", plugin: "speech", schema: line_schema, index: ["voice"])
        name = Artistry::Registry.add_index("line", "voice", plugin: "cattacula").name
        Artistry::Registry.drop_index("line", "voice", plugin: "nobody").should be_false
        Artistry::Registry.drop_index("line", "voice", plugin: "speech").should be_true
        Artistry::Registry.indexes("line").map(&.plugins).should eq([["cattacula"]])
        artifact_indexes.should contain(name)

        Artistry::Registry.drop_index("line", "voice", plugin: "cattacula").should be_true
        Artistry::Registry.indexes("line").should be_empty
        artifact_indexes.should_not contain(name)
      end

      it "serves where for its leading fields, over current versions" do
        Artistry::Registry.register(kind: "line", plugin: "speech", schema: line_schema, index: [%w[voice bit beat]])
        line = Artistry::Artifact.create("line", {voice: "v1", bit: "b1", beat: "1"})
        line.update({voice: "v1", bit: "b1", beat: "2"})
        Artistry::Artifact.where("L", voice: "v1", bit: "b1").map(&.["beat"].as_s).should eq(["2"])

        # Given enough lines that reading them all costs more, and statistics,
        # the query Artifact.where makes (the code bound as it binds it)
        # reads the index.
        20.times { |i| Artistry::Artifact.create("line", {voice: "v#{i % 4}", bit: "b#{i + 2}", beat: "1"}) }
        Artistry.optimize
        sql = "SELECT #{Artistry::Artifact::FIND_COLUMNS} FROM artifact a JOIN identity i ON a.id = i.id " \
              "WHERE a.code = ? AND a.new_id IS NULL " \
              "AND json_extract(a.data, '$.voice') = ? AND json_extract(a.data, '$.bit') = ? ORDER BY a.id"
        query_plan(sql, ["L", "v1", "b1"] of DB::Any).should contain(Artistry::Registry.indexes("line").first.name)
      end

      it "keeps full statistics, so a kind's code doesn't look selective" do
        Artistry::Registry.register(kind: "line", plugin: "speech", schema: line_schema)
        Artistry.transaction do
          2_500.times { |i| Artistry::Artifact.create("line", {voice: "v#{i % 2}", bit: "b#{i}", beat: "1"}) }
        end
        Artistry.optimize
        # A sampled analysis (optimize's default) stops near 2000: "2500 2001".
        Artistry.db.query_one("SELECT stat FROM sqlite_stat1 WHERE idx = 'idx_artifact_code'", as: String)
          .should eq("2500 2500")
      end

      it "rejects fields it can't index" do
        Artistry::Registry.register(kind: "line", plugin: "speech", schema: line_schema)
        [[] of String, %w[voice voice], ["it's"], ["two words"], ["1st"], ["meta..author"]].each do |fields|
          expect_raises(Artistry::InvalidIndex) do
            Artistry::Registry.add_index("line", fields, plugin: "speech")
          end
        end
        Artistry::Registry.add_index("line", %w[meta.author first-name], plugin: "speech").fields.should eq(%w[meta.author first-name])
      end

      it "raises for an unknown kind" do
        expect_raises(Artistry::Error, /Unknown artifact kind: nope/) do
          Artistry::Registry.add_index("nope", "title", plugin: "speech")
        end
      end

      it "turns older per-field indexes into claims by the kind's plugin" do
        Artistry::Registry.register(kind: "event", plugin: "memo", schema: {type: "object"})
        # As register(index:) made them before 0.13.
        Artistry.db.exec("CREATE INDEX IF NOT EXISTS idx_memo_event_title ON artifact(json_extract(data, '$.title')) WHERE code = 'E'")
        Artistry::Database.ensure_schema(Artistry.db)

        artifact_indexes.should_not contain("idx_memo_event_title")
        indexes = Artistry::Registry.indexes("event")
        indexes.map { |i| {i.fields, i.plugins} }.should eq([{["title"], ["memo"]}])
        artifact_indexes.should contain(indexes.first.name)
      end

      it "indexes new_id over superseded versions only, on older databases too" do
        Artistry.db.exec("DROP INDEX idx_artifact_new_id")
        Artistry.db.exec("CREATE INDEX idx_artifact_new_id ON artifact(new_id)")
        Artistry::Database.ensure_schema(Artistry.db)
        Artistry.db.query_one("SELECT sql FROM sqlite_master WHERE name = 'idx_artifact_new_id'", as: String)
          .should contain("WHERE new_id IS NOT NULL")
      end
    end

    describe "declared codes" do
      it "honors a declared code even when a shorter one is free" do
        code = Artistry::Registry.register(kind: "assumption", plugin: "justice", schema: {type: "object"}, code: "AS")
        code.should eq("AS")
        Artistry::Registry.find("AS").not_nil!.kind.should eq("assumption")
      end

      it "is idempotent when re-registered with or without the code" do
        Artistry::Registry.register(kind: "claim", plugin: "justice", schema: {type: "object"}, code: "C")
        Artistry::Registry.register(kind: "claim", plugin: "justice", schema: {type: "object"}, code: "C").should eq("C")
        Artistry::Registry.register(kind: "claim", plugin: "justice", schema: {type: "object"}).should eq("C")
      end

      it "doesn't depend on registration order" do
        Artistry::Registry.register(kind: "citation", plugin: "memory", schema: {type: "object"}, code: "CI")
        Artistry::Registry.register(kind: "claim", plugin: "justice", schema: {type: "object"}, code: "C").should eq("C")
      end

      it "raises CodeConflict naming both owners" do
        Artistry::Registry.register(kind: "citation", plugin: "memory", schema: {type: "object"}, code: "C")
        ex = expect_raises(Artistry::CodeConflict) do
          Artistry::Registry.register(kind: "claim", plugin: "justice", schema: {type: "object"}, code: "C")
        end
        ex.message.not_nil!.should contain("justice/claim")
        ex.message.not_nil!.should contain("memory/citation")
        ex.owner_plugin.should eq("memory")
      end

      it "raises CodeMismatch when a registered kind declares a different code" do
        Artistry::Registry.register(kind: "assumption", plugin: "justice", schema: {type: "object"})
        ex = expect_raises(Artistry::CodeMismatch) do
          Artistry::Registry.register(kind: "assumption", plugin: "justice", schema: {type: "object"}, code: "AS")
        end
        ex.registered_code.should eq("A")
        ex.declared_code.should eq("AS")
      end

      it "rejects codes that aren't one or two uppercase letters" do
        ["", "abc", "ABC", "a", "A1", "Q-"].each do |bad|
          expect_raises(Artistry::InvalidCode) do
            Artistry::Registry.register(kind: "question", plugin: "justice", schema: {type: "object"}, code: bad)
          end
        end
      end
    end

    describe "allocated codes" do
      it "stays within two letters" do
        codes = %w(definition design decide decision deliverable).map do |kind|
          Artistry::Registry.register(kind: kind, plugin: "p", schema: {type: "object"})
        end
        codes.should eq(["D", "DE", "DC", "DI", "DL"])
        codes.each { |c| c.size.should be <= 2 }
      end

      it "raises when every code for the first letter is taken" do
        (["Z"] + ('A'..'Z').map { |c| "Z#{c}" }).each_with_index do |c, i|
          Artistry::Registry.register(kind: "k#{i}", plugin: "p", schema: {type: "object"}, code: c)
        end
        expect_raises(Artistry::Error, /No free code/) do
          Artistry::Registry.register(kind: "zebra", plugin: "p", schema: {type: "object"})
        end
      end
    end

    describe "schema checks" do
      it "raises InvalidSchema when a declared type contradicts properties" do
        schema = simple_schema({title: {type: "string", properties: {x: {type: "string"}}}})
        expect_raises(Artistry::InvalidSchema, /memo\/event.*title.*type: object/) do
          Artistry::Registry.register(kind: "event", plugin: "memo", schema: schema)
        end
      end

      it "raises InvalidSchema for an invalid pattern" do
        expect_raises(Artistry::InvalidSchema, /memo\/event/) do
          Artistry::Registry.register(kind: "event", plugin: "memo", schema: simple_schema({title: {type: "string", pattern: "("}}))
        end
      end

      it "registers nothing when the schema is invalid" do
        expect_raises(Artistry::InvalidSchema) do
          Artistry::Registry.register(kind: "event", plugin: "memo", schema: {type: "string", items: {type: "string"}})
        end
        Artistry::Registry.find("memo", "event").should be_nil
      end

      it "doesn't bump the version for an invalid schema change" do
        Artistry::Registry.register(kind: "event", plugin: "memo", schema: {type: "object"})
        expect_raises(Artistry::InvalidSchema) do
          Artistry::Registry.register(kind: "event", plugin: "memo", schema: {type: "string", properties: {} of String => String})
        end
        Artistry::Registry.find("E").not_nil!.version.should eq(1)
      end
    end
  end

  describe Artistry::Artifact do
    before_each do
      Artistry::Registry.register(
        kind: "event",
        plugin: "memo",
        schema: simple_schema({title: {type: "string"}}),
        description: "Calendar events"
      )
    end

    it "creates an artifact" do
      artifact = Artistry::Artifact.create("E", {title: "Meeting"})
      artifact.id.should eq(1)
      artifact.code.should eq("E")
      artifact.slug.should eq("E1")
      artifact["title"].as_s.should eq("Meeting")
      artifact.hash.should_not be_empty
    end

    it "creates via plugin and kind" do
      artifact = Artistry::Artifact.create("memo", "event", {title: "Meeting"})
      artifact.code.should eq("E")
    end

    it "creates via kind name only" do
      artifact = Artistry::Artifact.create("event", {title: "Meeting"})
      artifact.code.should eq("E")
    end

    it "finds by id" do
      created = Artistry::Artifact.create("E", {title: "Meeting"})
      found = Artistry::Artifact.find(created.id)
      found.should_not be_nil
      found.not_nil!.slug.should eq(created.slug)
    end

    it "finds by slug" do
      created = Artistry::Artifact.create("E", {title: "Meeting"})
      found = Artistry::Artifact.find("E#{created.id}")
      found.should_not be_nil
      found.not_nil!.id.should eq(created.id)
    end

    it "queries by code" do
      Artistry::Artifact.create("E", {title: "Event 1"})
      Artistry::Artifact.create("E", {title: "Event 2"})
      results = Artistry::Artifact.where("E")
      results.size.should eq(2)
    end

    it "queries with conditions" do
      Artistry::Artifact.create("E", {title: "Meeting", priority: "high"})
      Artistry::Artifact.create("E", {title: "Lunch", priority: "low"})
      results = Artistry::Artifact.where("E", priority: "high")
      results.size.should eq(1)
      results[0]["title"].as_s.should eq("Meeting")
    end

    describe "COW updates" do
      it "creates new version on update" do
        v1 = Artistry::Artifact.create("E", {title: "Draft"})
        v2 = v1.update({title: "Final"})

        v2.id.should_not eq(v1.id)
        v2["title"].as_s.should eq("Final")
        v2.current?.should be_true
      end

      it "marks old version as superseded" do
        v1 = Artistry::Artifact.create("E", {title: "Draft"})
        v2 = v1.update({title: "Final"})

        # Reload v1 to see new_id
        v1_reloaded = Artistry::Artifact.find(v1.id).not_nil!
        v1_reloaded.superseded?.should be_true
        v1_reloaded.new_id.should eq(v2.id)
      end

      it "follows successor chain" do
        v1 = Artistry::Artifact.create("E", {title: "v1"})
        v2 = v1.update({title: "v2"})

        v1_reloaded = Artistry::Artifact.find(v1.id).not_nil!
        v1_reloaded.successor.not_nil!.id.should eq(v2.id)
      end

      it "gets latest version" do
        v1 = Artistry::Artifact.create("E", {title: "v1"})
        v2 = v1.update({title: "v2"})
        v3 = v2.update({title: "v3"})

        v1_reloaded = Artistry::Artifact.find(v1.id).not_nil!
        v1_reloaded.latest.id.should eq(v3.id)
      end

      it "gets full history" do
        v1 = Artistry::Artifact.create("E", {title: "v1"})
        v2 = v1.update({title: "v2"})
        v3 = v2.update({title: "v3"})

        history = v3.history
        history.size.should eq(3)
        history[0].id.should eq(v1.id)
        history[1].id.should eq(v2.id)
        history[2].id.should eq(v3.id)
      end

      it "prevents update on superseded artifact" do
        v1 = Artistry::Artifact.create("E", {title: "v1"})
        v1.update({title: "v2"})

        v1_reloaded = Artistry::Artifact.find(v1.id).not_nil!
        expect_raises(Exception, /superseded/) do
          v1_reloaded.update({title: "v3"})
        end
      end

      it "excludes superseded from where by default" do
        v1 = Artistry::Artifact.create("E", {title: "Event"})
        v1.update({title: "Event Updated"})

        results = Artistry::Artifact.where("E")
        results.size.should eq(1)
        results[0]["title"].as_s.should eq("Event Updated")
      end

      it "includes superseded when requested" do
        v1 = Artistry::Artifact.create("E", {title: "Event"})
        v1.update({title: "Event Updated"})

        results = Artistry::Artifact.where("E", include_superseded: true)
        results.size.should eq(2)
      end
    end

    describe "mutable updates" do
      it "updates in place with update!" do
        artifact = Artistry::Artifact.create("E", {title: "Draft"})
        original_id = artifact.id
        updated = artifact.update!({title: "Final"})

        updated.id.should eq(original_id)
        updated["title"].as_s.should eq("Final")
        updated.updated_at.should_not be_nil
      end

      it "preserves original created_at on update!" do
        artifact = Artistry::Artifact.create("E", {title: "Draft"})
        original_created_at = artifact.created_at
        updated = artifact.update!({title: "Final"})

        updated.created_at.should eq(original_created_at)
      end
    end

    it "deletes artifact" do
      artifact = Artistry::Artifact.create("E", {title: "Temp"})
      id = artifact.id
      artifact.delete
      Artistry::Artifact.find(id).should be_nil
    end
  end

  describe Artistry::Link do
    before_each do
      Artistry::Registry.register(kind: "event", plugin: "memo",
        schema: simple_schema({title: {type: "string"}}))
      Artistry::Registry.register(kind: "person", plugin: "memo",
        schema: simple_schema({name: {type: "string"}}))
    end

    it "creates a link between artifacts" do
      event = Artistry::Artifact.create("event", {title: "Meeting"})
      person = Artistry::Artifact.create("person", {name: "Alice"})

      link = Artistry::Link.create(event, person, "organizer")
      link.from_id.should eq(event.id)
      link.to_id.should eq(person.id)
      link.rel.should eq("organizer")
    end

    it "creates link with data" do
      event = Artistry::Artifact.create("event", {title: "Meeting"})
      person = Artistry::Artifact.create("person", {name: "Alice"})

      link = Artistry::Link.create(event, person, "attendee", {role: "presenter"})
      link.data.not_nil!["role"].as_s.should eq("presenter")
    end

    it "finds outgoing links" do
      event = Artistry::Artifact.create("event", {title: "Meeting"})
      alice = Artistry::Artifact.create("person", {name: "Alice"})
      bob = Artistry::Artifact.create("person", {name: "Bob"})

      Artistry::Link.create(event, alice, "attendee")
      Artistry::Link.create(event, bob, "attendee")

      links = Artistry::Link.from(event, "attendee")
      links.size.should eq(2)
    end

    it "finds incoming links" do
      event1 = Artistry::Artifact.create("event", {title: "Meeting 1"})
      event2 = Artistry::Artifact.create("event", {title: "Meeting 2"})
      person = Artistry::Artifact.create("person", {name: "Alice"})

      Artistry::Link.create(event1, person, "organizer")
      Artistry::Link.create(event2, person, "organizer")

      links = Artistry::Link.to(person, "organizer")
      links.size.should eq(2)
    end

    it "resolves linked artifacts" do
      event = Artistry::Artifact.create("event", {title: "Meeting"})
      person = Artistry::Artifact.create("person", {name: "Alice"})

      link = Artistry::Link.create(event, person, "organizer")

      link.from.not_nil!["title"].as_s.should eq("Meeting")
      link.to.not_nil!["name"].as_s.should eq("Alice")
    end

    it "deletes a link" do
      event = Artistry::Artifact.create("event", {title: "Meeting"})
      person = Artistry::Artifact.create("person", {name: "Alice"})

      link = Artistry::Link.create(event, person, "organizer")
      link.delete

      Artistry::Link.find(event.id, person.id, "organizer").should be_nil
    end
  end

  describe Artistry::Validator do
    before_each do
      Artistry::Registry.register(
        kind: "task",
        plugin: "test",
        schema: {
          type:       "object",
          properties: {
            title: {type: "string"},
            count: {type: "integer"},
            score: {type: "number"},
            done:  {type: "boolean"},
            tags:  {type: "array", items: {type: "string"}},
            meta:  {type: "object"},
          },
          required:             ["title", "count", "score", "done", "tags", "meta"],
          additionalProperties: false,
        }
      )
    end

    describe "type validation" do
      it "accepts valid string field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
        })
        artifact["title"].as_s.should eq("Test")
      end

      it "rejects wrong type for string field" do
        expect_raises(Artistry::ValidationError, /title.*expected/) do
          Artistry::Artifact.create("task", {
            title: 123, count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
          })
        end
      end

      it "names schema types in type errors" do
        ex = expect_raises(Artistry::ValidationError) do
          Artistry::Artifact.create("task", {
            title: 123, count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
          })
        end
        ex.errors.map { |e| {e.field, e.message} }.should eq([{"title", "expected string, got integer"}])
      end

      it "validates a schema that omits the root type" do
        Artistry::Registry.register(
          kind: "note",
          plugin: "test",
          schema: {properties: {count: {type: "integer"}, status: {type: "string", default: "draft"}}}
        )
        expect_raises(Artistry::ValidationError, /count: expected integer/) do
          Artistry::Artifact.create("note", {count: "x"})
        end
        Artistry::Artifact.create("note", {count: 1})["status"].as_s.should eq("draft")
      end

      it "accepts valid integer field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 42, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
        })
        artifact["count"].as_i.should eq(42)
      end

      it "rejects wrong type for integer field" do
        expect_raises(Artistry::ValidationError, /count.*expected/) do
          Artistry::Artifact.create("task", {
            title: "Test", count: "not a number", score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
          })
        end
      end

      it "accepts valid number field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 3.14, done: false, tags: [] of String, meta: {} of String => String,
        })
        artifact["score"].as_f.should eq(3.14)
      end

      it "accepts integer as number field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 10, done: false, tags: [] of String, meta: {} of String => String,
        })
        artifact["score"].as_i.should eq(10)
      end

      it "accepts valid boolean field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: true, tags: [] of String, meta: {} of String => String,
        })
        artifact["done"].as_bool.should eq(true)
      end

      it "accepts valid array field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: ["a", "b"], meta: {} of String => String,
        })
        artifact["tags"].as_a.size.should eq(2)
      end

      it "accepts valid object field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {key: "value"},
        })
        artifact["meta"]["key"].as_s.should eq("value")
      end
    end

    describe "required fields" do
      it "rejects missing required field" do
        expect_raises(Artistry::ValidationError, /title.*required/) do
          Artistry::Artifact.create("task", {
            count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
          })
        end
      end

      it "accepts missing optional field" do
        Artistry::Registry.register(
          kind: "note",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              title: {type: "string"},
              body:  {type: "string"},
            },
            required: ["title"],
          }
        )
        artifact = Artistry::Artifact.create("note", {title: "Hello"})
        artifact["title"].as_s.should eq("Hello")
      end
    end

    describe "additionalProperties" do
      it "rejects unknown fields when additionalProperties is false" do
        expect_raises(Artistry::ValidationError, /extra/) do
          Artistry::Artifact.create("task", {
            title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String, extra: "data",
          })
        end
      end

      it "allows unknown fields when additionalProperties is not false" do
        Artistry::Registry.register(
          kind: "note",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {title: {type: "string"}},
            required:   ["title"],
          }
        )
        artifact = Artistry::Artifact.create("note", {title: "Test", extra: "data"})
        artifact["extra"].as_s.should eq("data")
      end
    end

    describe "default values" do
      it "applies default when field is absent" do
        Artistry::Registry.register(
          kind: "item",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              title:  {type: "string"},
              status: {type: "string", default: "draft"},
            },
            required: ["title"],
          }
        )
        artifact = Artistry::Artifact.create("item", {title: "Hello"})
        artifact["status"].as_s.should eq("draft")
      end

      it "does not override explicit value with default" do
        Artistry::Registry.register(
          kind: "item",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              title:  {type: "string"},
              status: {type: "string", default: "draft"},
            },
            required: ["title"],
          }
        )
        artifact = Artistry::Artifact.create("item", {title: "Hello", status: "published"})
        artifact["status"].as_s.should eq("published")
      end

      it "applies defaults on update" do
        Artistry::Registry.register(
          kind: "item",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              title:  {type: "string"},
              status: {type: "string", default: "draft"},
            },
            required: ["title"],
          }
        )
        artifact = Artistry::Artifact.create("item", {title: "Hello"})
        updated = artifact.update({title: "Updated"})
        updated["status"].as_s.should eq("draft")
      end
    end

    describe "string constraints" do
      before_each do
        Artistry::Registry.register(
          kind: "constrained",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              name:  {type: "string", minLength: 2, maxLength: 10},
              code:  {type: "string", pattern: "^[A-Z]+$"},
            },
            required: ["name"],
          }
        )
      end

      it "rejects string shorter than minLength" do
        expect_raises(Artistry::ValidationError, /name/) do
          Artistry::Artifact.create("constrained", {name: "A"})
        end
      end

      it "rejects string longer than maxLength" do
        expect_raises(Artistry::ValidationError, /name/) do
          Artistry::Artifact.create("constrained", {name: "A" * 11})
        end
      end

      it "rejects string not matching pattern" do
        ex = expect_raises(Artistry::ValidationError) do
          Artistry::Artifact.create("constrained", {name: "Valid", code: "lower"})
        end
        ex.errors.map { |e| {e.field, e.message} }.should eq([{"code", "must match pattern: ^[A-Z]+$"}])
      end

      it "doesn't let $ in a pattern match before a trailing newline" do
        expect_raises(Artistry::ValidationError, /code: must match pattern/) do
          Artistry::Artifact.create("constrained", {name: "Valid", code: "ABC\n"})
        end
      end

      it "accepts string matching all constraints" do
        artifact = Artistry::Artifact.create("constrained", {name: "Valid", code: "ABC"})
        artifact["name"].as_s.should eq("Valid")
        artifact["code"].as_s.should eq("ABC")
      end
    end

    describe "numeric constraints" do
      before_each do
        Artistry::Registry.register(
          kind: "ranged",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              age:   {type: "integer", minimum: 0, maximum: 150},
              score: {type: "number", exclusiveMinimum: 0, exclusiveMaximum: 100},
            },
            required: ["age"],
          }
        )
      end

      it "rejects integer below minimum" do
        expect_raises(Artistry::ValidationError, /age/) do
          Artistry::Artifact.create("ranged", {age: -1})
        end
      end

      it "rejects integer above maximum" do
        expect_raises(Artistry::ValidationError, /age/) do
          Artistry::Artifact.create("ranged", {age: 200})
        end
      end

      it "rejects value at exclusiveMinimum" do
        expect_raises(Artistry::ValidationError, /score/) do
          Artistry::Artifact.create("ranged", {age: 25, score: 0})
        end
      end

      it "rejects value at exclusiveMaximum" do
        expect_raises(Artistry::ValidationError, /score/) do
          Artistry::Artifact.create("ranged", {age: 25, score: 100})
        end
      end

      it "accepts values within range" do
        artifact = Artistry::Artifact.create("ranged", {age: 25, score: 50.5})
        artifact["age"].as_i.should eq(25)
      end
    end

    describe "array constraints" do
      before_each do
        Artistry::Registry.register(
          kind: "listing",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              items: {type: "array", items: {type: "string"}, minItems: 1, maxItems: 3},
            },
            required: ["items"],
          }
        )
      end

      it "rejects array with wrong item type" do
        expect_raises(Artistry::ValidationError) do
          Artistry::Artifact.create("listing", {items: [1, 2]})
        end
      end

      it "rejects array shorter than minItems" do
        expect_raises(Artistry::ValidationError, /items/) do
          Artistry::Artifact.create("listing", {items: [] of String})
        end
      end

      it "rejects array longer than maxItems" do
        expect_raises(Artistry::ValidationError, /items/) do
          Artistry::Artifact.create("listing", {items: ["a", "b", "c", "d"]})
        end
      end

      it "accepts valid array" do
        artifact = Artistry::Artifact.create("listing", {items: ["a", "b"]})
        artifact["items"].as_a.size.should eq(2)
      end
    end

    describe "enum validation" do
      it "accepts value in enum" do
        Artistry::Registry.register(
          kind: "status",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              state: {type: "string", enum: ["open", "closed", "pending"]},
            },
            required: ["state"],
          }
        )
        artifact = Artistry::Artifact.create("status", {state: "open"})
        artifact["state"].as_s.should eq("open")
      end

      it "rejects value not in enum" do
        Artistry::Registry.register(
          kind: "status",
          plugin: "test",
          schema: {
            type:       "object",
            properties: {
              state: {type: "string", enum: ["open", "closed", "pending"]},
            },
            required: ["state"],
          }
        )
        expect_raises(Artistry::ValidationError, /state.*must be one of/) do
          Artistry::Artifact.create("status", {state: "invalid"})
        end
      end
    end

    describe "update validation" do
      it "validates on COW update" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
        })
        expect_raises(Artistry::ValidationError, /count.*expected/) do
          artifact.update({count: "invalid"})
        end
      end

      it "validates on mutable update" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
        })
        expect_raises(Artistry::ValidationError, /count.*expected/) do
          artifact.update!({count: "invalid"})
        end
      end
    end

    describe "multiple errors" do
      it "reports all validation errors" do
        begin
          Artistry::Artifact.create("task", {
            title: 123, count: "wrong", score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
          })
          fail "Expected ValidationError"
        rescue ex : Artistry::ValidationError
          ex.errors.size.should eq(2)
          ex.errors.map(&.field).should contain("title")
          ex.errors.map(&.field).should contain("count")
        end
      end
    end
  end

  describe Artistry::Tag do
    before_each do
      Artistry::Registry.register(kind: "event", plugin: "memo",
        schema: simple_schema({title: {type: "string"}}))
    end

    it "creates a tag" do
      tag = Artistry::Tag.create("security")
      tag.name.should eq("security")
      tag.id.should be > 0
    end

    it "find-or-creates on duplicate name" do
      t1 = Artistry::Tag.create("security")
      t2 = Artistry::Tag.create("security")
      t1.id.should eq(t2.id)
    end

    it "finds by id" do
      tag = Artistry::Tag.create("security")
      found = Artistry::Tag.find(tag.id)
      found.should_not be_nil
      found.not_nil!.name.should eq("security")
    end

    it "finds by name" do
      Artistry::Tag.create("security")
      found = Artistry::Tag.find("security")
      found.should_not be_nil
      found.not_nil!.name.should eq("security")
    end

    it "returns nil for missing tag" do
      Artistry::Tag.find("nonexistent").should be_nil
    end

    it "lists all tags" do
      Artistry::Tag.create("beta")
      Artistry::Tag.create("alpha")
      tags = Artistry::Tag.all
      tags.size.should eq(2)
      tags[0].name.should eq("alpha")
      tags[1].name.should eq("beta")
    end

    it "deletes a tag" do
      tag = Artistry::Tag.create("temporary")
      tag.delete
      Artistry::Tag.find("temporary").should be_nil
    end

    it "tags an artifact" do
      artifact = Artistry::Artifact.create("event", {title: "Meeting"})
      Artistry::Tag.tag(artifact, "important")
      tags = Artistry::Tag.for(artifact)
      tags.size.should eq(1)
      tags[0].name.should eq("important")
    end

    it "ignores duplicate tagging" do
      artifact = Artistry::Artifact.create("event", {title: "Meeting"})
      Artistry::Tag.tag(artifact, "important")
      Artistry::Tag.tag(artifact, "important")
      tags = Artistry::Tag.for(artifact)
      tags.size.should eq(1)
    end

    it "untags an artifact" do
      artifact = Artistry::Artifact.create("event", {title: "Meeting"})
      Artistry::Tag.tag(artifact, "important")
      Artistry::Tag.untag(artifact, "important")
      Artistry::Tag.for(artifact).size.should eq(0)
    end

    it "syncs tags for an artifact" do
      artifact = Artistry::Artifact.create("event", {title: "Meeting"})
      Artistry::Tag.tag(artifact, "old")
      Artistry::Tag.tag(artifact, "stale")

      Artistry::Tag.sync(artifact, ["fresh", "new"])
      tags = Artistry::Tag.for(artifact)
      tags.size.should eq(2)
      tags.map(&.name).should contain("fresh")
      tags.map(&.name).should contain("new")
      tags.map(&.name).should_not contain("old")
    end

    it "finds artifacts by tag name" do
      e1 = Artistry::Artifact.create("event", {title: "Meeting"})
      e2 = Artistry::Artifact.create("event", {title: "Lunch"})
      Artistry::Tag.tag(e1, "important")
      Artistry::Tag.tag(e2, "casual")

      results = Artistry::Tag.artifacts("important")
      results.size.should eq(1)
      results[0].id.should eq(e1.id)
    end

    it "excludes superseded artifacts from tag queries" do
      e1 = Artistry::Artifact.create("event", {title: "Draft"})
      Artistry::Tag.tag(e1, "wip")
      e1.update({title: "Final"})

      results = Artistry::Tag.artifacts("wip")
      results.size.should eq(0)
    end

    it "finds artifacts with ANY of the given tags" do
      e1 = Artistry::Artifact.create("event", {title: "Meeting"})
      e2 = Artistry::Artifact.create("event", {title: "Lunch"})
      e3 = Artistry::Artifact.create("event", {title: "Walk"})
      Artistry::Tag.tag(e1, "important")
      Artistry::Tag.tag(e2, "casual")
      Artistry::Tag.tag(e3, "exercise")

      results = Artistry::Tag.artifacts_any(["important", "casual"])
      results.size.should eq(2)
      results.map(&.id).should contain(e1.id)
      results.map(&.id).should contain(e2.id)
    end

    it "finds artifacts with ALL of the given tags" do
      e1 = Artistry::Artifact.create("event", {title: "Meeting"})
      e2 = Artistry::Artifact.create("event", {title: "Lunch"})
      Artistry::Tag.tag(e1, "important")
      Artistry::Tag.tag(e1, "urgent")
      Artistry::Tag.tag(e2, "important")

      results = Artistry::Tag.artifacts_all(["important", "urgent"])
      results.size.should eq(1)
      results[0].id.should eq(e1.id)
    end

    it "returns empty for artifacts_any with empty list" do
      Artistry::Tag.artifacts_any([] of String).size.should eq(0)
    end

    it "returns empty for artifacts_all with empty list" do
      Artistry::Tag.artifacts_all([] of String).size.should eq(0)
    end

    it "cascade deletes taggings when tag is deleted" do
      artifact = Artistry::Artifact.create("event", {title: "Meeting"})
      Artistry::Tag.tag(artifact, "temporary")
      tag = Artistry::Tag.find("temporary").not_nil!
      tag.delete
      Artistry::Tag.for(artifact).size.should eq(0)
    end

    it "cascade deletes taggings when artifact is deleted" do
      artifact = Artistry::Artifact.create("event", {title: "Meeting"})
      Artistry::Tag.tag(artifact, "important")
      artifact.delete
      # Tag still exists, but no artifacts linked
      Artistry::Tag.artifacts("important").size.should eq(0)
    end
  end

  describe "Artistry.transaction" do
    before_each do
      Artistry::Registry.register(kind: "event", plugin: "memo",
        schema: simple_schema({title: {type: "string"}}))
      Artistry::Registry.register(kind: "person", plugin: "memo",
        schema: simple_schema({name: {type: "string"}}))
    end

    it "commits on success" do
      Artistry.transaction do |art|
        art.create("event", {title: "Meeting"})
      end
      Artistry::Artifact.where("E").size.should eq(1)
    end

    it "rolls back on exception" do
      expect_raises(Exception, /boom/) do
        Artistry.transaction do |art|
          art.create("event", {title: "Meeting"})
          raise "boom"
        end
      end
      Artistry::Artifact.where("E").size.should eq(0)
    end

    it "rolls back silently on DB::Rollback" do
      Artistry.transaction do |art|
        art.create("event", {title: "Meeting"})
        raise DB::Rollback.new
      end
      Artistry::Artifact.where("E").size.should eq(0)
    end

    it "commits multiple operations atomically" do
      event = nil
      Artistry.transaction do |art|
        event = art.create("event", {title: "Meeting"})
        person = art.create("person", {name: "Alice"})
        art.link(event.not_nil!, person, "organizer")
        art.tag(event.not_nil!, "important")
      end
      Artistry::Artifact.where("E").size.should eq(1)
      Artistry::Artifact.where("P").size.should eq(1)
      Artistry::Link.from(event.not_nil!, "organizer").size.should eq(1)
      Artistry::Tag.for(event.not_nil!).size.should eq(1)
    end

    it "rolls back all operations on failure" do
      person = Artistry::Artifact.create("person", {name: "Alice"})
      expect_raises(Exception, /boom/) do
        Artistry.transaction do |art|
          event = art.create("event", {title: "Meeting"})
          art.tag(event, "important")
          art.link(event, person, "organizer")
          raise "boom"
        end
      end
      Artistry::Artifact.where("E").size.should eq(0)
      Artistry::Tag.artifacts("important").size.should eq(0)
      Artistry::Link.from(person).size.should eq(0)
    end

    it "supports explicit rollback" do
      Artistry.transaction do |art|
        art.create("event", {title: "Meeting"})
        art.rollback
      end
      Artistry::Artifact.where("E").size.should eq(0)
    end

    it "delegates find and where" do
      Artistry.transaction do |art|
        event = art.create("event", {title: "Meeting"})
        art.find(event.id).should_not be_nil
        art.find(event.slug).should_not be_nil
        art.where("E").size.should eq(1)
      end
    end

    it "delegates tag queries" do
      Artistry.transaction do |art|
        event = art.create("event", {title: "Meeting"})
        art.tag(event, "important")
        art.tags_for(event).size.should eq(1)
        art.untag(event, "important")
        art.tags_for(event).size.should eq(0)
      end
    end

    it "delegates link queries" do
      Artistry.transaction do |art|
        event = art.create("event", {title: "Meeting"})
        person = art.create("person", {name: "Alice"})
        art.link(event, person, "organizer")
        art.links_from(event, "organizer").size.should eq(1)
        art.links_to(person, "organizer").size.should eq(1)
        art.unlink(event, person, "organizer")
        art.links_from(event, "organizer").size.should eq(0)
      end
    end
  end

  describe "kind_seq" do
    before_each do
      Artistry::Registry.register(
        kind: "event", plugin: "memo",
        schema: simple_schema({title: {type: "string"}}))
      Artistry::Registry.register(
        kind: "contact", plugin: "memo",
        schema: simple_schema({name: {type: "string"}}))
    end

    it "counts sequence numbers per code" do
      Artistry.next_kind_seq("X").should eq(1)
      Artistry.next_kind_seq("X").should eq(2)
      Artistry.next_kind_seq("Y").should eq(1)
    end

    it "stamps code and kind_seq on create" do
      e1 = Artistry::Artifact.create("E", {title: "a"})
      c1 = Artistry::Artifact.create("C", {name: "b"})
      e2 = Artistry::Artifact.create("E", {title: "c"})

      e1.kind_seq.should eq(1)
      c1.kind_seq.should eq(1)
      e2.kind_seq.should eq(2)
      e2.kind_slug.should eq("2E")

      Artistry.conn.query_one("SELECT code FROM identity WHERE id = ?", e2.id, as: String).should eq("E")
    end

    it "gives an updated version the next kind_seq" do
      e1 = Artistry::Artifact.create("E", {title: "a"})
      e2 = e1.update({title: "b"})
      e2.kind_seq.should eq(2)
      e2.kind_slug.should eq("2E")
    end

    it "finds by absolute and kind-relative slugs" do
      Artistry::Artifact.create("C", {name: "x"})
      e = Artistry::Artifact.create("E", {title: "a"})

      Artistry::Artifact.find(e.slug).not_nil!.id.should eq(e.id)
      Artistry::Artifact.find("1E").not_nil!.id.should eq(e.id)
      Artistry::Artifact.find("1e").not_nil!.id.should eq(e.id)
      Artistry::Artifact.find("2E").should be_nil
      Artistry::Artifact.find("E#{e.id + 100}").should be_nil
    end

    it "upgrades an identity table created before kind_seq" do
      db = DB.open("sqlite3:%3Amemory%3A")
      db.exec(<<-SQL)
        CREATE TABLE identity (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at INTEGER NOT NULL DEFAULT 0
        )
        SQL
      db.exec("INSERT INTO identity DEFAULT VALUES")

      Artistry.open(db)

      columns = db.query_all("SELECT name FROM pragma_table_info('identity')", as: String)
      columns.should contain("code")
      columns.should contain("kind_seq")
      db.query_one?("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_identity_kind_seq'", as: String)
        .should eq("idx_identity_kind_seq")

      # Running ensure_schema again is a no-op
      Artistry::Database.ensure_schema(db)
    ensure
      Artistry.close
      db.try &.close
    end
  end
end
