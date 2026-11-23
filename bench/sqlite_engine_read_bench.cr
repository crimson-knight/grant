# bench/sqlite_engine_read_bench.cr
#
# Interleaved A/B of Grant's pure-Crystal SQLite reader (milestone G1)
# against the C library on the same file: the two alternate for ROUNDS rounds
# (order flipped every round), and each workload reports the median ratio
# as "N× as fast" or "N× slower" with the range of the middle rounds.
#
#   crystal-alpha build --release bench/sqlite_engine_read_bench.cr -o sqlite_engine_read_bench
#   ./sqlite_engine_read_bench [path/to/bench.db] [rounds]
#
# The database is built with the sqlite3 tool when the path does not exist:
# 200,000 rows of (INTEGER PRIMARY KEY, TEXT, INTEGER, REAL, TEXT) and an
# index on the text column. Both sides materialize every value as a Crystal
# value (Int64, Float64, String), so the comparison includes decoding.
#
# Only this benchmark links libsqlite3; the engine itself links no native
# library.
require "../src/grant/sqlite_engine"

@[Link("sqlite3")]
lib LibSQLite3Reference
  alias Handle = Void*
  alias Statement = Void*

  fun open_v2 = sqlite3_open_v2(filename : UInt8*, db : Handle*, flags : Int32, vfs : UInt8*) : Int32
  fun close_v2 = sqlite3_close_v2(db : Handle) : Int32
  fun prepare_v2 = sqlite3_prepare_v2(db : Handle, sql : UInt8*, bytes : Int32, statement : Statement*, tail : UInt8**) : Int32
  fun step = sqlite3_step(statement : Statement) : Int32
  fun reset = sqlite3_reset(statement : Statement) : Int32
  fun finalize = sqlite3_finalize(statement : Statement) : Int32
  fun bind_int64 = sqlite3_bind_int64(statement : Statement, index : Int32, value : Int64) : Int32
  fun column_count = sqlite3_column_count(statement : Statement) : Int32
  fun column_type = sqlite3_column_type(statement : Statement, column : Int32) : Int32
  fun column_int64 = sqlite3_column_int64(statement : Statement, column : Int32) : Int64
  fun column_double = sqlite3_column_double(statement : Statement, column : Int32) : Float64
  fun column_text = sqlite3_column_text(statement : Statement, column : Int32) : UInt8*
  fun column_blob = sqlite3_column_blob(statement : Statement, column : Int32) : Void*
  fun column_bytes = sqlite3_column_bytes(statement : Statement, column : Int32) : Int32
  fun libversion = sqlite3_libversion : UInt8*
  fun sourceid = sqlite3_sourceid : UInt8*
end

