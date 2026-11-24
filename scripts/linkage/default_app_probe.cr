# A program shaped like a default Amber app's use of Grant on SQLite: models
# with associations, built-in validations, normalization, querying, saving,
# transactions, sums and verbose query logs. `scripts/check_pcre2_linkage.rb`
# and `scripts/check_gmp_linkage.rb` build it and require that the binary
# links no PCRE2 and no GMP, then run it; `scripts/check_sqlite3_linkage.rb`
# builds it with -Dgrant_without_libsqlite3 and requires no libsqlite3.
require "../../src/grant"
require "../../src/adapter/sqlite"

require "./default_app_workload"
