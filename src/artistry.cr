require "sqlite3"
require "./artistry/database"
require "./artistry/validator"
require "./artistry/registry"
require "./artistry/artifact"
require "./artistry/link"
require "./artistry/tag"
require "./artistry/transaction"

module Artistry
  VERSION = "0.9.1"

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
    db
  end

  # Use an existing connection (caller owns it, Artistry won't close it)
  def self.open(db : DB::Database) : DB::Database
    close if @@db
    @@db = db
    @@owns_db = false
    Database.ensure_schema(db)
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
    @@db.try(&.close) if @@owns_db
    @@db = nil
    @@owns_db = false
  end

  @@tx_connections = {} of Fiber => DB::Connection

  def self.conn
    @@tx_connections[Fiber.current]? || db
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