module SQLiteEngineReadBench
  OPEN_READONLY =       1
  ROW           =     100
  ROWS          = 200_000
  LOOKUPS       =  20_000
  OPENS         =     300

  alias Value = Grant::SQLiteEngine::Value

  # Runs a prepared statement to the end, materializing every column.
  def self.drain(statement : LibSQLite3Reference::Statement) : Int64
    count = 0_i64
    columns = LibSQLite3Reference.column_count(statement)
    while LibSQLite3Reference.step(statement) == ROW
      columns.times do |column|
        value = read_column(statement, column)
        count += 1 unless value.nil?
      end
    end
    count
  end

  def self.read_column(statement : LibSQLite3Reference::Statement, column : Int32) : Value
    case LibSQLite3Reference.column_type(statement, column)
    when 1 then LibSQLite3Reference.column_int64(statement, column)
    when 2 then LibSQLite3Reference.column_double(statement, column)
    when 3
      String.new(LibSQLite3Reference.column_text(statement, column), LibSQLite3Reference.column_bytes(statement, column))
    when 4
      size = LibSQLite3Reference.column_bytes(statement, column)
      Bytes.new(LibSQLite3Reference.column_blob(statement, column).as(UInt8*), size).dup
    end
  end

  def self.with_c_database(path : String, & : LibSQLite3Reference::Handle ->) : Nil
    handle = Pointer(Void).null
    code = LibSQLite3Reference.open_v2(path, pointerof(handle), OPEN_READONLY, nil)
    raise "sqlite3_open_v2 failed with #{code}" unless code == 0
    yield handle
    LibSQLite3Reference.close_v2(handle)
  end

  def self.c_query(handle : LibSQLite3Reference::Handle, sql : String) : Int64
    statement = Pointer(Void).null
    code = LibSQLite3Reference.prepare_v2(handle, sql, sql.bytesize, pointerof(statement), nil)
    raise "prepare failed with #{code}: #{sql}" unless code == 0
    count = drain(statement)
    LibSQLite3Reference.finalize(statement)
    count
  end

  record Workload, workload_name : String, engine : Proc(Int64), c_library : Proc(Int64)

  def self.workloads(path : String, lookups : Array(Int64)) : Array(Workload)
    [
      Workload.new("full table scan, 200,000 rows",
        -> {
          count = 0_i64
          database = Grant::SQLiteEngine::Database.open(path)
          database.each_row("items") { |row| row.values.each { |value| count += 1 unless value.nil? } }
          database.close
          count
        },
        -> {
          count = 0_i64
          with_c_database(path) { |handle| count = c_query(handle, "SELECT * FROM items") }
          count
        }),
      Workload.new("index scan, 200,000 entries",
        -> {
          count = 0_i64
          database = Grant::SQLiteEngine::Database.open(path)
          database.each_index_entry("items_by_label") { |entry| entry.each { |value| count += 1 unless value.nil? } }
          database.close
          count
        },
        -> {
          count = 0_i64
          with_c_database(path) { |handle| count = c_query(handle, "SELECT label, rowid FROM items INDEXED BY items_by_label ORDER BY label") }
          count
        }),
      Workload.new("rowid lookups, 20,000",
        -> {
          count = 0_i64
          database = Grant::SQLiteEngine::Database.open(path)
          lookups.each do |rowid|
            row = database.find_row("items", rowid)
            row.try &.values.each { |value| count += 1 unless value.nil? }
          end
          database.close
          count
        },
        -> {
          count = 0_i64
          with_c_database(path) do |handle|
            statement = Pointer(Void).null
            sql = "SELECT * FROM items WHERE rowid = ?"
            LibSQLite3Reference.prepare_v2(handle, sql, sql.bytesize, pointerof(statement), nil)
            lookups.each do |rowid|
              LibSQLite3Reference.bind_int64(statement, 1, rowid)
              count += drain(statement)
              LibSQLite3Reference.reset(statement)
            end
            LibSQLite3Reference.finalize(statement)
          end
          count
        }),
      Workload.new("open and read the schema, 300 times",
        -> {
          count = 0_i64
          OPENS.times do
            database = Grant::SQLiteEngine::Database.open(path)
            count += database.schema.list_of_entries.size
            database.close
          end
          count
        },
        -> {
          count = 0_i64
          OPENS.times do
            with_c_database(path) { |handle| count += c_query(handle, "SELECT type, name, tbl_name, rootpage, sql FROM sqlite_schema") // 4 }
          end
          count
        }),
    ]
  end

  def self.build_database(path : String) : Nil
    sql = <<-SQL
      CREATE TABLE items(id INTEGER PRIMARY KEY, label TEXT, amount INTEGER, score REAL, payload TEXT);
      WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v + 1 FROM n WHERE v < #{ROWS})
      INSERT INTO items SELECT v, 'label ' || (v * 7919 % #{ROWS}), v * 3 - #{ROWS}, v / 7.0, printf('%.*c', 20 + v % 80, 'p') FROM n;
      CREATE INDEX items_by_label ON items(label);
      SQL
    status = Process.run("sqlite3", [path], input: IO::Memory.new(sql), error: STDERR)
    raise "sqlite3 could not build #{path}" unless status.success?
  end

  def self.time(& : -> Int64) : {Float64, Int64}
    started = Time.instant
    result = yield
    {(Time.instant - started).total_seconds, result}
  end

  def self.describe_ratio(ratio : Float64) : String
    ratio >= 1.0 ? "#{ratio.round(2)}× as fast" : "#{(1.0 / ratio).round(2)}× slower"
  end

  def self.run(path : String, rounds : Int32) : Nil
    build_database(path) unless File.exists?(path)
    random = Random.new(20261122)
    lookups = Array(Int64).new(LOOKUPS) { random.rand(1_i64..ROWS.to_i64) }
    STDOUT.puts "C library: SQLite #{String.new(LibSQLite3Reference.libversion)} (#{String.new(LibSQLite3Reference.sourceid)})"
    STDOUT.puts "Rounds: #{rounds}, order alternating (engine first on even rounds)"
    workloads(path, lookups).each do |workload|
      # One warm-up of each, then the measured rounds.
      engine_count = workload.engine.call
      c_count = workload.c_library.call
      raise "#{workload.workload_name}: engine counted #{engine_count} values, C #{c_count}" unless engine_count == c_count
      ratios = [] of Float64
      engine_times = [] of Float64
      c_times = [] of Float64
      rounds.times do |round|
        if round.even?
          engine_seconds, _ = time { workload.engine.call }
          c_seconds, _ = time { workload.c_library.call }
        else
          c_seconds, _ = time { workload.c_library.call }
          engine_seconds, _ = time { workload.engine.call }
        end
        engine_times << engine_seconds
        c_times << c_seconds
        ratios << c_seconds / engine_seconds
      end
      ratios.sort!
      median = (ratios[(rounds - 1) // 2] + ratios[rounds // 2]) / 2
      low = ratios[rounds >= 10 ? 1 : 0]
      high = ratios[rounds >= 10 ? rounds - 2 : rounds - 1]
      STDOUT.puts "#{workload.workload_name}: engine #{(engine_times.sort[rounds // 2] * 1000).round(2)} ms, " \
                  "C #{(c_times.sort[rounds // 2] * 1000).round(2)} ms median; " \
                  "#{describe_ratio(median)} (rounds' range #{describe_ratio(low)} to #{describe_ratio(high)}); #{engine_count} values each"
    end
  end
end

path = ARGV[0]? || File.join(Dir.tempdir, "grant_sqlite_engine_bench.db")
rounds = (ARGV[1]? || "10").to_i
SQLiteEngineReadBench.run(path, rounds)
