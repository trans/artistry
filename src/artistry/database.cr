module Artistry
  module Database
    SCHEMA = <<-SQL
      CREATE TABLE IF NOT EXISTS identity (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT,
        kind_seq INTEGER,
        created_at INTEGER NOT NULL DEFAULT (cast((julianday('now') - 2440587.5) * 86400000 as integer))
      );

      CREATE TABLE IF NOT EXISTS kind_counter (
        code TEXT PRIMARY KEY,
        next_seq INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS registry (
        code TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        plugin TEXT NOT NULL,
        description TEXT,
        symbol TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        UNIQUE(plugin, kind)
      );

      CREATE TABLE IF NOT EXISTS schema (
        code TEXT NOT NULL,
        version INTEGER NOT NULL,
        json TEXT NOT NULL,
        hash TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (cast((julianday('now') - 2440587.5) * 86400000 as integer)),
        PRIMARY KEY (code, version),
        FOREIGN KEY (code) REFERENCES registry(code)
      );

      CREATE TABLE IF NOT EXISTS artifact (
        id INTEGER PRIMARY KEY,
        code TEXT NOT NULL,
        version INTEGER NOT NULL,
        data JSON NOT NULL,
        hash TEXT NOT NULL,
        new_id INTEGER REFERENCES identity(id),
        updated_at INTEGER,
        FOREIGN KEY (id) REFERENCES identity(id),
        FOREIGN KEY (code, version) REFERENCES schema(code, version)
      );

      CREATE INDEX IF NOT EXISTS idx_artifact_code ON artifact(code);
      CREATE INDEX IF NOT EXISTS idx_artifact_new_id ON artifact(new_id) WHERE new_id IS NOT NULL;

      CREATE TABLE IF NOT EXISTS kind_index (
        code TEXT NOT NULL REFERENCES registry(code),
        fields TEXT NOT NULL,
        plugin TEXT NOT NULL,
        PRIMARY KEY (code, fields, plugin)
      ) WITHOUT ROWID;

      CREATE TABLE IF NOT EXISTS link (
        from_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
        to_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
        rel TEXT NOT NULL,
        data JSON,
        created_at INTEGER NOT NULL DEFAULT (cast((julianday('now') - 2440587.5) * 86400000 as integer)),
        PRIMARY KEY (from_id, to_id, rel)
      );

      CREATE TABLE IF NOT EXISTS tag (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL DEFAULT (cast((julianday('now') - 2440587.5) * 86400000 as integer))
      );

      CREATE TABLE IF NOT EXISTS tagging (
        tag_id INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
        artifact_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
        created_at INTEGER NOT NULL DEFAULT (cast((julianday('now') - 2440587.5) * 86400000 as integer)),
        PRIMARY KEY (tag_id, artifact_id)
      );

      CREATE INDEX IF NOT EXISTS idx_tagging_artifact_id ON tagging(artifact_id);
    SQL

    def self.ensure_schema(db : DB::Database) : Nil
      SCHEMA.split(";").each do |stmt|
        stmt = stmt.strip
        next if stmt.empty?
        db.exec(stmt)
      end

      # Add columns to identity tables created before kind_seq existed.
      # Checked rather than rescued: a failed ALTER leaves a cached
      # statement in an error state that raises when the DB is closed.
      existing = db.query_all("SELECT name FROM pragma_table_info('identity')", as: String)
      {"code" => "TEXT", "kind_seq" => "INTEGER"}.each do |column, type|
        db.exec("ALTER TABLE identity ADD COLUMN #{column} #{type}") unless existing.includes?(column)
      end

      # Created after the ALTERs so it also works on pre-kind_seq tables.
      db.exec("CREATE INDEX IF NOT EXISTS idx_identity_kind_seq ON identity(code, kind_seq)")

      # Older databases index every row's new_id. Every current-version query
      # says `new_id IS NULL`, true of nearly every row, yet with statistics
      # an index over all rows looks selective (rows per distinct value) and
      # lures the planner into reading every current artifact.
      new_id_index = db.query_one?("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_artifact_new_id'", as: String)
      if new_id_index && !new_id_index.includes?("WHERE")
        db.exec("DROP INDEX idx_artifact_new_id")
        db.exec("CREATE INDEX idx_artifact_new_id ON artifact(new_id) WHERE new_id IS NOT NULL")
      end

      Registry.migrate_legacy_indexes(db)
    end
  end
end
