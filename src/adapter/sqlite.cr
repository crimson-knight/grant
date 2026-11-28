# Grant's SQLite adapter on the C SQLite library. Grant's own engine is
# compiled in only when the app also requires `grant/adapter/sqlite/grant_engine`
# (see `sqlite/grant_engine.cr`, which links no C library on its own).
require "./sqlite/libsqlite3"
