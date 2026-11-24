# Concurrency soak for Grant's SQLite engine in WAL mode: engine processes
# and C SQLite (libsqlite3) processes read and write one database file at
# the same time, with random transactions, snapshot reads, checkpoints of
# every mode and reconnects, while a `sqlite3` process runs integrity_check
# beside them.
#
#   crystal-alpha build --release scripts/sqlite_engine_wal_soak.cr -o soak
#   ./soak run DIRECTORY SECONDS ENGINE_WORKERS C_WORKERS SEED
#
# Every writer owns its rows in `ledger` and its row in `totals` (its row
# count and the sum of its sequence numbers), and logs each commit the
# engine reported. Readers check, inside one snapshot, that every writer's
# totals match its rows, and that a snapshot reads the same twice. At the
# end every logged commit must be in the file (no lost commits), no row may
# be there that no commit logged, and integrity_check must say ok.
require "file_utils"
require "json"
require "../src/grant/drivers/sqlite3/sqlite3/type"
require "../src/grant/drivers/sqlite3/sqlite3/flags"
require "../src/grant/drivers/sqlite3/sqlite3/engine"
require "../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../src/grant/drivers/sqlite3/libsqlite3"

alias SoakEngine = Grant::SQLite3::Engine
alias SoakValue = SoakEngine::Value

SCHEMA = "PRAGMA journal_mode=WAL; " \
         "CREATE TABLE ledger(id INTEGER PRIMARY KEY, writer TEXT NOT NULL, seq INTEGER NOT NULL, payload BLOB, UNIQUE(writer, seq)); " \
         "CREATE TABLE totals(writer TEXT PRIMARY KEY, row_count INTEGER NOT NULL, seq_sum INTEGER NOT NULL);"

BUSY_CODES = {5, 6, 17}

# One connection, through either engine, with the calls the workers make.
class SoakConnection
  getter database : SoakEngine::Database

  def initialize(@engine : SoakEngine, @path : String, @synchronous : String)
    @database = open_database
  end

  private def open_database : SoakEngine::Database
    code, database = @engine.open(@path)
    raise "open failed (#{code}): #{database.error_message}" unless code == SoakEngine::OK_CODE
    database.exec("PRAGMA busy_timeout=2000; PRAGMA synchronous=#{@synchronous};")
    database
  end

  def reopen : Nil
    @database.close
    @database = open_database
  end

  def close : Nil
    @database.close
  end

  # Runs *sql*; returns the result code (DONE on success) and the rows.
  def query(sql : String, list_of_parameters : Array(SoakValue) = [] of SoakValue) : {Int32, Array(Array(SoakValue))}
    code, statement = @database.prepare(sql)
    return {code, [] of Array(SoakValue)} unless code == SoakEngine::OK_CODE
    list_of_rows = [] of Array(SoakValue)
    begin
      list_of_parameters.each_with_index do |value, index|
        case value
        when Int64  then statement.bind_int64(index + 1, value)
        when String then statement.bind_text(index + 1, value)
        when Bytes  then statement.bind_blob(index + 1, value)
        else             statement.bind_null(index + 1)
        end
      end
      loop do
        step = statement.step
        return {step, list_of_rows} unless step == SoakEngine::ROW_CODE || step == SoakEngine::DONE_CODE
        break if step == SoakEngine::DONE_CODE
        list_of_rows << (0...statement.column_count).map do |column|
          case statement.column_type(column)
          when Grant::SQLite3::Type::INTEGER then statement.column_int64(column).as(SoakValue)
          when Grant::SQLite3::Type::NULL    then nil.as(SoakValue)
          when Grant::SQLite3::Type::BLOB    then statement.column_blob(column).dup.as(SoakValue)
          else                                    statement.column_text(column).as(SoakValue)
          end
        end
      end
    ensure
      statement.finalize_statement
    end
    {SoakEngine::DONE_CODE, list_of_rows}
  end
end

