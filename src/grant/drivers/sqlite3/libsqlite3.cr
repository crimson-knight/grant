# The C SQLite library as an engine for Grant's SQLite driver
# (`Grant::SQLite3::Engine::LibSQLite3Engine`). A program links libsqlite3
# only when it requires this file: `require "grant/adapter/sqlite"` does,
# `require "grant/adapter/sqlite/grant_engine"` does not. A program built
# with -Dgrant_without_libsqlite3 leaves it out even when required.
require "./sqlite3"
require "./libsqlite3/lib_sqlite3"
require "./libsqlite3/lib_sqlite3_engine"
