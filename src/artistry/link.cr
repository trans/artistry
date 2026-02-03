require "json"

module Artistry
  class Link
    getter from_id : Int64
    getter to_id : Int64
    getter rel : String
    getter data : JSON::Any?
    getter created_at : String

    def initialize(@from_id, @to_id, @rel, @data, @created_at)
    end

    # Create a link between two artifacts
    def self.create(from : Artifact | Int64, to : Artifact | Int64, rel : String, data = nil) : Link
      from_id = from.is_a?(Artifact) ? from.id : from
      to_id = to.is_a?(Artifact) ? to.id : to

      data_json = data ? data.to_json : nil

      Artistry.db.exec(
        "INSERT INTO link (from_id, to_id, rel, data) VALUES (?, ?, ?, ?)",
        from_id, to_id, rel, data_json
      )

      created_at = Artistry.db.query_one(
        "SELECT created_at FROM link WHERE from_id = ? AND to_id = ? AND rel = ?",
        from_id, to_id, rel,
        as: String
      )

      Link.new(from_id, to_id, rel, data_json ? JSON.parse(data_json) : nil, created_at)
    end

    # Create from slug strings
    def self.create(from_slug : String, to_slug : String, rel : String, data = nil) : Link
      from = Artifact.find(from_slug)
      to = Artifact.find(to_slug)
      raise "Invalid from slug: #{from_slug}" unless from
      raise "Invalid to slug: #{to_slug}" unless to
      create(from, to, rel, data)
    end

    # Find a specific link
    def self.find(from_id : Int64, to_id : Int64, rel : String) : Link?
      row = Artistry.db.query_one?(
        "SELECT from_id, to_id, rel, data, created_at FROM link
         WHERE from_id = ? AND to_id = ? AND rel = ?",
        from_id, to_id, rel,
        as: {Int64, Int64, String, String?, String}
      )
      return nil unless row
      data_str = row[3]
      Link.new(row[0], row[1], row[2], data_str ? JSON.parse(data_str) : nil, row[4])
    end

    # Get all outgoing links from an artifact
    def self.from(artifact : Artifact | Int64, rel : String? = nil) : Array(Link)
      id = artifact.is_a?(Artifact) ? artifact.id : artifact
      results = [] of Link

      sql = if rel
              "SELECT from_id, to_id, rel, data, created_at FROM link
               WHERE from_id = ? AND rel = ? ORDER BY created_at"
            else
              "SELECT from_id, to_id, rel, data, created_at FROM link
               WHERE from_id = ? ORDER BY rel, created_at"
            end

      args = rel ? [id, rel] : [id]

      Artistry.db.query(sql, args: args.map(&.as(DB::Any))) do |rs|
        rs.each do
          from = rs.read(Int64)
          to = rs.read(Int64)
          r = rs.read(String)
          data_str = rs.read(String?)
          created = rs.read(String)
          results << Link.new(from, to, r, data_str ? JSON.parse(data_str) : nil, created)
        end
      end
      results
    end

    # Get all incoming links to an artifact
    def self.to(artifact : Artifact | Int64, rel : String? = nil) : Array(Link)
      id = artifact.is_a?(Artifact) ? artifact.id : artifact
      results = [] of Link

      sql = if rel
              "SELECT from_id, to_id, rel, data, created_at FROM link
               WHERE to_id = ? AND rel = ? ORDER BY created_at"
            else
              "SELECT from_id, to_id, rel, data, created_at FROM link
               WHERE to_id = ? ORDER BY rel, created_at"
            end

      args = rel ? [id, rel] : [id]

      Artistry.db.query(sql, args: args.map(&.as(DB::Any))) do |rs|
        rs.each do
          from = rs.read(Int64)
          to = rs.read(Int64)
          r = rs.read(String)
          data_str = rs.read(String?)
          created = rs.read(String)
          results << Link.new(from, to, r, data_str ? JSON.parse(data_str) : nil, created)
        end
      end
      results
    end

    # Get the source artifact
    def from : Artifact?
      Artifact.find(from_id)
    end

    # Get the target artifact
    def to : Artifact?
      Artifact.find(to_id)
    end

    # Delete this link
    def delete : Nil
      Artistry.db.exec(
        "DELETE FROM link WHERE from_id = ? AND to_id = ? AND rel = ?",
        from_id, to_id, rel
      )
    end

    # Delete all links of a rel from an artifact
    def self.delete_from(artifact : Artifact | Int64, rel : String) : Nil
      id = artifact.is_a?(Artifact) ? artifact.id : artifact
      Artistry.db.exec(
        "DELETE FROM link WHERE from_id = ? AND rel = ?",
        id, rel
      )
    end

    # Delete all links of a rel to an artifact
    def self.delete_to(artifact : Artifact | Int64, rel : String) : Nil
      id = artifact.is_a?(Artifact) ? artifact.id : artifact
      Artistry.db.exec(
        "DELETE FROM link WHERE to_id = ? AND rel = ?",
        id, rel
      )
    end
  end
end
