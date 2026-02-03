require "sqlite3"
require "./artistry/database"
require "./artistry/registry"
require "./artistry/artifact"
require "./artistry/link"

module Artistry
  VERSION = "0.2.0"

  class_property db_path : String = "artistry.db"
  class_getter! db : DB::Database

  def self.open(path : String = db_path) : DB::Database
    uri = path == ":memory:" ? "sqlite3:%3Amemory%3A" : "sqlite3://#{path}"
    db = DB.open(uri)
    @@db = db
    Database.ensure_schema(db)
    db
  end

  def self.open(path : String = db_path, &) : Nil
    open(path)
    yield db
  ensure
    close
  end

  def self.close : Nil
    @@db.try &.close
    @@db = nil
  end
end
