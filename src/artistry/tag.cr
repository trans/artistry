module Artistry
  class Tag
    getter id : Int64
    getter name : String
    getter created_at : Int64

    def initialize(@id, @name, @created_at)
    end

    # Find or create a tag by name.
    def self.create(name : String) : Tag
      db = Artistry.conn
      db.exec("INSERT OR IGNORE INTO tag (name) VALUES (?)", name)
      find(name).not_nil!
    end

    # Find tag by ID.
    def self.find(id : Int64) : Tag?
      row = Artistry.conn.query_one?(
        "SELECT id, name, created_at FROM tag WHERE id = ?",
        id,
        as: {Int64, String, Int64}
      )
      return nil unless row
      Tag.new(row[0], row[1], row[2])
    end

    # Find tag by name.
    def self.find(name : String) : Tag?
      row = Artistry.conn.query_one?(
        "SELECT id, name, created_at FROM tag WHERE name = ?",
        name,
        as: {Int64, String, Int64}
      )
      return nil unless row
      Tag.new(row[0], row[1], row[2])
    end

    # Get all tags, ordered by name.
    def self.all : Array(Tag)
      results = [] of Tag
      Artistry.conn.query("SELECT id, name, created_at FROM tag ORDER BY name") do |rs|
        rs.each do
          results << Tag.new(rs.read(Int64), rs.read(String), rs.read(Int64))
        end
      end
      results
    end

    # Delete this tag (CASCADE removes all taggings).
    def delete : Nil
      Artistry.conn.exec("DELETE FROM tag WHERE id = ?", id)
    end

    # Tag an artifact. Creates the tag if it doesn't exist.
    def self.tag(artifact : Artifact | Int64, name : String) : Nil
      tag = create(name)
      artifact_id = artifact.is_a?(Artifact) ? artifact.id : artifact
      Artistry.conn.exec(
        "INSERT OR IGNORE INTO tagging (tag_id, artifact_id) VALUES (?, ?)",
        tag.id, artifact_id
      )
    end

    # Remove a tag from an artifact.
    def self.untag(artifact : Artifact | Int64, name : String) : Nil
      tag = find(name)
      return unless tag
      artifact_id = artifact.is_a?(Artifact) ? artifact.id : artifact
      Artistry.conn.exec(
        "DELETE FROM tagging WHERE tag_id = ? AND artifact_id = ?",
        tag.id, artifact_id
      )
    end

    # Replace all tags on an artifact with the given set.
    def self.sync(artifact : Artifact | Int64, names : Array(String)) : Nil
      artifact_id = artifact.is_a?(Artifact) ? artifact.id : artifact
      Artistry.conn.exec("DELETE FROM tagging WHERE artifact_id = ?", artifact_id)
      names.each do |name|
        tag(artifact_id, name)
      end
    end

    # Get all tags for an artifact.
    def self.for(artifact : Artifact | Int64) : Array(Tag)
      artifact_id = artifact.is_a?(Artifact) ? artifact.id : artifact
      results = [] of Tag
      Artistry.conn.query(
        "SELECT t.id, t.name, t.created_at FROM tag t
         JOIN tagging tg ON t.id = tg.tag_id
         WHERE tg.artifact_id = ?
         ORDER BY t.name",
        artifact_id
      ) do |rs|
        rs.each do
          results << Tag.new(rs.read(Int64), rs.read(String), rs.read(Int64))
        end
      end
      results
    end

    # Get all current artifacts with a given tag.
    def self.artifacts(name : String) : Array(Artifact)
      tag = find(name)
      return [] of Artifact unless tag
      artifacts(tag)
    end

    # Get all current artifacts with a given tag.
    def self.artifacts(tag : Tag) : Array(Artifact)
      results = [] of Artifact
      Artistry.conn.query(
        "SELECT a.id, a.code, a.version, a.data, a.hash, i.created_at,
                a.new_id, a.updated_at
         FROM artifact a
         JOIN identity i ON a.id = i.id
         JOIN tagging tg ON a.id = tg.artifact_id
         WHERE tg.tag_id = ? AND a.new_id IS NULL
         ORDER BY a.id",
        tag.id
      ) do |rs|
        rs.each do
          results << Artifact.new(
            rs.read(Int64), rs.read(String), rs.read(Int32),
            JSON.parse(rs.read(String)), rs.read(String), rs.read(Int64),
            rs.read(Int64?), rs.read(Int64?)
          )
        end
      end
      results
    end

    # Get all current artifacts with ANY of the given tags.
    def self.artifacts_any(names : Array(String)) : Array(Artifact)
      return [] of Artifact if names.empty?
      placeholders = names.map { "?" }.join(", ")
      results = [] of Artifact
      Artistry.conn.query(
        "SELECT DISTINCT a.id, a.code, a.version, a.data, a.hash, i.created_at,
                a.new_id, a.updated_at
         FROM artifact a
         JOIN identity i ON a.id = i.id
         JOIN tagging tg ON a.id = tg.artifact_id
         JOIN tag t ON tg.tag_id = t.id
         WHERE t.name IN (#{placeholders}) AND a.new_id IS NULL
         ORDER BY a.id",
        args: names.map(&.as(DB::Any))
      ) do |rs|
        rs.each do
          results << Artifact.new(
            rs.read(Int64), rs.read(String), rs.read(Int32),
            JSON.parse(rs.read(String)), rs.read(String), rs.read(Int64),
            rs.read(Int64?), rs.read(Int64?)
          )
        end
      end
      results
    end

    # Get all current artifacts with ALL of the given tags.
    def self.artifacts_all(names : Array(String)) : Array(Artifact)
      return [] of Artifact if names.empty?
      placeholders = names.map { "?" }.join(", ")
      results = [] of Artifact
      Artistry.conn.query(
        "SELECT a.id, a.code, a.version, a.data, a.hash, i.created_at,
                a.new_id, a.updated_at
         FROM artifact a
         JOIN identity i ON a.id = i.id
         JOIN tagging tg ON a.id = tg.artifact_id
         JOIN tag t ON tg.tag_id = t.id
         WHERE t.name IN (#{placeholders}) AND a.new_id IS NULL
         GROUP BY a.id
         HAVING COUNT(DISTINCT t.id) = ?
         ORDER BY a.id",
        args: names.map(&.as(DB::Any)) + [names.size.to_i64.as(DB::Any)]
      ) do |rs|
        rs.each do
          results << Artifact.new(
            rs.read(Int64), rs.read(String), rs.read(Int32),
            JSON.parse(rs.read(String)), rs.read(String), rs.read(Int64),
            rs.read(Int64?), rs.read(Int64?)
          )
        end
      end
      results
    end
  end
end
