# Replays the migration corpus on Grant's SQLite engine and on C SQLite and
# reports every difference (spec/support/sqlite_engine/migration_differential.cr
# says what is compared), each marked with its reason when it is one of the
# known remaining differences.
#
#   crystal-alpha run scripts/sqlite_engine_migration_differential.cr -- CORPUS_DIR REPORT_DIR
#
# CORPUS_DIR is spec/grant/sqlite_engine/migrations (written partly by
# scripts/sqlite_engine_migration_corpus.rb). REPORT_DIR receives
# summary.txt, differences.txt and remaining.txt. The exit status is 1 when
# a difference is unexplained or a remaining rule matched nothing.
#
# Link a pinned libsqlite3 with --link-flags "-L DIR -Wl,-rpath,DIR".
require "../spec/support/sqlite_engine/migration_differential"

corpus = ARGV[0]? || abort "usage: sqlite_engine_migration_differential CORPUS_DIR REPORT_DIR"
directory = ARGV[1]? || abort "usage: sqlite_engine_migration_differential CORPUS_DIR REPORT_DIR"
started = Time.instant
report = MigrationDifferential.run(corpus, File.join(directory, "work"))
count = MigrationDifferential.list_of_migrations(corpus).size
puts report.write(directory, "migration differential over #{corpus}: #{count} migrations, #{(Time.instant - started).total_seconds.round(1)} s")
exit 1 unless report.list_of_unexplained.empty? && report.list_of_unused_rules.empty?
