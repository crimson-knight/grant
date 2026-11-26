# Compares Grant's SQLite engine with C SQLite on triggers: both run the
# same statements, each on its own database file, and after every statement
# the rows, the error, changes(), last_insert_rowid() and the growth of
# total_changes() are compared. After each schema change outside a
# transaction, and at the end of every scenario, C reads both files: the
# engine's must pass C's integrity_check and hold the same sqlite_schema
# rows (trigger SQL text included) and table rows; the TEMP schema is
# compared through each side's own connection.
#
#   crystal-alpha run scripts/sqlite_engine_trigger_differential.cr -- corpus FILE REPORT_DIR
#     FILE holds scenarios, each starting at a line `-- scenario: NAME`.
#     A line `-- swap` puts a copy of C's file in place of the engine's, so
#     the engine goes on reading (and firing) triggers C wrote.
#
#   crystal-alpha run scripts/sqlite_engine_trigger_differential.cr -- records FILE REPORT_DIR
#     FILE is JSON lines {"source": "file.test:line", "sql": ...} from
#     scripts/sqlite_engine_sql_tests_extract.rb run over SQLite's
#     trigger*.test files; every test file is one scenario, its blocks run
#     in order.
#
# A statement the engine refuses with UnsupportedSQL is listed with its
# reason, not counted as a difference; C's file then replaces the engine's
# so later statements start from the same state.
require "../spec/support/sqlite_engine/trigger_differential"

mode = ARGV[0]? || abort "usage: corpus FILE REPORT_DIR | records FILE REPORT_DIR"
path = ARGV[1]? || abort "missing FILE"
directory = ARGV[2]? || abort "missing REPORT_DIR"
started = Time.instant
scenarios = case mode
            when "corpus"  then TriggerScenarios.from_corpus(path)
            when "records" then TriggerScenarios.from_records(path)
            else                abort "unknown mode #{mode}"
            end
report = TriggerReport.new
work = File.join(directory, "work")
FileUtils.rm_rf(work)
differential = TriggerDifferential.new(report, work)
scenarios.each { |scenario| differential.run(scenario) }
FileUtils.rm_rf(work)
report.write(directory, "trigger differential, #{mode} #{File.basename(path)}, #{(Time.instant - started).total_seconds.round(1)} s")
