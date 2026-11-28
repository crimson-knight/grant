# Grant's SQLite adapter on Grant's own engine only (`Grant::SQLiteEngine`).
# The program links no C SQLite library, and `Grant.settings.sqlite_engine`
# starts at `:grant`.
#
# ```
# require "grant/adapter/sqlite/grant_engine"
# ```
#
# To run on the system's C SQLite library instead, require
# `"grant/adapter/sqlite"` (or add `require "grant/adapter/sqlite/libsqlite3"`):
# the setting then starts at `:libsqlite3`, and `:grant` stays available.
require "./adapter"
require "../../grant/drivers/sqlite3/grant_engine"
