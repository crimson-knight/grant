require "spec"
require "../../../support/sqlite_engine/date_time_generator"
require "../../../support/sqlite_engine/write_oracle"

# The date and time functions compared with C SQLite: values pinned for
# Grant's stored format (six fractional digits), the inputs that give NULL,
# 'now' read once per statement run, the places that refuse 'now', and
# seeded random calls under two process time zones.
module DateTimeSpecFixture
  alias V = Grant::SQLiteEngine::Value

  lib LibZone
    fun tzset : Void
  end

  # Runs the block with the process time zone set to *name*, as the C
  # library's localtime_r sees it.
  def self.in_time_zone(name : String, &)
    previous = ENV["TZ"]?
    ENV["TZ"] = name
    LibZone.tzset
    begin
      yield
    ensure
      ENV["TZ"] = previous
      LibZone.tzset
    end
  end

  def self.bits(real : Float64) : UInt64
    real.unsafe_as(UInt64)
  end

  NULL_CALLS = [
    "date('not a date')", "datetime('2026-13-01')", "julianday(NULL)", "date('2026-00-10')", "date('2026-01-00')",
    "date('2026-01-32')", "time('25:00')", "time('10:60')", "time('10:00:60')", "date('2026-1-1')",
    "date('2026-11-24', NULL)", "date('2026-11-24', '')", "date('2026-11-24', 'start of week')", "date('2026-11-24', 'weekday 7')",
    "date('2026-11-24', '+1')", "date('2026-11-24', '1 fortnight')", "date('2026-11-24', '+1 day', 'auto')",
    "date('2026-11-24', 'unixepoch')", "date('2026-11-24', 'julianday')", "date(5373484.5)", "date(-1)",
    "date(1700000000)", "date(1e300, 'unixepoch')", "date('9999-12-31', '+1 day')", "date('0000-01-01', '-4714 years')",
    "date('-4713-11-23')", "datetime('2026-11-24 10:11:12.123456+15:00')", "datetime('2026-11-24 10:11:12.123456 UTC')",
    "strftime('%q', '2026-11-24')", "strftime('%', '2026-11-24')", "strftime(NULL, '2026-11-24')", "strftime('%Y', 'x')",
    "timediff('2026-11-24', NULL)", "timediff('x', '2026-11-24')", "timediff(1700000000, '2026-11-24')", "date(x'')",
    "date('2026-11-24', '+0001-12-00')", "date('2026-11-24', '+0001-00-31')", "date('2026-11-24', '0001-00-00')",
  ]

  CONTEXT_SCRIPTS = [
    ["CREATE TABLE t(x, CHECK (x < date('now')))", "INSERT INTO t VALUES ('2020-01-01')"],
    ["CREATE TABLE t(x, CHECK (date(x, 'localtime') > '2000'))", "INSERT INTO t VALUES ('2020-01-01')"],
    ["CREATE TABLE t(x, CHECK (x < current_date))", "INSERT INTO t VALUES ('2020-01-01')", "SELECT x FROM t"],
    ["CREATE TABLE t(x, y AS (date(x, 'utc')) STORED)", "INSERT INTO t VALUES ('2020-01-01')"],
    ["CREATE TABLE t(x, y AS (unixepoch()) STORED)", "INSERT INTO t VALUES ('2020-01-01')"],
    ["CREATE TABLE t(x)", "CREATE INDEX i ON t(strftime('%Y', x, 'utc'))", "INSERT INTO t VALUES (1)"],
    ["CREATE TABLE t(x)", "INSERT INTO t VALUES ('2020-01-01')", "CREATE INDEX i ON t(date(x, 'localtime'))"],
    ["CREATE TABLE t(x)", "CREATE INDEX i ON t(x) WHERE x < date('now')", "INSERT INTO t VALUES (1)"],
    ["CREATE TABLE t(x, y AS (date(x, '+1 day')) STORED, CHECK (time(x) IS NOT NULL))", "CREATE INDEX i ON t(date(x, 'start of month'))",
     "INSERT INTO t VALUES ('2020-01-31 10:11:12.123456')", "INSERT INTO t VALUES ('nope')", "SELECT * FROM t",
     "SELECT x FROM t WHERE date(x, 'start of month') = '2020-01-01'"],
  ]
end

