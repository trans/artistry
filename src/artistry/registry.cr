require "digest/sha256"
require "json"
require "jargon"

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

    # A field an index can name: letters, digits, `_` and `-`, starting with
    # a letter or `_`, with `.` between the names of nested fields
    # (`meta.author`).
    FIELD_FORMAT = /\A[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)*\z/

    # An index on a kind's fields, in order, over its current versions, and
    # the plugins that asked for it.
    record Index, code : String, fields : Array(String), plugins : Array(String) do
      # The SQLite index's name, as query plans show it.
      def name : String
        Registry.index_name(code, fields)
      end
    end

    # Register a new artifact kind. Returns the assigned code.
    # Schema is a JSON Schema as any JSON-serializable value. Raises
    # `InvalidSchema` if it can't be parsed, so it fails here rather than
    # on every create.
    # `index` lists the indexes this plugin asks for on the kind, as
    # `add_index` does: each entry a field or an ordered list of fields
    # (`["title", ["voice", "bit"]]`). Leaving one out later doesn't drop it;
    # `drop_index` does.
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
      index : Array = [] of String,
      code : String? = nil
    ) : String
      db = Artistry.conn
      kind = kind.downcase
      plugin = plugin.downcase
      declared = code
      raise InvalidCode.new(declared) if declared && !CODE_FORMAT.matches?(declared)
      check_schema(plugin, kind, schema)

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

        index.each { |fields| add_index(code, fields, plugin: plugin) }

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

      index.each { |fields| add_index(code, fields, plugin: plugin) }

      code
    end

    # Parse the schema as validation will, raising `InvalidSchema` on failure.
    private def self.check_schema(plugin : String, kind : String, schema) : Nil
      Jargon::Schema.from_json_any(JSON.parse(normalize_schema(schema)))
    rescue ex
      raise InvalidSchema.new(plugin, kind, ex.message)
    end

    # Ask for an index on a kind's `fields`, in order, for `plugin`'s common
    # lookups: `Artifact.where` fixing the leading fields (or all of them)
    # then reads one range of the index instead of every artifact of the
    # kind. Any plugin may ask, for any kind, given by code or name.
    #
    # Indexes are shared: asking for fields already indexed records `plugin`
    # as wanting the index too, and it stays until every plugin that asked
    # has dropped it (`drop_index`). They cover current versions only, so
    # `where(..., include_superseded: true)` doesn't use them. Raises
    # `InvalidIndex`.
    def self.add_index(kind : String, fields : Array(String), *, plugin : String) : Index
      reg = resolve(kind)
      check_fields(fields)
      db = Artistry.conn
      create_index(db, reg.code, fields)
      db.exec("INSERT OR IGNORE INTO kind_index (code, fields, plugin) VALUES (?, ?, ?)",
        reg.code, fields.to_json, plugin.downcase)
      Index.new(reg.code, fields, claims(db, reg.code, fields))
    end

    # :ditto:
    def self.add_index(kind : String, field : String, *, plugin : String) : Index
      add_index(kind, [field], plugin: plugin)
    end

    # Withdraw `plugin`'s claim on the index over `fields`, and drop the
    # index once no plugin claims it. Returns whether `plugin` had claimed it.
    def self.drop_index(kind : String, fields : Array(String), *, plugin : String) : Bool
      reg = resolve(kind)
      db = Artistry.conn
      claimed = db.exec("DELETE FROM kind_index WHERE code = ? AND fields = ? AND plugin = ?",
        reg.code, fields.to_json, plugin.downcase).rows_affected > 0
      db.exec("DROP INDEX IF EXISTS #{index_name(reg.code, fields)}") if claims(db, reg.code, fields).empty?
      claimed
    end

    # :ditto:
    def self.drop_index(kind : String, field : String, *, plugin : String) : Bool
      drop_index(kind, [field], plugin: plugin)
    end

    # A kind's indexes, each with the plugins that asked for it.
    def self.indexes(kind : String) : Array(Index)
      code = resolve(kind).code
      rows = Artistry.conn.query_all("SELECT fields, plugin FROM kind_index WHERE code = ? ORDER BY fields, plugin",
        code, as: {String, String})
      rows.group_by(&.[0]).map { |fields, claims| Index.new(code, Array(String).from_json(fields), claims.map(&.[1])) }
    end

    # :nodoc:
    # The SQLite index over a kind's fields: readable in query plans, and
    # suffixed with a hash of the field list, so that lists differing only
    # in punctuation (`a.b`, `a_b`) don't share a name.
    def self.index_name(code : String, fields : Array(String)) : String
      "ix_#{code}_#{fields.join("_").gsub(/[^A-Za-z0-9_]/, "_")}_#{Digest::SHA256.hexdigest(fields.to_json)[0, 8]}"
    end

    # :nodoc:
    # Before 0.13, `register(index:)` made one index per field, over every
    # version, named `idx_<plugin>_<kind>_<field>`. Each becomes a claim by
    # its kind's plugin on that field, over current versions only. One on a
    # field `add_index` wouldn't take is left as it is.
    def self.migrate_legacy_indexes(db) : Nil
      legacy = db.query_all(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'artifact' " \
        "AND name LIKE 'idx%' AND sql LIKE '%json_extract(data, ''$.%'')) WHERE code = ''%'''",
        as: {String, String})
      legacy.each do |name, sql|
        next unless match = sql.match(/json_extract\(data, '\$\.([^']+)'\)\) WHERE code = '([A-Z]{1,2})'\z/)
        field, code = match[1], match[2]
        next unless FIELD_FORMAT.matches?(field)
        if plugin = db.query_one?("SELECT plugin FROM registry WHERE code = ?", code, as: String)
          create_index(db, code, [field])
          db.exec("INSERT OR IGNORE INTO kind_index (code, fields, plugin) VALUES (?, ?, ?)", code, [field].to_json, plugin)
        end
        db.exec("DROP INDEX #{name}")
      end
    end

    # The index over current versions only: a query reaches it by giving the
    # kind's code and `new_id IS NULL`, as `Artifact.where` does.
    private def self.create_index(db, code : String, fields : Array(String)) : Nil
      columns = fields.map { |field| "json_extract(data, '$.#{field}')" }.join(", ")
      db.exec("CREATE INDEX IF NOT EXISTS #{index_name(code, fields)} ON artifact(#{columns}) " \
              "WHERE code = '#{code}' AND new_id IS NULL")
    end

    private def self.check_fields(fields : Array(String)) : Nil
      raise InvalidIndex.new(fields, "it names no fields") if fields.empty?
      raise InvalidIndex.new(fields, "it names a field twice") unless fields.uniq.size == fields.size
      if bad = fields.find { |field| !FIELD_FORMAT.matches?(field) }
        raise InvalidIndex.new(fields, "#{bad.inspect} isn't a field name: letters, digits, _ and -, with . between nested names")
      end
    end

    private def self.claims(db, code : String, fields : Array(String)) : Array(String)
      db.query_all("SELECT plugin FROM kind_index WHERE code = ? AND fields = ? ORDER BY plugin", code, fields.to_json, as: String)
    end

    # A kind by code or name, as `Artifact.create` takes it.
    private def self.resolve(kind : String) : Registry
      find(kind.upcase) || find_by_kind(kind) || raise Error.new("Unknown artifact kind: #{kind}")
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
