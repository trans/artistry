require "./spec_helper"

describe Artistry do
  around_each do |example|
    Artistry.open(":memory:") do
      example.run
    end
  end

  describe Artistry::Registry do
    it "registers a new kind and assigns shortest code" do
      code = Artistry::Registry.register(
        kind: "event",
        plugin: "memo",
        schema: {title: "string"}
      )
      code.should eq("E")
    end

    it "assigns longer code when short one is taken" do
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {} of String => String)
      code = Artistry::Registry.register(kind: "entry", plugin: "blog", schema: {} of String => String)
      code.should eq("EN")
    end

    it "finds registration by code" do
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {} of String => String)
      reg = Artistry::Registry.find("E")
      reg.should_not be_nil
      reg.not_nil!.kind.should eq("event")
      reg.not_nil!.plugin.should eq("memo")
    end

    it "finds registration by plugin and kind" do
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {} of String => String)
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

    it "creates indexes on specified fields" do
      Artistry::Registry.register(
        kind: "event",
        plugin: "memo",
        schema: {title: "string", date: "datetime"},
        index: ["title", "date"]
      )

      # Check indexes exist via SQLite metadata
      indexes = [] of String
      Artistry.db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_memo_event_%'") do |rs|
        rs.each do
          indexes << rs.read(String)
        end
      end

      indexes.should contain("idx_memo_event_title")
      indexes.should contain("idx_memo_event_date")
    end
  end

  describe Artistry::Artifact do
    before_each do
      Artistry::Registry.register(
        kind: "event",
        plugin: "memo",
        schema: {title: "string"},
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
      Artistry::Artifact.create("E", {title: "Meeting", priority: "high"}, strict: false)
      Artistry::Artifact.create("E", {title: "Lunch", priority: "low"}, strict: false)
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
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {title: "string"})
      Artistry::Registry.register(kind: "person", plugin: "memo", schema: {name: "string"})
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
          title: "string",
          count: "integer",
          score: "float",
          done: "boolean",
          tags: "array",
          meta: "object",
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
        expect_raises(Artistry::ValidationError, /title.*expected string/) do
          Artistry::Artifact.create("task", {
            title: 123, count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
          })
        end
      end

      it "accepts valid integer field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 42, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
        })
        artifact["count"].as_i.should eq(42)
      end

      it "rejects wrong type for integer field" do
        expect_raises(Artistry::ValidationError, /count.*expected integer/) do
          Artistry::Artifact.create("task", {
            title: "Test", count: "not a number", score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
          })
        end
      end

      it "accepts valid float field" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 3.14, done: false, tags: [] of String, meta: {} of String => String,
        })
        artifact["score"].as_f.should eq(3.14)
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
    end

    describe "strict mode" do
      it "rejects unknown fields by default" do
        expect_raises(Artistry::ValidationError, /extra.*unknown field/) do
          Artistry::Artifact.create("task", {
            title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String, extra: "data",
          })
        end
      end

      it "allows unknown fields with strict: false" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String, extra: "data",
        }, strict: false)
        artifact["extra"].as_s.should eq("data")
      end
    end

    describe "update validation" do
      it "validates on COW update" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
        })
        expect_raises(Artistry::ValidationError, /count.*expected integer/) do
          artifact.update({count: "invalid"})
        end
      end

      it "validates on mutable update" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
        })
        expect_raises(Artistry::ValidationError, /count.*expected integer/) do
          artifact.update!({count: "invalid"})
        end
      end

      it "allows unknown fields on update with strict: false" do
        artifact = Artistry::Artifact.create("task", {
          title: "Test", count: 1, score: 1.5, done: false, tags: [] of String, meta: {} of String => String,
        })
        updated = artifact.update({extra: "data"}, strict: false)
        updated["extra"].as_s.should eq("data")
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
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {title: "string"})
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
      Artistry::Registry.register(kind: "event", plugin: "memo", schema: {title: "string"})
      Artistry::Registry.register(kind: "person", plugin: "memo", schema: {name: "string"})
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
end
