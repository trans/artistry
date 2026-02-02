module Artistry
  module Database
    SCHEMA = <<-SQL
      CREATE TABLE IF NOT EXISTS identity (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
      );

      CREATE TABLE IF NOT EXISTS registry (
        code TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        plugin TEXT NOT NULL,
        description TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        UNIQUE(plugin, kind)
      );

      CREATE TABLE IF NOT EXISTS schema (
        code TEXT NOT NULL,
        version INTEGER NOT NULL,
        json TEXT NOT NULL,
        hash TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (code, version),
        FOREIGN KEY (code) REFERENCES registry(code)
      );

      CREATE TABLE IF NOT EXISTS artifact (
        id INTEGER PRIMARY KEY,
        code TEXT NOT NULL,
        version INTEGER NOT NULL,
        data JSON NOT NULL,
        hash TEXT NOT NULL,
        superseded_by INTEGER REFERENCES identity(id),
        updated_at TEXT,
        FOREIGN KEY (id) REFERENCES identity(id),
        FOREIGN KEY (code, version) REFERENCES schema(code, version)
      );

      CREATE INDEX IF NOT EXISTS idx_artifact_code ON artifact(code);
      CREATE INDEX IF NOT EXISTS idx_artifact_superseded ON artifact(superseded_by);

      CREATE TABLE IF NOT EXISTS link (
        from_id INTEGER NOT NULL REFERENCES identity(id),
        to_id INTEGER NOT NULL REFERENCES identity(id),
        kind TEXT NOT NULL,
        data JSON,
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (from_id, to_id, kind)
      );
    SQL

    def self.ensure_schema(db : DB::Database) : Nil
      SCHEMA.split(";").each do |stmt|
        stmt = stmt.strip
        next if stmt.empty?
        db.exec(stmt)
      end
    end
  end
end
