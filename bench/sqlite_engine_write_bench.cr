# bench/sqlite_engine_write_bench.cr
#
# Interleaved A/B of Grant's pure-Crystal SQLite writer (milestone G2)
# against the C library, both in journal_mode=DELETE with synchronous=FULL:
# the two alternate for ROUNDS rounds (order flipped every round), and each
# workload reports the median ratio as "N× as fast" or "N× slower" with the
# range of the middle rounds.
#
#   crystal-alpha build --release bench/sqlite_engine_write_bench.cr -o sqlite_engine_write_bench
#   ./sqlite_engine_write_bench [directory] [rounds]
#
# Workloads, each on its own copy of the files so neither side sees the
# other's work: 200,000 inserts in one transaction into an empty table;
# 1,000 inserts each in its own transaction; 10,000 updates by rowid and
# 10,000 deletes by rowid, each in one transaction, on a 200,000-row table
# the sqlite3 tool built. The C side runs prepared statements with bound
# values; the engine side calls its typed write API (no SQL).
#
# Only this benchmark links libsqlite3; the engine itself links no native
# library.
require "file_utils"
require "../src/grant/sqlite_engine"

@[Link("sqlite3")]
lib LibSQLite3Writer
  alias Handle = Void*
  alias Statement = Void*

  fun open_v2 = sqlite3_open_v2(filename : UInt8*, db : Handle*, flags : Int32, vfs : UInt8*) : Int32
  fun close_v2 = sqlite3_close_v2(db : Handle) : Int32
  fun exec = sqlite3_exec(db : Handle, sql : UInt8*, callback : Void*, argument : Void*, error : UInt8**) : Int32
  fun prepare_v2 = sqlite3_prepare_v2(db : Handle, sql : UInt8*, bytes : Int32, statement : Statement*, tail : UInt8**) : Int32
  fun step = sqlite3_step(statement : Statement) : Int32
  fun reset = sqlite3_reset(statement : Statement) : Int32
  fun finalize = sqlite3_finalize(statement : Statement) : Int32
  fun bind_int64 = sqlite3_bind_int64(statement : Statement, index : Int32, value : Int64) : Int32
  fun bind_double = sqlite3_bind_double(statement : Statement, index : Int32, value : Float64) : Int32
  fun bind_text = sqlite3_bind_text(statement : Statement, index : Int32, text : UInt8*, bytes : Int32, destructor : Void*) : Int32
  fun bind_null = sqlite3_bind_null(statement : Statement, index : Int32) : Int32
  fun libversion = sqlite3_libversion : UInt8*
  fun sourceid = sqlite3_sourceid : UInt8*
end