# One worker process: random transactions for *seconds*, its commits
# appended to *log_path* as JSON lines.
class SoakWorker
  @list_of_own = [] of Int64
  @next_seq = 1_i64
  @counts = Hash(String, Int64).new(0_i64)

  def initialize(@name : String, engine_name : String, path : String, @seconds : Int32, seed : Int64, @log_path : String)
    @random = Random.new(seed)
    synchronous = @random.rand(2) == 0 ? "NORMAL" : "FULL"
    engine = engine_name == "grant" ? SoakEngine::GrantEngine.new.as(SoakEngine) : SoakEngine::LibSQLite3Engine.new.as(SoakEngine)
    @connection = SoakConnection.new(engine, path, synchronous)
    @log = File.open(@log_path, "w")
  end

  def run : Nil
    deadline = Time.instant + @seconds.seconds
    while Time.instant < deadline
      choice = @random.rand(100)
      if choice < 55
        write_transaction
      elsif choice < 85
        read_transaction(hold: choice >= 80)
      elsif choice < 92
        checkpoint
      elsif choice < 94
        @connection.reopen
        @counts["reconnects"] += 1
      else
        sleep (@random.rand(20) + 1).milliseconds
      end
    end
    @connection.close
    @log.puts({"summary" => @counts}.to_json)
    @log.close
  end

  private def ok?(result : {Int32, Array(Array(SoakValue))}) : Bool
    result[0] == SoakEngine::DONE_CODE
  end

  private def note_failure(step : String, code : Int32) : Nil
    if BUSY_CODES.includes?(code)
      @counts["busy #{step}"] += 1
    else
      @counts["error #{step} #{code}: #{@connection.database.error_message}"] += 1
    end
  end

  private def write_transaction : Nil
    begin_code = @connection.query(@random.rand(2) == 0 ? "BEGIN IMMEDIATE" : "BEGIN")[0]
    unless begin_code == SoakEngine::DONE_CODE
      note_failure("begin", begin_code)
      return
    end
    added = [] of Int64
    removed = [] of Int64
    own = @list_of_own.dup
    failed = nil
    (@random.rand(4) + 1).times do
      seq = @next_seq
      @next_seq += 1
      payload = Bytes.new(@random.rand(3_000)) { |index| (index &* 31 &+ seq).to_u8! }
      result = @connection.query("INSERT INTO ledger(writer, seq, payload) VALUES (?, ?, ?)", [@name, seq, payload] of SoakValue)
      unless ok?(result)
        failed = {"insert", result[0]}
        break
      end
      added << seq
      own << seq
    end
    if failed.nil? && !own.empty? && @random.rand(3) == 0
      seq = own.sample(@random)
      result = @connection.query("UPDATE ledger SET payload = ? WHERE writer = ? AND seq = ?", [Bytes.new(@random.rand(500)), @name, seq] of SoakValue)
      failed = {"update", result[0]} unless ok?(result)
    end
    if failed.nil? && own.size > 4 && @random.rand(2) == 0
      seq = own.sample(@random)
      result = @connection.query("DELETE FROM ledger WHERE writer = ? AND seq = ?", [@name, seq] of SoakValue)
      if ok?(result)
        removed << seq
        own.delete(seq)
      else
        failed = {"delete", result[0]}
      end
    end
    if failed.nil?
      result = @connection.query("INSERT OR REPLACE INTO totals(writer, row_count, seq_sum) VALUES (?, ?, ?)",
        [@name, own.size.to_i64, own.sum(0_i64)] of SoakValue)
      failed = {"totals", result[0]} unless ok?(result)
    end
    if failed.nil?
      commit = @connection.query("COMMIT")[0]
      if commit == SoakEngine::DONE_CODE
        @list_of_own = own
        @counts["commits"] += 1
        @log.puts({"added" => added, "removed" => removed}.to_json)
        @log.flush
        return
      end
      failed = {"commit", commit}
    end
    step, code = failed
    note_failure(step, code)
    @connection.query("ROLLBACK")
  end

  # Every writer's totals row matches its rows; a held snapshot reads the
  # same twice.
  private def read_transaction(hold : Bool) : Nil
    code = @connection.query("BEGIN")[0]
    return note_failure("begin read", code) unless code == SoakEngine::DONE_CODE
    first = snapshot_problem
    if first.is_a?(String)
      @counts["VIOLATION #{first}"] += 1
    elsif first.nil?
      @counts["busy read"] += 1
    elsif hold
      sleep (@random.rand(50) + 10).milliseconds
      second = snapshot_problem
      if second.is_a?(Array) && second != first
        @counts["VIOLATION a snapshot changed while held"] += 1
      end
    end
    @counts["reads"] += 1
    @connection.query("COMMIT")
  end

  # The rows of the check, a message naming a broken invariant, or nil
  # when the read was busy.
  private def snapshot_problem : Array(Array(SoakValue)) | String?
    code, list_of_groups = @connection.query("SELECT writer, count(*), sum(seq) FROM ledger GROUP BY writer ORDER BY writer")
    return unless code == SoakEngine::DONE_CODE
    code, list_of_totals = @connection.query("SELECT writer, row_count, seq_sum FROM totals WHERE row_count > 0 ORDER BY writer")
    return unless code == SoakEngine::DONE_CODE
    return "totals #{list_of_totals.first(3)} differ from rows #{list_of_groups.first(3)}" unless list_of_groups == list_of_totals
    list_of_groups
  end

  private def checkpoint : Nil
    mode = %w[PASSIVE FULL RESTART TRUNCATE].sample(@random)
    code, list_of_rows = @connection.query("PRAGMA wal_checkpoint(#{mode})")
    return note_failure("checkpoint", code) unless code == SoakEngine::DONE_CODE
    busy = list_of_rows.first?.try(&.first?) == 1_i64
    @counts[busy ? "checkpoint #{mode.downcase} busy" : "checkpoint #{mode.downcase}"] += 1
  end
