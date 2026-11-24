# Grant's SQLite adapter with both engines: the system's C SQLite library
# (the default, `Grant.settings.sqlite_engine = :libsqlite3`) and Grant's own
# engine (`:grant`). `require "grant/adapter/sqlite"` loads this file.
require "./adapter"
require "../../grant/drivers/sqlite3/libsqlite3"
