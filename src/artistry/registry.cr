require "digest/sha256"
require "json"

module Artistry
  class Registry
    getter code : String
    getter kind : String
    getter plugin : String
    getter description : String?
    getter symbol : String?
    getter version : Int32

    def initialize(@code, @kind, @plugin, @description, @symbol, @version)
    end

    # Register a new artifact kind. Returns the assigned code.
    # Schema can be any JSON-serializable value.
    # Index is a list of field names to create expression indexes on.
    def self.register(
      kind : String,
      plugin : String,
      schema,
      description : String? = nil,
      symbol : String? = nil,
      index : Array(String) = [] of String
    ) : String
      db = Artistry.db
      kind = kind.downcase
      plugin = plugin.downcase

      # Check if already registered
      existing = db.query_one?(
        "SELECT code, version FROM registry WHERE plugin = ? AND kind = ?",
        plugin, kind,
        as: {String, Int32}
      )

      if existing
        code, current_version = existing
        # Check if schema changed
        schema_json = normalize_schema(schema)
        schema_hash = hash_schema(schema_json)

        last_hash = db.query_one?(
          "SELECT hash FROM schema WHERE code = ? AND version = ?",
          code, current_version,
          as: String
        )

        if last_hash != schema_hash
          # Schema changed, create new version
          new_version = current_version + 1
          db.exec(
            "UPDATE registry SET version = ? WHERE code = ?",
            new_version, code
          )
          db.exec(
            "INSERT INTO schema (code, version, json, hash) VALUES (?, ?, ?, ?)",
            code, new_version, schema_json, schema_hash
          )
        end

        # Ensure indexes exist (idempotent)
        create_indexes(db, plugin, kind, code, index)

        return code
      end

      # New registration - find available code
      code = allocate_code(db, kind)

      db.exec(
        "INSERT INTO registry (code, kind, plugin, description, symbol, version) VALUES (?, ?, ?, ?, ?, 1)",
        code, kind, plugin, description, symbol
      )

      schema_json = normalize_schema(schema)
      schema_hash = hash_schema(schema_json)

      db.exec(
        "INSERT INTO schema (code, version, json, hash) VALUES (?, 1, ?, ?)",
        code, schema_json, schema_hash
      )

      # Create indexes
      create_indexes(db, plugin, kind, code, index)

      code
    end

    # Create expression indexes on JSON fields for a kind
    private def self.create_indexes(db : DB::Database, plugin : String, kind : String, code : String, fields : Array(String)) : Nil
      fields.each do |field|
        index_name = "idx_#{plugin}_#{kind}_#{field}"
        # CREATE INDEX IF NOT EXISTS is idempotent
        db.exec(
          "CREATE INDEX IF NOT EXISTS #{index_name} ON artifact(json_extract(data, '$.#{field}')) WHERE code = '#{code}'"
        )
      end
    end

    # Find the shortest unique prefix for a kind name
    def self.allocate_code(db : DB::Database, kind : String) : String
      kind_upper = kind.upcase

      (1..kind_upper.size).each do |len|
        candidate = kind_upper[0, len]
        exists = db.query_one?(
          "SELECT 1 FROM registry WHERE code = ?",
          candidate,
          as: Int32
        )
        return candidate unless exists
      end

      # Fallback: append number if full name is taken
      suffix = 1
      loop do
        candidate = "#{kind_upper}#{suffix}"
        exists = db.query_one?(
          "SELECT 1 FROM registry WHERE code = ?",
          candidate,
          as: Int32
        )
        return candidate unless exists
        suffix += 1
      end
    end

    def self.normalize_schema(schema) : String
      schema.to_json
    end

    def self.hash_schema(json : String) : String
      Digest::SHA256.hexdigest(json)
    end

    # Lookup a registration by code
    def self.find(code : String) : Registry?
      row = Artistry.db.query_one?(
        "SELECT code, kind, plugin, description, symbol, version FROM registry WHERE code = ?",
        code,
        as: {String, String, String, String?, String?, Int32}
      )
      return nil unless row
      Registry.new(*row)
    end

    # Lookup a registration by plugin and kind
    def self.find(plugin : String, kind : String) : Registry?
      row = Artistry.db.query_one?(
        "SELECT code, kind, plugin, description, symbol, version FROM registry WHERE plugin = ? AND kind = ?",
        plugin.downcase, kind.downcase,
        as: {String, String, String, String?, String?, Int32}
      )
      return nil unless row
      Registry.new(*row)
    end

    # Lookup a registration by kind name only (returns first match if multiple plugins use same kind)
    def self.find_by_kind(kind : String) : Registry?
      row = Artistry.db.query_one?(
        "SELECT code, kind, plugin, description, symbol, version FROM registry WHERE kind = ? LIMIT 1",
        kind.downcase,
        as: {String, String, String, String?, String?, Int32}
      )
      return nil unless row
      Registry.new(*row)
    end

    # List all registrations
    def self.all : Array(Registry)
      results = [] of Registry
      Artistry.db.query(
        "SELECT code, kind, plugin, description, symbol, version FROM registry ORDER BY code"
      ) do |rs|
        rs.each do
          results << Registry.new(
            rs.read(String),
            rs.read(String),
            rs.read(String),
            rs.read(String?),
            rs.read(String?),
            rs.read(Int32)
          )
        end
      end
      results
    end
  end
end