end

# Starts the workers, runs sqlite3's integrity_check every few seconds
# while they work, then checks every commit they logged.
class SoakRun
  struct LogLine
    include JSON::Serializable
    @[JSON::Field(key: "added")]
    getter list_of_added : Array(Int64)? = nil
    @[JSON::Field(key: "removed")]
    getter list_of_removed : Array(Int64)? = nil
    @[JSON::Field(key: "summary")]
    getter counts_by_name : Hash(String, Int64)? = nil
  end

  def initialize(@directory : String, @seconds : Int32, @engine_workers : Int32, @c_workers : Int32, @seed : Int64)
  end

  def run : Int32
    FileUtils.rm_rf(@directory)
    Dir.mkdir_p(@directory)
    path = File.join(@directory, "soak.db")
    status = Process.run("sqlite3", [path, SCHEMA], output: Process::Redirect::Close, error: Process::Redirect::Inherit)
    raise "schema failed" unless status.success?
    list_of_workers = [] of {String, String, Process}
    (@engine_workers + @c_workers).times do |index|
      engine = index < @engine_workers ? "grant" : "c"
      name = "#{engine}#{index}"
      log = File.join(@directory, "#{name}.log")
      process = Process.new(Process.executable_path || PROGRAM_NAME,
        ["worker", name, engine, path, @seconds.to_s, (@seed + index).to_s, log],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      list_of_workers << {name, log, process}
    end
    checks = 0
    list_of_integrity_failures = [] of String
    while list_of_workers.any? { |worker| !worker[2].terminated? }
      sleep 3.seconds
      output = IO::Memory.new
      Process.run("sqlite3", ["-cmd", ".timeout 5000", path, "PRAGMA integrity_check;"], output: output, error: output)
      checks += 1
      list_of_integrity_failures << output.to_s.strip[0, 300] unless output.to_s == "ok\n"
    end
    failed_workers = list_of_workers.count { |worker| !worker[2].wait.success? }
    verify(path, list_of_workers, checks, list_of_integrity_failures, failed_workers)
  end

  private def verify(path : String, list_of_workers : Array({String, String, Process}), checks : Int32,
                     list_of_integrity_failures : Array(String), failed_workers : Int32) : Int32
    reader = SoakConnection.new(SoakEngine::LibSQLite3Engine.new, path, "FULL")
    problems = [] of String
    totals = Hash(String, Int64).new(0_i64)
    commits_by_engine = Hash(String, Int64).new(0_i64)
    lost = 0
    phantom = 0
    list_of_workers.each do |name, log, _process|
      expected = Set(Int64).new
      File.each_line(log) do |line|
        entry = LogLine.from_json(line)
        if summary = entry.counts_by_name
          summary.each { |key, count| totals["#{name.starts_with?("grant") ? "engine" : "C"}: #{key}"] += count }
          next
        end
        commits_by_engine[name.starts_with?("grant") ? "engine" : "C"] += 1
        (entry.list_of_added || [] of Int64).each { |seq| expected << seq }
        (entry.list_of_removed || [] of Int64).each { |seq| expected.delete(seq) }
      end
      _code, list_of_rows = reader.query("SELECT seq FROM ledger WHERE writer = ?", [name] of SoakValue)
      actual = list_of_rows.map(&.first.as(Int64)).to_set
      lost += (expected - actual).size
      phantom += (actual - expected).size
      _code, list_of_totals = reader.query("SELECT row_count, seq_sum FROM totals WHERE writer = ?", [name] of SoakValue)
      unless expected.empty? && list_of_totals.empty?
        recorded = list_of_totals.first?
        problems << "#{name}: totals #{recorded} for #{actual.size} rows" unless recorded == [actual.size.to_i64, actual.sum(0_i64)] of SoakValue
      end
    end
    _code, integrity = reader.query("PRAGMA integrity_check")
    reader.close
    final_check = IO::Memory.new
    Process.run("sqlite3", [path, "PRAGMA integrity_check;"], output: final_check, error: final_check)
    violations = totals.select { |key, _count| key.includes?("VIOLATION") || key.includes?(": error ") }
    summary = {
      "seconds"                      => @seconds,
      "engine workers"               => @engine_workers,
      "C workers"                    => @c_workers,
      "seed"                         => @seed,
      "engine commits"               => commits_by_engine["engine"],
      "C commits"                    => commits_by_engine["C"],
      "lost commits (rows)"          => lost,
      "rows no commit logged"        => phantom,
      "sqlite3 integrity checks run" => checks,
      "sqlite3 integrity failures"   => list_of_integrity_failures.size,
      "final integrity (C library)"  => integrity.first?.try(&.first?).to_s,
      "final integrity (sqlite3)"    => final_check.to_s.strip,
      "workers failed"               => failed_workers,
      "invariant violations, errors" => violations.to_s,
      "totals problems"              => problems.first(5).to_s,
      "counts"                       => totals.to_s,
    }
    File.write(File.join(@directory, "summary.json"), summary.to_pretty_json)
    puts summary.to_pretty_json
    clean = lost == 0 && phantom == 0 && list_of_integrity_failures.empty? && failed_workers == 0 && violations.empty? &&
            problems.empty? && final_check.to_s == "ok\n"
    clean ? 0 : 1
  end
end

case ARGV[0]?
when "worker"
  SoakWorker.new(ARGV[1], ARGV[2], ARGV[3], ARGV[4].to_i, ARGV[5].to_i64, ARGV[6]).run
when "run"
  exit SoakRun.new(ARGV[1], ARGV[2].to_i, ARGV[3].to_i, ARGV[4].to_i, ARGV[5].to_i64).run
else
  abort "usage: run DIRECTORY SECONDS ENGINE_WORKERS C_WORKERS SEED"
end
