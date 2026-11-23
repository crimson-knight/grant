# Grant's pure-Crystal SQLite engine, opt-in. This milestone (G1) reads the
# SQLite database file format: the header, every b-tree page type, overflow
# chains, the record format, the schema table, the freelist, pointer-map pages
# and committed frames of a `-wal` file, with no native library.
#
# Files are opened read-only and never written, including the `-wal` and
# `-shm` files. Every structural fact read from disk is checked before use; a
# violation raises `Grant::SQLiteEngine::CorruptDatabase` naming the page and
# the check.
#
# ```
# require "grant/sqlite_engine"
#
# database = Grant::SQLiteEngine::Database.open("app.db")
# database.each_row("users") do |row|
#   row.rowid  # => 1_i64
#   row.values # => [1_i64, "ada@example.com"]
# end
# database.close
# ```
#
# Specification: https://www.sqlite.org/fileformat2.html ,
# https://www.sqlite.org/walformat.html , https://www.sqlite.org/datatype3.html
module Grant::SQLiteEngine
end

require "./sqlite_engine/errors"
require "./sqlite_engine/limits"
require "./sqlite_engine/value"
require "./sqlite_engine/varint"
require "./sqlite_engine/database_header"
require "./sqlite_engine/byte_source"
require "./sqlite_engine/wal_reader"
require "./sqlite_engine/pager"
require "./sqlite_engine/btree_page"
require "./sqlite_engine/payload_reader"
require "./sqlite_engine/record"
require "./sqlite_engine/schema_tokenizer"
require "./sqlite_engine/table_definition"
require "./sqlite_engine/index_definition"
require "./sqlite_engine/schema"
require "./sqlite_engine/freelist"
require "./sqlite_engine/pointer_map"
require "./sqlite_engine/database"
require "./sqlite_engine/dump"
require "./sqlite_engine/sql"
