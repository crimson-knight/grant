# Compares SQLite's date and time functions on Grant's engine with C SQLite
# over seeded random calls (SQLiteDateTimeGenerator).
#
#   crystal-alpha build --release scripts/sqlite_engine_datetime_differential.cr -o datetime_differential
#   TZ=America/New_York ./datetime_differential SEED COUNT REPORT_DIR
#
# Writes REPORT_DIR/summary.txt (counts by function and by result kind) and
# REPORT_DIR/differences.txt, and exits 1 when any call differs. The
# `localtime` and `utc` modifiers follow the process time zone, so run it
# under each zone of interest.
#
# Link a pinned libsqlite3 with --link-flags "-L DIR -Wl,-rpath,DIR".
require "file_utils"
require "../spec/support/sqlite_engine/date_time_generator"

seed = ARGV[0].to_i
count = ARGV[1].to_i
report_directory = ARGV[2]
FileUtils.mkdir_p(report_directory)

directory = Path[Dir.tempdir] / "grant-datetime-differential-#{Process.pid}"
Dir.mkdir_p(directory)
path = (directory / "fixture.db").to_s
oracle = SQLiteQueryOracle::Connection.new(path)
oracle.exec("CREATE TABLE t (x)")
session = Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.open(path))

generator = SQLiteDateTimeGenerator.new(seed)
calls_by_function = Hash(String, Int32).new(0)
results_by_kind = Hash(String, Int32).new(0)
differences = [] of String
count.times do
  sql, parameters = generator.call
  expected = oracle.query(sql, parameters)
  actual = begin
    SQLiteQueryOracle.engine_query(session, sql, parameters)
  rescue error : Exception
    SQLiteQueryOracle::Outcome.new([] of String, [] of Array(Grant::SQLiteEngine::Value), "raised #{error.class}: #{error.message}", [] of Bool)
  end
  calls_by_function[sql[7...sql.index!('(')]] += 1
  kind = expected.error ? "error" : SQLiteQueryOracle.token(expected.list_of_rows[0][0]).split(':')[0]
  results_by_kind[kind] += 1
  if difference = SQLiteQueryOracle.difference(expected, actual, ordered: true)
    differences << "#{sql} #{parameters.inspect}\n    #{difference}"
  end
end

summary = String.build do |io|
  io << "date and time differential: seed " << seed << ", " << count << " calls, TZ " << (ENV["TZ"]? || "(unset)") << '\n'
  io << "C library " << SQLiteSQLOracle.version << '\n'
  io << "calls by function: " << calls_by_function.to_a.sort.map { |(name, total)| "#{name} #{total}" }.join(", ") << '\n'
  io << "C results: " << results_by_kind.to_a.sort.map { |(name, total)| "#{name} #{total}" }.join(", ") << '\n'
  io << "differences: " << differences.size << '\n'
end
File.write(File.join(report_directory, "summary.txt"), summary)
File.write(File.join(report_directory, "differences.txt"), differences.join("\n"))
STDOUT.print summary
differences.first(25).each { |difference| STDOUT.puts difference }
FileUtils.rm_rf(directory.to_s)
exit differences.empty? ? 0 : 1
