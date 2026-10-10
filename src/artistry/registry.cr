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

    CODE_FORMAT = /\A[A-Z]{1,2}\z/

    # Register a new artifact kind. Returns the assigned code.
    # Schema can be any JSON-serializable value.
    # Index is a list of field names to create expression indexes on.
    #
    # `code` declares the kind's code (one or two uppercase letters) so it
    # doesn't depend on registration order. Without it, a code is allocated
    # from the kind name. Raises `InvalidCode`, `CodeConflict` (another kind
    # owns the code) or `CodeMismatch` (this kind is already registered
    # under a different code).
    def self.register(
      kind : String,
      plugin : String,
      schema,
      description : String? = nil,
      symbol : String? = nil,
      index : Array(String) = [] of String,
      code : String? = nil
    ) : String
      db = Artistry.conn
      kind = kind.downcase
      plugin = plugin.downcase
      declared = code
      raise InvalidCode.new(declared) if declared && !CODE_FORMAT.matches?(declared)

      # Check if already registered
      existing = db.query_one?(
        "SELECT code, version FROM registry WHERE plugin = ? AND kind = ?",
        plugin, kind,
        as: {String, Int32}
      )

      if existing
        code, current_version = existing
        if declared && declared != code
          raise CodeMismatch.new(plugin, kind, code, declared)
        end

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

      # New registration - use the declared code, or allocate one
      code = if declared
               if owner = db.query_one?("SELECT plugin, kind FROM registry WHERE code = ?", declared, as: {String, String})
                 raise CodeConflict.new(declared, plugin, kind, owner[0], owner[1])
               end
               declared
             else
               allocate_code(db, kind)
             end

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
    private def self.create_indexes(db, plugin : String, kind : String, code : String, fields : Array(String)) : Nil
      fields.each do |field|
        index_name = "idx_#{plugin}_#{kind}_#{field}"
        # CREATE INDEX IF NOT EXISTS is idempotent
        db.exec(
          "CREATE INDEX IF NOT EXISTS #{index_name} ON artifact(json_extract(data, '$.#{field}')) WHERE code = '#{code}'"
        )
      end
    end

    # Allocate a free one- or two-letter code for a kind name.
    #
    # Tries the first letter, then the first letter followed by each later
    # letter of the name, then the first letter followed by A-Z. Codes are
    # capped at two letters because slugs ("C42", "42C") are parsed that way.
    def self.allocate_code(db, kind : String) : String
      letters = kind.upcase.gsub(/[^A-Z]/, "")
      raise Error.new("Cannot allocate a code for kind #{kind.inspect}: it has no letters") if letters.empty?

      first = letters[0]
      candidates = [first.to_s]
      letters[1..].each_char { |c| candidates << "#{first}#{c}" }
      ('A'..'Z').each { |c| candidates << "#{first}#{c}" }

      candidates.uniq.each do |candidate|
        exists = db.query_one?(
          "SELECT 1 FROM registry WHERE code = ?",
          candidate,
          as: Int32
        )
        return candidate unless exists
      end

      raise Error.new("No free code for kind #{kind.inspect}: all codes starting with #{first} are taken (declare one with code:)")
    end

    def self.normalize_schema(schema) : String
      schema.to_json
    end

    def self.hash_schema(json : String) : String
      Digest::SHA256.hexdigest(json)
    end

    # Lookup a registration by code
    def self.find(code : String) : Registry?
      row = Artistry.conn.query_one?(
        "SELECT code, kind, plugin, description, symbol, version FROM registry WHERE code = ?",
        code,
        as: {String, String, String, String?, String?, Int32}
      )
      return nil unless row
      Registry.new(*row)
    end

    # Lookup a registration by plugin and kind
    def self.find(plugin : String, kind : String) : Registry?
      row = Artistry.conn.query_one?(
        "SELECT code, kind, plugin, description, symbol, version FROM registry WHERE plugin = ? AND kind = ?",
        plugin.downcase, kind.downcase,
        as: {String, String, String, String?, String?, Int32}
      )
      return nil unless row
      Registry.new(*row)
    end

    # Lookup a registration by kind name only (returns first match if multiple plugins use same kind)
    def self.find_by_kind(kind : String) : Registry?
      row = Artistry.conn.query_one?(
        "SELECT code, kind, plugin, description, symbol, version FROM registry WHERE kind = ? LIMIT 1",
        kind.downcase,
        as: {String, String, String, String?, String?, Int32}
      )
      return nil unless row
      Registry.new(*row)
    end

    # Get the schema JSON for a code and version
    def self.get_schema(code : String, version : Int32) : JSON::Any?
      json = Artistry.conn.query_one?(
        "SELECT json FROM schema WHERE code = ? AND version = ?",
        code, version,
        as: String
      )
      json ? JSON.parse(json) : nil
    end

    # List all registrations
    def self.all : Array(Registry)
      results = [] of Registry
      Artistry.conn.query(
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
