# Grant's SQLite adapter on the system's C SQLite library (the default,
# `Grant.settings.sqlite_engine = :libsqlite3`). `require
# "grant/adapter/sqlite"` loads this file. Grant's own engine (`:grant`) is
# compiled in only when the program also requires
# `grant/adapter/sqlite/grant_engine`, or is built with
# -Dgrant_without_libsqlite3, which leaves the C library out and runs on
# Grant's engine instead.
require "./adapter"
require "../../grant/drivers/sqlite3/libsqlite3"
{% if flag?(:grant_without_libsqlite3) %}
  require "../../grant/drivers/sqlite3/grant_engine"
{% end %}
