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

        # Reload v1 to see superseded_by
        v1_reloaded = Artistry::Artifact.find(v1.id).not_nil!
        v1_reloaded.superseded?.should be_true
        v1_reloaded.superseded_by.should eq(v2.id)
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
      link.kind.should eq("organizer")
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
end
