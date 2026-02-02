require "json"

module Artistry
  class Link
    getter from_id : Int64
    getter to_id : Int64
    getter kind : String
    getter data : JSON::Any?
    getter created_at : String

    def initialize(@from_id, @to_id, @kind, @data, @created_at)
    end

    # Create a link between two artifacts
    def self.create(from : Artifact | Int64, to : Artifact | Int64, kind : String, data = nil) : Link
      from_id = from.is_a?(Artifact) ? from.id : from
      to_id = to.is_a?(Artifact) ? to.id : to

      data_json = data ? data.to_json : nil

      Artistry.db.exec(
        "INSERT INTO link (from_id, to_id, kind, data) VALUES (?, ?, ?, ?)",
        from_id, to_id, kind, data_json
      )

      created_at = Artistry.db.query_one(
        "SELECT created_at FROM link WHERE from_id = ? AND to_id = ? AND kind = ?",
        from_id, to_id, kind,
        as: String
      )

      Link.new(from_id, to_id, kind, data_json ? JSON.parse(data_json) : nil, created_at)
    end

    # Create from slug strings
    def self.create(from_slug : String, to_slug : String, kind : String, data = nil) : Link
      from = Artifact.find(from_slug)
      to = Artifact.find(to_slug)
      raise "Invalid from slug: #{from_slug}" unless from
      raise "Invalid to slug: #{to_slug}" unless to
      create(from, to, kind, data)
    end

    # Find a specific link
    def self.find(from_id : Int64, to_id : Int64, kind : String) : Link?
      row = Artistry.db.query_one?(
        "SELECT from_id, to_id, kind, data, created_at FROM link
         WHERE from_id = ? AND to_id = ? AND kind = ?",
        from_id, to_id, kind,
        as: {Int64, Int64, String, String?, String}
      )
      return nil unless row
      data_str = row[3]
      Link.new(row[0], row[1], row[2], data_str ? JSON.parse(data_str) : nil, row[4])
    end

    # Get all outgoing links from an artifact
    def self.from(artifact : Artifact | Int64, kind : String? = nil) : Array(Link)
      id = artifact.is_a?(Artifact) ? artifact.id : artifact
      results = [] of Link

      sql = if kind
              "SELECT from_id, to_id, kind, data, created_at FROM link
               WHERE from_id = ? AND kind = ? ORDER BY created_at"
            else
              "SELECT from_id, to_id, kind, data, created_at FROM link
               WHERE from_id = ? ORDER BY kind, created_at"
            end

      args = kind ? [id, kind] : [id]

      Artistry.db.query(sql, args: args.map(&.as(DB::Any))) do |rs|
        rs.each do
          from = rs.read(Int64)
          to = rs.read(Int64)
          k = rs.read(String)
          data_str = rs.read(String?)
          created = rs.read(String)
          results << Link.new(from, to, k, data_str ? JSON.parse(data_str) : nil, created)
        end
      end
      results
    end

    # Get all incoming links to an artifact
    def self.to(artifact : Artifact | Int64, kind : String? = nil) : Array(Link)
      id = artifact.is_a?(Artifact) ? artifact.id : artifact
      results = [] of Link

      sql = if kind
              "SELECT from_id, to_id, kind, data, created_at FROM link
               WHERE to_id = ? AND kind = ? ORDER BY created_at"
            else
              "SELECT from_id, to_id, kind, data, created_at FROM link
               WHERE to_id = ? ORDER BY kind, created_at"
            end

      args = kind ? [id, kind] : [id]

      Artistry.db.query(sql, args: args.map(&.as(DB::Any))) do |rs|
        rs.each do
          from = rs.read(Int64)
          to = rs.read(Int64)
          k = rs.read(String)
          data_str = rs.read(String?)
          created = rs.read(String)
          results << Link.new(from, to, k, data_str ? JSON.parse(data_str) : nil, created)
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
        "DELETE FROM link WHERE from_id = ? AND to_id = ? AND kind = ?",
        from_id, to_id, kind
      )
    end

    # Delete all links of a kind from an artifact
    def self.delete_from(artifact : Artifact | Int64, kind : String) : Nil
      id = artifact.is_a?(Artifact) ? artifact.id : artifact
      Artistry.db.exec(
        "DELETE FROM link WHERE from_id = ? AND kind = ?",
        id, kind
      )
    end

    # Delete all links of a kind to an artifact
    def self.delete_to(artifact : Artifact | Int64, kind : String) : Nil
      id = artifact.is_a?(Artifact) ? artifact.id : artifact
      Artistry.db.exec(
        "DELETE FROM link WHERE to_id = ? AND kind = ?",
        id, kind
      )
    end
  end
end
