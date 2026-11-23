# Grant's pure-Crystal SQLite engine, opt-in. It reads and writes the SQLite
# database file format with no native library: the header, every b-tree page
# type, overflow chains, the record format, the schema table, the freelist,
# pointer-map pages and committed frames of a `-wal` file (G1), and, opened
# with `read_write: true`, writes through a rollback journal
# (`journal_mode=DELETE`) under the same POSIX locks C SQLite takes (G2).
#
# `Database.open(path)` opens a file read-only and never writes it, nor its
# `-wal` or `-shm` file. Every structural fact read from disk is checked
# before use; a violation raises `Grant::SQLiteEngine::CorruptDatabase`
# naming the page and the check.
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
#
# writer = Grant::SQLiteEngine::Database.open("app.db", read_write: true)
# writer.create_table("CREATE TABLE users(id INTEGER PRIMARY KEY, email TEXT UNIQUE)")
# writer.transaction do |database|
#   database.insert("users", nil, [nil, "ada@example.com"] of Grant::SQLiteEngine::Value) # => 1_i64
#   database.update("users", 1_i64, [1_i64, "ada@example.org"] of Grant::SQLiteEngine::Value)
# end
# writer.close
# ```
#
# Specification: https://www.sqlite.org/fileformat2.html ,
# https://www.sqlite.org/atomiccommit.html , https://www.sqlite.org/lockingv3.html ,
# https://www.sqlite.org/walformat.html , https://www.sqlite.org/datatype3.html
module Grant::SQLiteEngine
end

require "./sqlite_engine/errors"
require "./sqlite_engine/limits"
require "./sqlite_engine/value"
require "./sqlite_engine/varint"
require "./sqlite_engine/database_header"
require "./sqlite_engine/byte_source"
require "./sqlite_engine/file_system"
require "./sqlite_engine/memory_file_system"
require "./sqlite_engine/rollback_journal"
require "./sqlite_engine/wal_reader"
require "./sqlite_engine/pager"
require "./sqlite_engine/btree_page"
require "./sqlite_engine/payload_reader"
require "./sqlite_engine/record"
require "./sqlite_engine/record_encoder"
require "./sqlite_engine/key_comparator"
require "./sqlite_engine/page_editor"
require "./sqlite_engine/btree_writer"
require "./sqlite_engine/schema_tokenizer"
require "./sqlite_engine/table_definition"
require "./sqlite_engine/index_definition"
require "./sqlite_engine/schema"
require "./sqlite_engine/freelist"
require "./sqlite_engine/pointer_map"
require "./sqlite_engine/index_layout"
require "./sqlite_engine/create_statement"
require "./sqlite_engine/database"
require "./sqlite_engine/database_writer"
require "./sqlite_engine/database_row_access"
require "./sqlite_engine/dump"
require "./sqlite_engine/sql"
require "./sqlite_engine/query"
