{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "spec"
require "../../../../../src/grant/drivers/sqlite3/sqlite3"

SQLITE_DRIVER_DB_FILENAME = "./test.db"

def with_sqlite_driver_db(&block : DB::Database ->)
  File.delete(SQLITE_DRIVER_DB_FILENAME) rescue nil
  DB.open "sqlite3:#{SQLITE_DRIVER_DB_FILENAME}", &block
ensure
  File.delete(SQLITE_DRIVER_DB_FILENAME)
end

def with_sqlite_driver_cnn(&block : DB::Connection ->)
  File.delete(SQLITE_DRIVER_DB_FILENAME) rescue nil
  DB.connect "sqlite3:#{SQLITE_DRIVER_DB_FILENAME}", &block
ensure
  File.delete(SQLITE_DRIVER_DB_FILENAME)
end

def with_sqlite_driver_db(config, &block : DB::Database ->)
  uri = "sqlite3:#{config}"
  filename = Grant::SQLite3::Connection.filename(URI.parse(uri))
  File.delete(filename) rescue nil
  DB.open uri, &block
ensure
  File.delete(filename) if filename
end

def with_sqlite_driver_mem_db(&block : DB::Database ->)
  DB.open "sqlite3://%3Amemory%3A", &block
end
