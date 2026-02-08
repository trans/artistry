require "json"
require "digest/sha256"

module Artistry
  class Artifact
    getter id : Int64
    getter code : String
    getter version : Int32
    getter data : JSON::Any
    getter hash : String
    getter created_at : Int64
    getter new_id : Int64?
    getter updated_at : Int64?

    def initialize(@id, @code, @version, @data, @hash, @created_at,
                   @new_id = nil, @updated_at = nil)
    end

    def self.hash_data(data_json : String) : String
      Digest::SHA256.hexdigest(data_json)
    end

    protected def self.now_ms : Int64
      Time.utc.to_unix_ms
    end

    # Create a new artifact (internal - by registry)
    private def self.create_with_registry(reg : Registry, data, strict : Bool = true) : Artifact
      db = Artistry.conn

      # Convert to JSON for validation and storage
      data_json = data.to_json
      data_parsed = JSON.parse(data_json)

      # Validate against schema
      schema = Registry.get_schema(reg.code, reg.version)
      if schema
        Validator.validate(data_parsed, schema, strict)
      end

      # Create identity
      db.exec("INSERT INTO identity DEFAULT VALUES")
      id = db.scalar("SELECT last_insert_rowid()").as(Int64)

      # Create artifact
      data_hash = hash_data(data_json)
      db.exec(
        "INSERT INTO artifact (id, code, version, data, hash) VALUES (?, ?, ?, ?, ?)",
        id, reg.code, reg.version, data_json, data_hash
      )

      created_at = db.query_one(
        "SELECT created_at FROM identity WHERE id = ?",
        id,
        as: Int64
      )

      Artifact.new(id, reg.code, reg.version, data_parsed, data_hash, created_at)
    end

    # Create via plugin and kind names
    def self.create(plugin : String, kind : String, data, strict : Bool = true) : Artifact
      reg = Registry.find(plugin, kind)
      raise "Unknown artifact: #{plugin}/#{kind}" unless reg
      create_with_registry(reg, data, strict)
    end

    # Create via code or kind name
    def self.create(kind_or_code : String, data, strict : Bool = true) : Artifact
      # First check if it's a code (uppercase)
      reg = Registry.find(kind_or_code.upcase)
      unless reg
        # Try to find by kind name
        reg = Registry.find_by_kind(kind_or_code)
      end
      raise "Unknown artifact kind: #{kind_or_code}" unless reg
      create_with_registry(reg, data, strict)
    end

    # Build artifact from database row
    private def self.from_row(row : Tuple) : Artifact
      Artifact.new(
        row[0].as(Int64),
        row[1].as(String),
        row[2].as(Int32),
        JSON.parse(row[3].as(String)),
        row[4].as(String),
        row[5].as(Int64),
        row[6].as(Int64?),
        row[7].as(Int64?)
      )
    end

    # Find by ID
    def self.find(id : Int64) : Artifact?
      row = Artistry.conn.query_one?(
        "SELECT a.id, a.code, a.version, a.data, a.hash, i.created_at,
                a.new_id, a.updated_at
         FROM artifact a
         JOIN identity i ON a.id = i.id
         WHERE a.id = ?",
        id,
        as: {Int64, String, Int32, String, String, Int64, Int64?, Int64?}
      )
      return nil unless row
      from_row(row)
    end

    # Find by slug (e.g., "E42", "EV123")
    def self.find(slug : String) : Artifact?
      # Split where letters end and digits begin
      match = slug.match(/^([A-Z]+)(\d+)$/i)
      return nil unless match
      code = match[1].upcase
      id = match[2].to_i64?
      return nil unless id
      artifact = find(id)
      return nil unless artifact && artifact.code == code
      artifact
    end

    # Query artifacts by code (current versions only by default)
    def self.where(code : String, include_superseded : Bool = false) : Array(Artifact)
      results = [] of Artifact
      sql = if include_superseded
              "SELECT a.id, a.code, a.version, a.data, a.hash, i.created_at,
                      a.new_id, a.updated_at
               FROM artifact a
               JOIN identity i ON a.id = i.id
               WHERE a.code = ?
               ORDER BY a.id"
            else
              "SELECT a.id, a.code, a.version, a.data, a.hash, i.created_at,
                      a.new_id, a.updated_at
               FROM artifact a
               JOIN identity i ON a.id = i.id
               WHERE a.code = ? AND a.new_id IS NULL
               ORDER BY a.id"
            end

      Artistry.conn.query(sql, code) do |rs|
        rs.each do
          results << Artifact.new(
            rs.read(Int64),
            rs.read(String),
            rs.read(Int32),
            JSON.parse(rs.read(String)),
            rs.read(String),
            rs.read(Int64),
            rs.read(Int64?),
            rs.read(Int64?)
          )
        end
      end
      results
    end

    # Query with JSON field conditions (current versions only by default)
    def self.where(code : String, include_superseded : Bool = false, **conditions) : Array(Artifact)
      return where(code, include_superseded) if conditions.empty?

      where_clauses = ["a.code = ?"]
      where_clauses << "a.new_id IS NULL" unless include_superseded
      params = [code] of DB::Any

      conditions.each do |key, value|
        where_clauses << "json_extract(a.data, '$.#{key}') = ?"
        params << value
      end

      sql = <<-SQL
        SELECT a.id, a.code, a.version, a.data, a.hash, i.created_at,
               a.new_id, a.updated_at
        FROM artifact a
        JOIN identity i ON a.id = i.id
        WHERE #{where_clauses.join(" AND ")}
        ORDER BY a.id
      SQL

      results = [] of Artifact
      Artistry.conn.query(sql, args: params) do |rs|
        rs.each do
          results << Artifact.new(
            rs.read(Int64),
            rs.read(String),
            rs.read(Int32),
            JSON.parse(rs.read(String)),
            rs.read(String),
            rs.read(Int64),
            rs.read(Int64?),
            rs.read(Int64?)
          )
        end
      end
      results
    end

    # Slug representation (e.g., "E1", "EV42")
    def slug : String
      "#{code}#{id}"
    end

    # Is this the current (non-superseded) version?
    def current? : Bool
      new_id.nil?
    end

    # Has this been superseded by a newer version?
    def superseded? : Bool
      !new_id.nil?
    end

    # Get the artifact that superseded this one
    def successor : Artifact?
      sid = new_id
      return nil unless sid
      Artifact.find(sid)
    end

    # Get the latest version in this artifact's chain
    def latest : Artifact
      current = self
      while current.superseded?
        next_version = current.successor
        break unless next_version
        current = next_version
      end
      current
    end

    # Get the full history chain (oldest first)
    def history : Array(Artifact)
      # First, find the root (oldest version)
      root = self
      loop do
        # Find what superseded by this one
        prev = Artistry.conn.query_one?(
          "SELECT id FROM artifact WHERE new_id = ?",
          root.id,
          as: Int64
        )
        break unless prev
        prev_artifact = Artifact.find(prev)
        break unless prev_artifact
        root = prev_artifact
      end

      # Now follow the chain forward
      chain = [root]
      current = root
      while current.superseded?
        next_version = current.successor
        break unless next_version
        chain << next_version
        current = next_version
      end
      chain
    end

    # Access data fields
    def [](key : String) : JSON::Any
      data[key]
    end

    def []?(key : String) : JSON::Any?
      data[key]?
    end

    # COW update - creates new version, supersedes this one
    def update(new_data, strict : Bool = true) : Artifact
      raise "Cannot update superseded artifact (use .latest.update)" if superseded?

      db = Artistry.conn

      # Get current schema version for this code
      current_version = db.query_one?(
        "SELECT version FROM registry WHERE code = ?",
        code,
        as: Int32
      )
      raise "Unknown artifact code: #{code}" unless current_version

      # Merge: parse new_data as JSON, merge with existing
      new_json = JSON.parse(new_data.to_json).as_h
      merged = data.as_h.merge(new_json)
      merged_parsed = JSON.parse(merged.to_json)

      # Validate merged data against current schema
      schema = Registry.get_schema(code, current_version)
      if schema
        Validator.validate(merged_parsed, schema, strict)
      end

      data_json = merged.to_json
      data_hash = Artifact.hash_data(data_json)

      # Create new identity for new version
      db.exec("INSERT INTO identity DEFAULT VALUES")
      new_id = db.scalar("SELECT last_insert_rowid()").as(Int64)

      # Create new artifact
      db.exec(
        "INSERT INTO artifact (id, code, version, data, hash) VALUES (?, ?, ?, ?, ?)",
        new_id, code, current_version, data_json, data_hash
      )

      # Mark this artifact as superseded
      db.exec(
        "UPDATE artifact SET new_id = ? WHERE id = ?",
        new_id, id
      )

      new_created_at = db.query_one(
        "SELECT created_at FROM identity WHERE id = ?",
        new_id,
        as: Int64
      )

      Artifact.new(new_id, code, current_version, merged_parsed, data_hash, new_created_at)
    end

    # Mutable update - modifies in place, sets updated_at
    def update!(new_data, strict : Bool = true) : Artifact
      db = Artistry.conn

      # Get current schema version for this code
      current_version = db.query_one?(
        "SELECT version FROM registry WHERE code = ?",
        code,
        as: Int32
      )
      raise "Unknown artifact code: #{code}" unless current_version

      # Merge: parse new_data as JSON, merge with existing
      new_json = JSON.parse(new_data.to_json).as_h
      merged = data.as_h.merge(new_json)
      merged_parsed = JSON.parse(merged.to_json)

      # Validate merged data against current schema
      schema = Registry.get_schema(code, current_version)
      if schema
        Validator.validate(merged_parsed, schema, strict)
      end

      data_json = merged.to_json
      data_hash = Artifact.hash_data(data_json)
      now = Artifact.now_ms

      db.exec(
        "UPDATE artifact SET data = ?, version = ?, hash = ?, updated_at = ? WHERE id = ?",
        data_json, current_version, data_hash, now, id
      )

      Artifact.new(id, code, current_version, merged_parsed, data_hash, created_at,
                   new_id, now)
    end

    # Delete artifact (hard delete)
    def delete : Nil
      db = Artistry.conn
      db.exec("DELETE FROM artifact WHERE id = ?", id)
      db.exec("DELETE FROM identity WHERE id = ?", id)
    end
  end
end
