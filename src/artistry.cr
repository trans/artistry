require "sqlite3"
require "./artistry/database"
require "./artistry/validator"
require "./artistry/registry"
require "./artistry/artifact"
require "./artistry/link"
require "./artistry/tag"

module Artistry
  VERSION = "0.8.0"

  class_property db_path : String = "artistry.db"
  class_getter! db : DB::Database

  def self.open(path : String = db_path) : DB::Database
    uri = path == ":memory:" ? "sqlite3:%3Amemory%3A" : "sqlite3://#{path}"
    db = DB.open(uri)
    db.exec("PRAGMA foreign_keys = ON")
    @@db = db
    Database.ensure_schema(db)
    db
  end

  def self.open(path : String = db_path, &block) : Nil
    open(path)
    yield db
  ensure
    close
  end

  def self.close : Nil
    @@db.try &.close
    @@db = nil
  end

  @@tx_connections = {} of Fiber => DB::Connection

  def self.conn
    @@tx_connections[Fiber.current]? || db
  end

  def self.transaction(&block)
    db.using_connection do |conn|
      @@tx_connections[Fiber.current] = conn
      conn.transaction do |tx|
        yield tx
      end
    end
  ensure
    @@tx_connections.delete(Fiber.current)
  end
end
