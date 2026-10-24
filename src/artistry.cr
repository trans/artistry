require "sqlite3"
require "./artistry/errors"
require "./artistry/database"
require "./artistry/validator"
require "./artistry/registry"
require "./artistry/artifact"
require "./artistry/link"
require "./artistry/tag"
require "./artistry/transaction"

module Artistry
  VERSION = "0.13.0"

  class_property db_path : String = "artistry.db"
  class_getter! db : DB::Database
  @@owns_db = false

  # Open a new connection by path (Artistry owns and will close it)
  def self.open(path : String = db_path) : DB::Database
    close if @@db
    uri = path == ":memory:" ? "sqlite3:%3Amemory%3A" : "sqlite3://#{path}"
    db = DB.open(uri)
    db.exec("PRAGMA foreign_keys = ON")
    @@db = db
    @@owns_db = true
    Database.ensure_schema(db)
    refresh_statistics(db)
    db
  end

  # Use an existing connection (caller owns it, Artistry won't close it)
  def self.open(db : DB::Database) : DB::Database
    close if @@db
    @@db = db
    @@owns_db = false
    Database.ensure_schema(db)
    refresh_statistics(db)
    db
  end

  def self.open(path : String = db_path, &block) : Nil
    open(path)
    yield db
  ensure
    close
  end

  def self.open(db : DB::Database, &block) : Nil
    open(db)
    yield db
  ensure
    close
  end

  def self.close : Nil
    if @@owns_db && (db = @@db)
      refresh_statistics(db)
      db.close
    end
    @@db = nil
    @@owns_db = false
  end

  # Let SQLite refresh the statistics its query planner chooses indexes by
  # (`PRAGMA optimize`, which analyzes a table only when it has none or has
  # changed a lot, so it's quick otherwise). Without them it can pass over
  # an index. Runs on open and on close; a long-running process can call it
  # now and then too.
  def self.optimize : Nil
    conn.exec(OPTIMIZE)
  end

  # Checks every table (0x10000), not only those this connection has
  # queried, and analyzes in full: without 0x10, optimize doesn't sample.
  # A sample stops at about 2000 rows an index, so it puts a kind's code at
  # about 2000 artifacts however many the kind has, as selective as a
  # consumer's leading field; the code index, already in id order, then
  # wins.
  private OPTIMIZE = "PRAGMA optimize=0x10002"

  # Statistics are a help, not a need: a store that can't write them
  # (read-only, say) still opens and closes.
  private def self.refresh_statistics(db) : Nil
    db.exec(OPTIMIZE)
  rescue SQLite3::Exception
  end

  @@tx_connections = {} of Fiber => DB::Connection

  def self.conn
    @@tx_connections[Fiber.current]? || db
  end

  # Atomically allocate the next kind_seq for a given artifact code.
  #
  # Inserts or increments the counter in `kind_counter`, then returns
  # the new sequence number. Thread-safe via SQLite's write lock.
  def self.next_kind_seq(code : String) : Int64
    c = conn
    c.exec(
      "INSERT INTO kind_counter (code, next_seq) VALUES (?, 1) " \
      "ON CONFLICT(code) DO UPDATE SET next_seq = next_seq + 1",
      code
    )
    c.scalar("SELECT next_seq FROM kind_counter WHERE code = ?", code).as(Int64)
  end

  def self.transaction(&block)
    db.using_connection do |conn|
      @@tx_connections[Fiber.current] = conn
      conn.transaction do |tx|
        yield Transaction.new(tx)
      end
    end
  ensure
    @@tx_connections.delete(Fiber.current)
  end
end