module SQLiteEngineWriteBench
  OPEN_READ_WRITE_CREATE = 6
  DONE                   = 101
  ROWS                   = 200_000
  SINGLE_INSERTS         = 1_000
  CHANGES                = 10_000
  TABLE_SQL              = "CREATE TABLE items(id INTEGER PRIMARY KEY, label TEXT, amount INTEGER, score REAL, payload TEXT)"
  # SQLITE_TRANSIENT: the library copies bound text.
  TRANSIENT = Pointer(Void).new(-1_i64.to_u64!)

  alias Value = Grant::SQLiteEngine::Value

  def self.row(number : Int64) : Array(Value)
    [number, "label #{number * 7919 % ROWS}", number * 3 - ROWS, number / 7.0, "p" * (20 + number % 80)] of Value
  end

  def self.c_open(path : String, & : LibSQLite3Writer::Handle ->) : Nil
    handle = Pointer(Void).null
    code = LibSQLite3Writer.open_v2(path, pointerof(handle), OPEN_READ_WRITE_CREATE, nil)
    raise "sqlite3_open_v2 failed with #{code}" unless code == 0
    c_exec(handle, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
    yield handle
    LibSQLite3Writer.close_v2(handle)
  end

  def self.c_exec(handle : LibSQLite3Writer::Handle, sql : String) : Nil
    code = LibSQLite3Writer.exec(handle, sql, nil, nil, nil)
    raise "sqlite3_exec failed with #{code}: #{sql}" unless code == 0
  end

  def self.c_prepare(handle : LibSQLite3Writer::Handle, sql : String) : LibSQLite3Writer::Statement
    statement = Pointer(Void).null
    code = LibSQLite3Writer.prepare_v2(handle, sql, sql.bytesize, pointerof(statement), nil)
    raise "prepare failed with #{code}: #{sql}" unless code == 0
    statement
  end

  def self.c_bind_row(statement : LibSQLite3Writer::Statement, values : Array(Value), first : Int32) : Nil
    values.each_with_index do |value, position|
      index = first + position
      case value
      when Int64   then LibSQLite3Writer.bind_int64(statement, index, value)
      when Float64 then LibSQLite3Writer.bind_double(statement, index, value)
      when String  then LibSQLite3Writer.bind_text(statement, index, value, value.bytesize, TRANSIENT)
      else              LibSQLite3Writer.bind_null(statement, index)
      end
    end
  end

  def self.c_run(statement : LibSQLite3Writer::Statement) : Nil
    code = LibSQLite3Writer.step(statement)
    raise "sqlite3_step returned #{code}" unless code == DONE
    LibSQLite3Writer.reset(statement)
  end

  def self.engine_open(path : String) : Grant::SQLiteEngine::Database
    Grant::SQLiteEngine::Database.open(path, read_write: true)
  end

  # Fresh files for one run: an empty table, or a copy of the 200,000-row
  # base database.
  def self.prepare(directory : String, name : String, base : String?) : String
    path = File.join(directory, name)
    File.delete?(path)
    File.delete?("#{path}-journal")
    if base
      FileUtils.cp(base, path)
    else
      c_open(path) { |handle| c_exec(handle, TABLE_SQL) }
    end
    path
  end

  record Workload, workload_name : String, base : Bool, engine : Proc(String, Nil), c_library : Proc(String, Nil)

  def self.workloads(updates : Array(Int64), deletes : Array(Int64)) : Array(Workload)
    [
      Workload.new("bulk insert, 200,000 rows in one transaction", false,
        ->(path : String) {
          database = engine_open(path)
          database.transaction { |writer| (1_i64..ROWS).each { |number| writer.insert("items", nil, row(number)) } }
          database.close
        },
        ->(path : String) {
          c_open(path) do |handle|
            statement = c_prepare(handle, "INSERT INTO items VALUES (?, ?, ?, ?, ?)")
            c_exec(handle, "BEGIN")
            (1_i64..ROWS).each do |number|
              c_bind_row(statement, row(number), 1)
              c_run(statement)
            end
            c_exec(handle, "COMMIT")
            LibSQLite3Writer.finalize(statement)
          end
        }),
      Workload.new("single-row insert transactions, 1,000", false,
        ->(path : String) {
          database = engine_open(path)
          (1_i64..SINGLE_INSERTS).each { |number| database.insert("items", nil, row(number)) }
          database.close
        },
        ->(path : String) {
          c_open(path) do |handle|
            statement = c_prepare(handle, "INSERT INTO items VALUES (?, ?, ?, ?, ?)")
            (1_i64..SINGLE_INSERTS).each do |number|
              c_bind_row(statement, row(number), 1)
              c_run(statement)
            end
            LibSQLite3Writer.finalize(statement)
          end
        }),
      Workload.new("update by rowid, 10,000 in one transaction", true,
        ->(path : String) {
          database = engine_open(path)
          database.transaction do |writer|
            updates.each { |rowid| writer.update("items", rowid, [rowid, "changed #{rowid}", rowid, rowid / 3.0, "u" * 30] of Value) }
          end
          database.close
        },
        ->(path : String) {
          c_open(path) do |handle|
            statement = c_prepare(handle, "UPDATE items SET id = ?, label = ?, amount = ?, score = ?, payload = ? WHERE rowid = ?")
            c_exec(handle, "BEGIN")
            updates.each do |rowid|
              c_bind_row(statement, [rowid, "changed #{rowid}", rowid, rowid / 3.0, "u" * 30] of Value, 1)
              LibSQLite3Writer.bind_int64(statement, 6, rowid)
              c_run(statement)
            end
            c_exec(handle, "COMMIT")
            LibSQLite3Writer.finalize(statement)
          end
        }),
      Workload.new("delete by rowid, 10,000 in one transaction", true,
        ->(path : String) {
          database = engine_open(path)
          database.transaction { |writer| deletes.each { |rowid| writer.delete("items", rowid) } }
          database.close
        },
        ->(path : String) {
          c_open(path) do |handle|
            statement = c_prepare(handle, "DELETE FROM items WHERE rowid = ?")
            c_exec(handle, "BEGIN")
            deletes.each do |rowid|
              LibSQLite3Writer.bind_int64(statement, 1, rowid)
              c_run(statement)
            end
            c_exec(handle, "COMMIT")
            LibSQLite3Writer.finalize(statement)
          end
        }),
    ]
  end

  def self.build_base(path : String) : Nil
    return if File.exists?(path)
    c_open(path) do |handle|
      c_exec(handle, TABLE_SQL)
      statement = c_prepare(handle, "INSERT INTO items VALUES (?, ?, ?, ?, ?)")
      c_exec(handle, "BEGIN")
      (1_i64..ROWS).each do |number|
        c_bind_row(statement, row(number), 1)
        c_run(statement)
      end
      c_exec(handle, "COMMIT")
      LibSQLite3Writer.finalize(statement)
    end
  end

  def self.time(& : -> Nil) : Float64
    started = Time.instant
    yield
    (Time.instant - started).total_seconds
  end

  def self.describe_ratio(ratio : Float64) : String
    ratio >= 1.0 ? "#{ratio.round(2)}× as fast" : "#{(1.0 / ratio).round(2)}× slower"
  end

  # Both files hold the same rows afterward (read back by the engine).
  def self.check_same(engine_path : String, c_path : String, workload : String) : Nil
    engine_rows = Grant::SQLiteEngine::Database.open(engine_path).rows("items")
    c_rows = Grant::SQLiteEngine::Database.open(c_path).rows("items")
    raise "#{workload}: engine and C files differ" unless engine_rows == c_rows
  end

  def self.run(directory : String, rounds : Int32) : Nil
    Dir.mkdir_p(directory)
    base = File.join(directory, "base.db")
    build_base(base)
    random = Random.new(20261123)
    updates = Array(Int64).new(CHANGES) { random.rand(1_i64..ROWS.to_i64) }
    deletes = (1_i64..ROWS.to_i64).to_a.shuffle(random).first(CHANGES)
    STDOUT.puts "C library: SQLite #{String.new(LibSQLite3Writer.libversion)} (#{String.new(LibSQLite3Writer.sourceid)})"
    STDOUT.puts "Rounds: #{rounds}, order alternating (engine first on even rounds); journal_mode=DELETE, synchronous=FULL on both"
    workloads(updates, deletes).each do |workload|
      source = workload.base ? base : nil
      engine_path = prepare(directory, "engine.db", source)
      c_path = prepare(directory, "c.db", source)
      workload.engine.call(engine_path)
      workload.c_library.call(c_path)
      check_same(engine_path, c_path, workload.workload_name)
      ratios = [] of Float64
      engine_times = [] of Float64
      c_times = [] of Float64
      rounds.times do |round|
        engine_seconds = 0.0
        c_seconds = 0.0
        if round.even?
          engine_path = prepare(directory, "engine.db", source)
          engine_seconds = time { workload.engine.call(engine_path) }
          c_path = prepare(directory, "c.db", source)
          c_seconds = time { workload.c_library.call(c_path) }
        else
          c_path = prepare(directory, "c.db", source)
          c_seconds = time { workload.c_library.call(c_path) }
          engine_path = prepare(directory, "engine.db", source)
          engine_seconds = time { workload.engine.call(engine_path) }
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
                  "#{describe_ratio(median)} (rounds' range #{describe_ratio(low)} to #{describe_ratio(high)})"
    end
  end
end

directory = ARGV[0]? || File.join(Dir.tempdir, "grant_sqlite_engine_write_bench")
rounds = (ARGV[1]? || "10").to_i
SQLiteEngineWriteBench.run(directory, rounds)