describe "Grant::SQLiteEngine::Query date and time functions" do
  directory = Path[Dir.tempdir] / "grant-date-time-spec-#{Process.pid}"
  Dir.mkdir_p(directory)
  path = (directory / "fixture.db").to_s
  oracle = SQLiteQueryOracle::Connection.new(path)
  setup = "CREATE TABLE authors(id INTEGER PRIMARY KEY, born_at TEXT);" \
          "INSERT INTO authors VALUES (1, '2026-11-24 10:11:12.123456'), (2, '1999-12-31 23:59:59.999999'), (3, '2024-02-29 00:00:00.000000')"
  if message = oracle.exec(setup)
    raise "fixture setup failed: #{message}"
  end
  session = Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.open(path))
  both = ->(sql : String) do
    expected = oracle.query(sql)
    actual = SQLiteQueryOracle.engine_query(session, sql)
    SQLiteQueryOracle.difference(expected, actual, ordered: true).should be_nil, sql
    actual.list_of_rows
  end

  # The engine follows date.c of 3.51.0; older libraries lack modifiers
  # (ceiling, floor), conversions and the zero-offset UTC rule.
  library_version = SQLiteSQLOracle.version.split(" ").first
  if library_version.split(".").map(&.to_i) < [3, 51, 0]
    pending "matches C SQLite 3.51.0 (the linked libsqlite3 is #{library_version})"
    next
  end

  describe "Grant's stored format, six fractional digits" do
    it "reads date, time and datetime" do
      both.call("SELECT date(born_at), time(born_at), datetime(born_at) FROM authors ORDER BY id").should eq([
        ["2026-11-24", "10:11:12", "2026-11-24 10:11:12"],
        ["1999-12-31", "23:59:59", "1999-12-31 23:59:59"],
        ["2024-02-29", "00:00:00", "2024-02-29 00:00:00"],
      ])
    end

    it "gives julianday the same bits as C" do
      rows = both.call("SELECT julianday(born_at), CAST(julianday(born_at) AS TEXT) FROM authors ORDER BY id")
      rows.map { |row| DateTimeSpecFixture.bits(row[0].as(Float64)) }.should eq([
        4702540160864370177_u64, 4702519063073521639_u64, 4702538014616715264_u64,
      ])
      rows.map(&.[1]).should eq(["2461368.92444587", "2451544.49999999", "2460369.5"])
    end

    it "cuts fractional seconds to milliseconds" do
      both.call("SELECT unixepoch(born_at), unixepoch(born_at, 'subsec'), datetime(born_at, 'subsec'), time(born_at, 'subsecond'), " \
                "strftime('%Y-%m-%d %H:%M:%f', born_at), strftime('%s', born_at, 'subsec'), strftime('%J', born_at) " \
                "FROM authors ORDER BY id").should eq([
        [1795515072_i64, 1795515072.123, "2026-11-24 10:11:12.123", "10:11:12.123", "2026-11-24 10:11:12.123", "1795515072.123", "2461368.924445868"],
        [946684799_i64, 946684799.999, "1999-12-31 23:59:59.999", "23:59:59.999", "1999-12-31 23:59:59.999", "946684799.999", "2451544.499999988"],
        [1709164800_i64, 1709164800.0, "2024-02-29 00:00:00.000", "00:00:00.000", "2024-02-29 00:00:00.000", "1709164800.000", "2460369.5"],
      ])
    end

    it "applies modifiers" do
      both.call("SELECT datetime(born_at, '+1 day'), datetime(born_at, 'start of month'), date(born_at, 'weekday 0'), " \
                "datetime(born_at, '-3 hours', '+30 minutes'), date(born_at, '+1 month'), date(born_at, '+1 year', 'floor'), " \
                "datetime(born_at, '+0001-01-01 01:01:01.001', 'subsec'), datetime(born_at, '-1.5 seconds', 'subsec') " \
                "FROM authors ORDER BY id").should eq([
        ["2026-11-25 10:11:12", "2026-11-01 00:00:00", "2026-11-29", "2026-11-24 07:41:12", "2026-12-24", "2027-11-24",
         "2027-12-25 11:12:13.124", "2026-11-24 10:11:10.623"],
        ["2000-01-01 23:59:59", "1999-12-01 00:00:00", "2000-01-02", "1999-12-31 21:29:59", "2000-01-31", "2000-12-31",
         "2001-02-02 01:01:01.000", "1999-12-31 23:59:58.499"],
        ["2024-03-01 00:00:00", "2024-02-01 00:00:00", "2024-03-03", "2024-02-28 21:30:00", "2024-03-29", "2025-02-28",
         "2025-03-30 01:01:01.001", "2024-02-28 23:59:58.500"],
      ])
    end

    it "compares and orders stored times as text and through datetime()" do
      both.call("SELECT id FROM authors WHERE born_at >= '2024-02-29 00:00:00.000000' AND datetime(born_at) < datetime('2026-12-01') ORDER BY julianday(born_at) DESC")
        .should eq([[1_i64], [3_i64]])
    end
  end

  describe "time values and modifiers" do
    it "normalizes a day past the end of its month as C does" do
      both.call("SELECT date('2026-02-30'), date('2026-02-30', '+0 days'), date('2026-01-31', '+1 month'), date('2026-01-31', '+1 month', 'floor'), " \
                "date('2024-02-29', '+1 year'), date('2024-02-29', '+1 year', 'floor'), date('2026-04-31'), datetime('2026-11-24 24:00:00')")
        .should eq([["2026-03-02", "2026-03-02", "2026-03-03", "2026-02-28", "2025-03-01", "2025-02-28", "2026-05-01", "2026-11-24 24:00:00"]])
    end

    it "reads every time value format" do
      both.call("SELECT datetime('2026-11-24T10:11'), datetime('2026-11-24 10:11:12.5+02:30'), datetime('2026-11-24 10:11:12Z'), " \
                "datetime('10:11'), time('10:11:12.999999999'), datetime(2460000.5), datetime('2460000.5'), datetime(1700000000, 'unixepoch'), " \
                "datetime(1700000000, 'auto'), datetime(1700000000.5, 'unixepoch', 'subsec'), date('0000-01-01'), datetime('9999-12-31 23:59:59.999'), " \
                "date('-4713-11-24'), julianday('-4713-11-24 12:00:00'), date(0, 'julianday'), unixepoch('1969-12-31 23:59:59.5'), timediff('2026-11-24 10:00:00', '2026-01-01 00:00:00'), " \
                "timediff('2023-02-28', '2024-02-29 12:00:00.5')")
        .should eq([["2026-11-24 10:11:00", "2026-11-24 07:41:12", "2026-11-24 10:11:12", "2000-01-01 10:11:00", "10:11:12", "2023-02-25 00:00:00",
                     "2023-02-25 00:00:00", "2023-11-14 22:13:20", "2023-11-14 22:13:20", "2023-11-14 22:13:20.500", "0000-01-01",
                     "9999-12-31 23:59:59", nil, 0.0, "-4713-11-24", -1_i64, "+0000-10-23 10:00:00.000", "-0001-00-01 12:00:00.500"]])
    end

    it "writes every strftime conversion" do
      both.call("SELECT strftime('%d|%e|%f|%F|%G|%g|%H|%I|%j|%J|%k|%l|%m|%M|%p|%P|%R|%s|%S|%T|%u|%U|%V|%w|%W|%Y|%%', '2027-01-03 04:05:06.789012')")
        .should eq([["03| 3|06.789|2027-01-03|2026|26|04|04|003|2461408.670217465| 4| 4|01|05|AM|am|04:05|1798949106|06|04:05:06|7|01|53|0|00|2027|%"]])
    end

    it "gives NULL exactly where C gives NULL" do
      DateTimeSpecFixture::NULL_CALLS.each do |call|
        both.call("SELECT #{call}").should eq([[nil]]), call
      end
    end
  end

  describe "'now'" do
    it "is read once for each run of a statement" do
      both.call("SELECT count(DISTINCT julianday('now')), count(DISTINCT unixepoch('subsec')), count(DISTINCT strftime('%J')), " \
                "min(datetime('now') = current_timestamp), min(date() = current_date), min(time('now') = current_time), " \
                "min(julianday() = julianday('now', '+0 seconds')) FROM authors, authors AS other").should eq([[1_i64, 1_i64, 1_i64, 1_i64, 1_i64, 1_i64, 1_i64]])
      query = session.prepare("SELECT julianday('now'), julianday('now', 'subsec'), unixepoch('now', 'subsec') FROM authors")
      rows = query.all_rows
      rows.uniq.size.should eq(1)
      rows[0][0].should eq(rows[0][1])
    end

    it "is read again by the next run of a prepared statement" do
      query = session.prepare("SELECT unixepoch('now', 'subsec'), current_timestamp")
      first = query.all_rows[0][0].as(Float64)
      sleep 20.milliseconds
      query.reset
      second = query.all_rows[0][0].as(Float64)
      (second - first).should be >= 0.019
      (Time.utc.to_unix_f - second).abs.should be < 5.0
    end

    it "agrees with the clock in every function" do
      row = session.prepare("SELECT unixepoch(), datetime(), date('now'), current_date, current_time, current_timestamp, julianday('now'), typeof(current_time)").all_rows[0]
      moment = Time.unix(row[0].as(Int64))
      row[1].should eq(moment.to_s("%Y-%m-%d %H:%M:%S"))
      row[2].should eq(moment.to_s("%Y-%m-%d"))
      row[3].should eq(row[2])
      row[4].should eq(moment.to_s("%H:%M:%S"))
      row[5].should eq(row[1])
      (row[6].as(Float64) - (row[0].as(Int64) / 86400.0 + 2440587.5)).abs.should be < 1.0 / 86400
      row[7].should eq("text")
    end
  end

  describe "defaults and the places that demand deterministic functions" do
    it "evaluates DEFAULT (datetime('now')) and CURRENT_TIMESTAMP when each row is inserted" do
      pair = SQLiteWriteOracle::Pair.new((directory / "defaults").to_s)
      pair.step("CREATE TABLE events(id INTEGER PRIMARY KEY, created_at DEFAULT (datetime('now')), stamped_at DEFAULT CURRENT_TIMESTAMP, " \
                "day DEFAULT CURRENT_DATE, clock DEFAULT CURRENT_TIME, exact DEFAULT (julianday('now')))").should be_nil
      pair.engine_step("INSERT INTO events(id) VALUES (1)")
      sleep 20.milliseconds
      pair.engine_step("INSERT INTO events(id) VALUES (2)")
      rows = pair.engine_step("SELECT created_at = stamped_at, created_at = day || ' ' || clock, abs(julianday('now') - exact) < 0.001, exact FROM events ORDER BY id").outcome.list_of_rows
      rows.map(&.[0, 3]).should eq([[1_i64, 1_i64, 1_i64], [1_i64, 1_i64, 1_i64]])
      (rows[1][3].as(Float64) - rows[0][3].as(Float64)).should be > 0.019 / 86400
      pair.close
    end

    it "refuses 'now', localtime and utc in a CHECK constraint, a generated column and an index, as C does" do
      DateTimeSpecFixture::CONTEXT_SCRIPTS.each_with_index do |script, index|
        pair = SQLiteWriteOracle::Pair.new((directory / "context-#{index}").to_s)
        script.each { |sql| pair.step(sql).should be_nil, sql }
        pair.close
      end
      pair = SQLiteWriteOracle::Pair.new((directory / "context-message").to_s)
      pair.step("CREATE TABLE t(x, CHECK (x < date('now')))")
      pair.engine_step("INSERT INTO t VALUES (1)").outcome.error.should eq("non-deterministic use of date() in a CHECK constraint")
      pair.close
    end
  end

  describe "localtime and utc" do
    it "follow the process time zone" do
      DateTimeSpecFixture.in_time_zone("America/New_York") do
        both.call("SELECT datetime('2026-07-04 12:00:00', 'localtime'), datetime('2026-01-15 12:00:00', 'localtime'), " \
                  "datetime('2026-07-04 12:00:00', 'utc'), datetime('2026-03-08 02:30:00', 'utc'), datetime('2026-11-01 01:30:00', 'utc'), " \
                  "datetime('1960-07-04 12:00:00', 'localtime'), datetime('2500-01-15 12:00:00.123456', 'localtime', 'subsec'), " \
                  "datetime('2026-07-04 12:00:00Z', 'utc'), datetime('2026-07-04 12:00:00', 'localtime', 'localtime'), " \
                  "datetime('2026-07-04 12:00:00', 'localtime', 'utc')")
          .should eq([["2026-07-04 08:00:00", "2026-01-15 07:00:00", "2026-07-04 16:00:00", "2026-03-08 07:30:00", "2026-11-01 05:30:00",
                       "1960-07-04 08:00:00", "2500-01-15 07:00:00.123", "2026-07-04 12:00:00", "2026-07-04 08:00:00", "2026-07-04 12:00:00"]])
      end
      DateTimeSpecFixture.in_time_zone("UTC") do
        both.call("SELECT datetime('2026-07-04 12:00:00', 'localtime'), datetime('2026-07-04 12:00:00', 'utc')")
          .should eq([["2026-07-04 12:00:00", "2026-07-04 12:00:00"]])
      end
    end
  end

  describe "seeded random calls" do
    {"UTC" => 20261124, "America/New_York" => 20261125}.each do |zone, seed|
      it "match C SQLite under TZ=#{zone}" do
        DateTimeSpecFixture.in_time_zone(zone) do
          generator = SQLiteDateTimeGenerator.new(seed)
          failures = [] of String
          6000.times do
            sql, parameters = generator.call
            expected = oracle.query(sql, parameters)
            actual = begin
              SQLiteQueryOracle.engine_query(session, sql, parameters)
            rescue error : Exception
              SQLiteQueryOracle::Outcome.new([] of String, [] of Array(DateTimeSpecFixture::V), "raised #{error.class}: #{error.message}", [] of Bool)
            end
            if difference = SQLiteQueryOracle.difference(expected, actual, ordered: true)
              failures << "#{sql} #{parameters.inspect}\n    #{difference}"
            end
          end
          failures.first(20).should eq([] of String)
        end
      end
    end
  end
end
