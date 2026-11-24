# The default app workload on the adapter entry that leaves the C engine out
# (`grant/adapter/sqlite/grant_engine`), built with no flags.
# `scripts/check_sqlite3_linkage.rb` requires that the binary links no
# libsqlite3 and runs every statement on Grant's engine.
require "../../src/grant"
require "../../src/adapter/sqlite/grant_engine"

require "./default_app_workload"
