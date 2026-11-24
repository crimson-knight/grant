# Long-running durability soak for Grant's SQLite engine: engine and C
# SQLite (libsqlite3) worker processes write and read one WAL database at
# the same time, in cycles, while the supervisor kills workers mid-work
# (SIGKILL of one worker, and of all of them at once) and restarts them.
# After every cycle, every acknowledged commit must be in the database and
# `PRAGMA integrity_check` in the stock /usr/bin/sqlite3 must say `ok`.
#
# The soak survives its own interruption (a power cut, a reboot, the
# supervisor being stopped): progress is written durably (F_FULLFSYNC on
# macOS) after every cycle and in a heartbeat every minute, and `run` on an
# existing soak folder first verifies the database against the ledger of
# acknowledged commits, records the interruption, and continues from the
# soak time already run.
#
#   crystal-alpha build --release scripts/sqlite_engine_durability_soak.cr -o soak
#   ./soak run DIRECTORY [--hours 72] [--cycle-minutes 10] [--engine-workers 4]
#                        [--c-workers 2] [--seed N] [--resume-command TEXT]
#   ./soak status DIRECTORY
#   ./soak check DIRECTORY      (verify a stopped soak against its snapshot)
#
# Durability rules. Every worker writes an intent line (the rows it is about
# to add and remove) to its ledger and syncs it before COMMIT, and an
# acknowledgment line, synced, after COMMIT returns. Even-numbered workers
# are durable (`synchronous=FULL`, `fullfsync=ON`): every commit they
# acknowledged must survive anything, a power cut included. Odd-numbered
# workers run `synchronous=NORMAL`, which SQLite documents as durable across
# a process crash but not a power cut: after a process kill every
# acknowledged commit must be present; after a power cut their rows must
# equal the state after one of their acknowledged commits (a prefix), and the
# acknowledged commits after it are counted as rolled back by the power cut,
# separately from lost commits.
require "file_utils"
require "json"
require "../src/grant/drivers/sqlite3/sqlite3/type"
require "../src/grant/drivers/sqlite3/sqlite3/flags"
require "../src/grant/drivers/sqlite3/sqlite3/engine"
require "../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../src/grant/drivers/sqlite3/libsqlite3"

alias SoakEngine = Grant::SQLite3::Engine
alias SoakValue = SoakEngine::Value

SQLITE3_TOOL = "/usr/bin/sqlite3"
SCHEMA       = "PRAGMA journal_mode=WAL; " \
               "CREATE TABLE ledger(id INTEGER PRIMARY KEY, writer TEXT NOT NULL, seq INTEGER NOT NULL, payload BLOB, UNIQUE(writer, seq)); " \
               "CREATE TABLE totals(writer TEXT PRIMARY KEY, row_count INTEGER NOT NULL, seq_sum INTEGER NOT NULL);"
BUSY_CODES      = {5, 6, 17}
ROWS_PER_WRITER = 1_500

# Writes that must reach stable storage: F_FULLFSYNC on macOS (plain fsync
# leaves data in the drive's cache), fsync elsewhere.
module DurableFile
  F_FULLFSYNC = 51

  def self.sync(file : File) : Nil
    file.flush
    {% if flag?(:darwin) %}
      return if LibC.fcntl(file.fd, F_FULLFSYNC) == 0
    {% end %}
    file.fsync
  end

  def self.sync_path(path : String) : Nil
    return unless File.exists?(path)
    File.open(path, "r") { |file| sync(file) }
  end

  # Replaces *path* with *content* so a power cut leaves the old file or the
  # new one, never a mix.
  def self.write(path : String, content : String) : Nil
    temporary = "#{path}.tmp"
    File.open(temporary, "w") do |file|
      file << content
      sync(file)
    end
    File.rename(temporary, path)
    File.open(File.dirname(path), "r") { |directory| directory.fsync rescue nil }
  end
end

# One connection, through either engine.
class SoakConnection
  getter database : SoakEngine::Database

  def initialize(@engine : SoakEngine, @path : String, @pragmas : String)
    @database = open_database
  end

  private def open_database : SoakEngine::Database
    code, database = @engine.open(@path)
    raise "open failed (#{code}): #{database.error_message}" unless code == SoakEngine::OK_CODE
    code = database.exec(@pragmas)
    raise "pragmas failed (#{code}): #{database.error_message}" unless code == SoakEngine::OK_CODE
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

# One line of a worker's ledger: an intent (`I`, with the sequence numbers
# the transaction adds and removes), its acknowledgment (`A`), its failure
# (`X`), the outcome of an intent a killed worker left open, decided from
# the database when the worker restarts (`R` committed, `N` not), or a read
# invariant violation (`V`).
struct LedgerLine
  include JSON::Serializable

  @[JSON::Field(key: "k")]
  getter kind_of_entry : String
  @[JSON::Field(key: "t")]
  getter transaction_number : Int64 = 0_i64
  @[JSON::Field(key: "a")]
  getter list_of_added : Array(Int64) = [] of Int64
  @[JSON::Field(key: "r")]
  getter list_of_removed : Array(Int64) = [] of Int64
  @[JSON::Field(key: "m")]
  getter message : String = ""

  def initialize(@kind_of_entry, @transaction_number = 0_i64, @list_of_added = [] of Int64, @list_of_removed = [] of Int64, @message = "")
  end
end

# A writer's rows at the last verified cycle boundary.
struct WriterSnapshot
  include JSON::Serializable

  getter list_of_seqs : Array(Int64)
  getter next_seq : Int64

  def initialize(@list_of_seqs, @next_seq)
  end
end

struct Interruption
  include JSON::Serializable

  getter kind_of_interruption : String
  getter last_heartbeat_at : String
  getter resumed_at : String
  getter cycle : Int64
  getter cycle_seconds_run : Float64
  getter verification : String

  def initialize(@kind_of_interruption, @last_heartbeat_at, @resumed_at, @cycle, @cycle_seconds_run, @verification)
  end
end

struct Heartbeat
  include JSON::Serializable

  getter cycle : Int64
  getter cycle_seconds_run : Float64
  getter written_at : String

  def initialize(@cycle, @cycle_seconds_run, @written_at)
  end
end

# Everything the soak must not lose; written durably after every cycle.
class SoakState
  include JSON::Serializable

  property target_seconds : Float64
  property cycle_seconds : Float64
  property engine_workers : Int32
  property c_workers : Int32
  property seed : Int64
  property resume_command : String
  property started_at : String
  property soak_seconds_run : Float64 = 0.0
  property cycle : Int64 = 0_i64
  property cycles_verified : Int64 = 0_i64
  property? cycle_in_progress : Bool = false
  property boot_time : Int64 = 0_i64
  property outcome : String = "running"
  property list_of_failures : Array(String) = [] of String
  property list_of_interruptions : Array(Interruption) = [] of Interruption
  property snapshots_by_writer : Hash(String, WriterSnapshot) = {} of String => WriterSnapshot
  property counts_by_name : Hash(String, Int64) = {} of String => Int64
  property list_of_hourly_lines : Array(String) = [] of String
  property last_verified_at : String = ""

  def initialize(@target_seconds, @cycle_seconds, @engine_workers, @c_workers, @seed, @resume_command, @started_at)
  end

  def list_of_writer_names : Array(String)
    (0...engine_workers).map { |index| "g#{index}" } + (0...c_workers).map { |index| "c#{index}" }
  end

  def add(key : String, amount : Int64) : Nil
    counts_by_name[key] = counts_by_name.fetch(key, 0_i64) + amount
  end
end

def now_text : String
  Time.utc.to_rfc3339
end

def durable_writer?(name : String) : Bool
  name[1..].to_i.even?
end

def engine_for(name : String) : SoakEngine
  name.starts_with?("g") ? SoakEngine::GrantEngine.new.as(SoakEngine) : SoakEngine::LibSQLite3Engine.new.as(SoakEngine)
end

def boot_time : Int64
  output = `sysctl -n kern.boottime`
  if match = output.match(/sec = (\d+)/)
    match[1].to_i64
  else
    File.read("/proc/stat").lines.find(&.starts_with?("btime")).try(&.split[1].to_i64) || 0_i64
  end
rescue
  0_i64
end

# Reads a ledger, ignoring a last line a kill cut short.
def read_ledger(path : String) : Array(LedgerLine)
  return [] of LedgerLine unless File.exists?(path)
  list_of_lines = File.read_lines(path)
  list_of_entries = [] of LedgerLine
  list_of_lines.each_with_index do |line, index|
    next if line.empty?
    begin
      list_of_entries << LedgerLine.from_json(line)
    rescue error : JSON::ParseException
      raise "ledger #{path} line #{index + 1} is damaged: #{line[0, 80].inspect}" unless index == list_of_lines.size - 1
    end
  end
  list_of_entries
end

# The writer's state after each acknowledged commit, and the intent left
# open at the end, if any.
struct LedgerReplay
  getter list_of_states : Array(Set(Int64))
  getter open_intent : LedgerLine?
  getter list_of_violations : Array(String)
  getter highest_seq : Int64

  def initialize(start : Set(Int64), list_of_entries : Array(LedgerLine), next_seq : Int64)
    @list_of_states = [start]
    @list_of_violations = [] of String
    @highest_seq = next_seq - 1
    pending = nil
    list_of_entries.each do |entry|
      case entry.kind_of_entry
      when "I"
        pending = entry
        entry.list_of_added.each { |seq| @highest_seq = seq if seq > @highest_seq }
      when "A", "R"
        if intent = pending
          state = @list_of_states.last.dup
          intent.list_of_added.each { |seq| state << seq }
          intent.list_of_removed.each { |seq| state.delete(seq) }
          @list_of_states << state
        end
        pending = nil
      when "X", "N"
        pending = nil
      when "V"
        @list_of_violations << entry.message
      end
    end
    @open_intent = pending
  end

  def final_state : Set(Int64)
    @list_of_states.last
  end

  def state_with_open_intent : Set(Int64)?
    intent = @open_intent
    return unless intent
    state = final_state.dup
    intent.list_of_added.each { |seq| state << seq }
    intent.list_of_removed.each { |seq| state.delete(seq) }
    state
  end
end

# One worker process: random transactions until the stop file appears or it
# is killed.
class SoakWorker
  @own = Set(Int64).new
  @next_seq = 1_i64
  @transaction = 0_i64
  @counts = Hash(String, Int64).new(0_i64)

  def initialize(@name : String, @database_path : String, @cycle_directory : String, snapshot : WriterSnapshot?, seed : Int64)
    @random = Random.new(seed)
    @ledger_path = File.join(@cycle_directory, "#{@name}.ledger")
    @counts_path = File.join(@cycle_directory, "#{@name}.#{Process.pid}.counts")
    @stop_path = File.join(@cycle_directory, "stop")
    pragmas = durable_writer?(@name) ? "PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;" : "PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;"
    @connection = SoakConnection.new(engine_for(@name), @database_path, pragmas)
    check_durability_pragmas if durable_writer?(@name)
    start = snapshot ? snapshot.list_of_seqs.to_set : Set(Int64).new
    replay = LedgerReplay.new(start, read_ledger(@ledger_path), snapshot.try(&.next_seq) || 1_i64)
    @own = replay.final_state
    @next_seq = replay.highest_seq + 1
    @transaction = read_ledger(@ledger_path).max_of?(&.transaction_number) || 0_i64
    @ledger = File.open(@ledger_path, "a")
    if intent = replay.open_intent
      settle_open_intent(intent, replay)
    end
  end

  private def check_durability_pragmas : Nil
    {"fullfsync", "checkpoint_fullfsync", "synchronous"}.each do |pragma|
      code, list_of_rows = @connection.query("PRAGMA #{pragma}")
      value = list_of_rows.first?.try(&.first?)
      expected = pragma == "synchronous" ? 2_i64 : 1_i64
      raise "#{@name}: PRAGMA #{pragma} reads #{value.inspect} (code #{code}), expected #{expected}" unless value == expected
    end
  end

  # The previous process of this worker was killed between writing an intent
  # and its outcome: the database says whether the commit happened.
  private def settle_open_intent(intent : LedgerLine, replay : LedgerReplay) : Nil
    code, list_of_rows = @connection.query("SELECT seq FROM ledger WHERE writer = ?", [@name] of SoakValue)
    raise "#{@name}: reading own rows failed (#{code})" unless code == SoakEngine::DONE_CODE
    actual = list_of_rows.map(&.first.as(Int64)).to_set
    if actual == replay.state_with_open_intent
      @own = actual
      append(LedgerLine.new("R", intent.transaction_number))
    elsif actual == replay.final_state
      append(LedgerLine.new("N", intent.transaction_number))
    else
      append(LedgerLine.new("V", message: "#{@name}: after restart the rows match neither the state before transaction #{intent.transaction_number} nor after it"))
      @own = actual
    end
  end

  private def append(line : LedgerLine) : Nil
    @ledger.puts(line.to_json)
    DurableFile.sync(@ledger)
  end

  def run : Nil
    last_counts = Time.instant
    until File.exists?(@stop_path)
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
      if Time.instant - last_counts > 20.seconds
        write_counts
        last_counts = Time.instant
      end
    end
    @connection.close
    write_counts
  end

  private def write_counts : Nil
    File.write(@counts_path, @counts.to_json)
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
    return note_failure("begin", begin_code) unless begin_code == SoakEngine::DONE_CODE
    added = [] of Int64
    removed = [] of Int64
    own = @own.dup
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
    deletions = own.size > ROWS_PER_WRITER ? @random.rand(4) + 2 : (own.size > 4 && @random.rand(2) == 0 ? 1 : 0)
    deletions.times do
      break unless failed.nil?
      seq = own.sample(@random)
      result = @connection.query("DELETE FROM ledger WHERE writer = ? AND seq = ?", [@name, seq] of SoakValue)
      if ok?(result)
        removed << seq unless added.includes?(seq)
        added.delete(seq)
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
      @transaction += 1
      append(LedgerLine.new("I", @transaction, added, removed))
      commit = @connection.query("COMMIT")[0]
      if commit == SoakEngine::DONE_CODE
        append(LedgerLine.new("A", @transaction))
        @own = own
        @counts["commits"] += 1
        return
      end
      failed = {"commit", commit}
      @connection.query("ROLLBACK")
      append(LedgerLine.new("X", @transaction))
      step, code = failed
      return note_failure(step, code)
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
      append(LedgerLine.new("V", message: first))
    elsif first.nil?
      @counts["busy read"] += 1
    elsif hold
      sleep (@random.rand(50) + 10).milliseconds
      second = snapshot_problem
      if second.is_a?(Array) && second != first
        append(LedgerLine.new("V", message: "#{@name}: a snapshot changed while held"))
      end
    end
    @counts["reads"] += 1
    @connection.query("COMMIT")
  end

  private def snapshot_problem : Array(Array(SoakValue)) | String?
    code, list_of_groups = @connection.query("SELECT writer, count(*), sum(seq) FROM ledger GROUP BY writer ORDER BY writer")
    return unless code == SoakEngine::DONE_CODE
    code, list_of_totals = @connection.query("SELECT writer, row_count, seq_sum FROM totals WHERE row_count > 0 ORDER BY writer")
    return unless code == SoakEngine::DONE_CODE
    return "#{@name}: totals #{list_of_totals.first(3)} differ from rows #{list_of_groups.first(3)}" unless list_of_groups == list_of_totals
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

# The outcome of checking the database against the ledgers.
struct Verification
  getter? passed : Bool
  getter list_of_problems : Array(String)
  getter acknowledged_commits : Int64
  getter acknowledged_by_engine : Hash(String, Int64)
  getter rolled_back_by_power_cut : Int64
  getter snapshots_by_writer : Hash(String, WriterSnapshot)
  getter integrity : String

  def initialize(@passed, @list_of_problems, @acknowledged_commits, @acknowledged_by_engine, @rolled_back_by_power_cut, @snapshots_by_writer, @integrity)
  end

  def summary : String
    passed? ? "passed (integrity #{integrity}, #{acknowledged_commits} acknowledged commits checked)" : "FAILED: #{list_of_problems.first(5).join("; ")}"
  end
end

# Checks the database against every writer's ledger. *after_power_cut*
# relaxes the rule for `synchronous=NORMAL` writers to "a prefix of their
# acknowledged commits", as SQLite documents.
def verify(state : SoakState, database_path : String, cycle_directory : String, after_power_cut : Bool) : Verification
  problems = [] of String
  check = IO::Memory.new
  Process.run(SQLITE3_TOOL, ["-cmd", ".timeout 20000", database_path, "PRAGMA integrity_check;"], output: check, error: check)
  integrity = check.to_s.strip
  problems << "/usr/bin/sqlite3 integrity_check: #{integrity[0, 300]}" unless integrity == "ok"
  reader = SoakConnection.new(SoakEngine::LibSQLite3Engine.new, database_path, "PRAGMA busy_timeout=20000;")
  engine_reader = SoakConnection.new(SoakEngine::GrantEngine.new, database_path, "PRAGMA busy_timeout=20000;")
  _code, engine_integrity = engine_reader.query("PRAGMA integrity_check")
  engine_integrity_text = engine_integrity.first?.try(&.first?).to_s
  problems << "engine integrity_check: #{engine_integrity_text[0, 300]}" unless engine_integrity_text == "ok"
  engine_reader.close
  acknowledged = 0_i64
  acknowledged_by_engine = Hash(String, Int64).new(0_i64)
  rolled_back = 0_i64
  snapshots = {} of String => WriterSnapshot
  state.list_of_writer_names.each do |name|
    snapshot = state.snapshots_by_writer[name]?
    start = snapshot ? snapshot.list_of_seqs.to_set : Set(Int64).new
    entries = read_ledger(File.join(cycle_directory, "#{name}.ledger"))
    replay = LedgerReplay.new(start, entries, snapshot.try(&.next_seq) || 1_i64)
    replay.list_of_violations.each { |message| problems << "read invariant: #{message}" }
    code, list_of_rows = reader.query("SELECT seq FROM ledger WHERE writer = ?", [name] of SoakValue)
    problems << "#{name}: reading rows failed (#{code})" unless code == SoakEngine::DONE_CODE
    actual = list_of_rows.map(&.first.as(Int64)).to_set
    committed = replay.list_of_states.size.to_i64 - 1
    acknowledged += committed
    acknowledged_by_engine[name.starts_with?("g") ? "engine" : "C"] += committed
    matched = actual == replay.final_state || actual == replay.state_with_open_intent
    unless matched
      if after_power_cut && !durable_writer?(name)
        if index = replay.list_of_states.rindex(actual)
          rolled_back += committed - index
          matched = true
        end
      end
    end
    unless matched
      lost = (replay.final_state - actual).size
      unexpected = (actual - replay.final_state).size
      problems << "#{name}: rows differ from its acknowledged commits: #{lost} acknowledged rows missing, #{unexpected} rows no commit wrote"
    end
    _code, list_of_totals = reader.query("SELECT row_count, seq_sum FROM totals WHERE writer = ?", [name] of SoakValue)
    if recorded = list_of_totals.first?
      unless recorded == [actual.size.to_i64, actual.sum(0_i64)] of SoakValue
        problems << "#{name}: totals #{recorded} for #{actual.size} rows"
      end
    elsif !actual.empty?
      problems << "#{name}: #{actual.size} rows but no totals row"
    end
    snapshots[name] = WriterSnapshot.new(actual.to_a.sort, replay.highest_seq + 1)
  end
  reader.close
  Verification.new(problems.empty?, problems, acknowledged, acknowledged_by_engine, rolled_back, snapshots, integrity)
end

# Runs the soak in cycles until the target soak time is reached, resuming an
# interrupted soak first.
class SoakSupervisor
  @list_of_processes = {} of String => Process
  @stop_requested = false
  @heartbeat_seconds = 0.0

  def initialize(@directory : String, @state : SoakState)
    @database_path = File.join(@directory, "soak.db")
    @state_path = File.join(@directory, "state.json")
    @heartbeat_path = File.join(@directory, "heartbeat.json")
    @random = Random.new(@state.seed &+ @state.cycle)
  end

  def run : Int32
    Signal::TERM.trap { @stop_requested = true }
    Signal::INT.trap { @stop_requested = true }
    create_database unless File.exists?(@database_path)
    resume_interrupted_cycle if @state.cycle_in_progress?
    while @state.outcome == "running" && @state.soak_seconds_run < @state.target_seconds && !@stop_requested
      run_cycle
    end
    if @state.outcome == "running" && @state.soak_seconds_run >= @state.target_seconds
      @state.outcome = "passed"
      save_state
    end
    write_status
    @state.outcome == "failed" ? 1 : 0
  end

  private def create_database : Nil
    status = Process.run(SQLITE3_TOOL, [@database_path, SCHEMA], output: Process::Redirect::Close, error: Process::Redirect::Inherit)
    raise "creating the schema failed" unless status.success?
    DurableFile.sync_path(@database_path)
    @state.boot_time = boot_time
    save_state
  end

  private def cycle_directory(cycle : Int64) : String
    File.join(@directory, "cycles", "c%06d" % cycle)
  end

  private def save_state : Nil
    DurableFile.write(@state_path, @state.to_pretty_json)
  end

  # The supervisor stopped mid-cycle: a power cut, a reboot, or a stop. Kill
  # any worker still running, verify the database, record the interruption.
  private def resume_interrupted_cycle : Nil
    directory = cycle_directory(@state.cycle)
    kill_leftover_workers(directory)
    heartbeat = File.exists?(@heartbeat_path) ? Heartbeat.from_json(File.read(@heartbeat_path)) : nil
    cycle_seconds_run = heartbeat && heartbeat.cycle == @state.cycle ? heartbeat.cycle_seconds_run : 0.0
    rebooted = boot_time != @state.boot_time
    kind = rebooted ? "power cut or reboot" : "supervisor stopped"
    verification = verify(@state, @database_path, directory, after_power_cut: rebooted)
    @state.list_of_interruptions << Interruption.new(kind, heartbeat.try(&.written_at) || "unknown", now_text, @state.cycle,
      cycle_seconds_run, verification.summary)
    @state.add(rebooted ? "power cuts or reboots survived" : "supervisor stops survived", verification.passed? ? 1_i64 : 0_i64)
    finish_cycle(verification, cycle_seconds_run)
  end

  private def kill_leftover_workers(directory : String) : Nil
    pids_path = File.join(directory, "pids")
    return unless File.exists?(pids_path)
    File.read_lines(pids_path).each do |pid_text|
      pid = pid_text.to_i64? || next
      command = `ps -p #{pid} -o command=`.strip
      Process.signal(Signal::KILL, pid) rescue nil if command.includes?(" worker ")
    end
    sleep 1.second
  end

  private def run_cycle : Nil
    @state.cycle += 1
    @state.cycle_in_progress = true
    @state.boot_time = boot_time
    directory = cycle_directory(@state.cycle)
    Dir.mkdir_p(directory)
    save_state
    started = Time.instant
    @state.list_of_writer_names.each { |name| start_worker(name, directory) }
    next_event = started + (@random.rand(70) + 20).seconds
    next_check = started + 30.seconds
    next_heartbeat = started
    integrity_failures = 0
    while (elapsed = (Time.instant - started).total_seconds) < @state.cycle_seconds && !@stop_requested
      sleep 1.second
      now = Time.instant
      if now >= next_heartbeat
        DurableFile.write(@heartbeat_path, Heartbeat.new(@state.cycle, elapsed, now_text).to_json)
        @heartbeat_seconds = elapsed
        next_heartbeat = now + 30.seconds
        write_status(elapsed)
      end
      if now >= next_check
        integrity_failures += 1 unless concurrent_integrity_ok?
        @state.add("concurrent sqlite3 integrity checks", 1_i64)
        next_check = now + 30.seconds
      end
      if now >= next_event
        kill_and_restart(directory)
        next_event = now + (@random.rand(70) + 20).seconds
      end
      restart_exited_workers(directory)
    end
    return stop_for_signal if @stop_requested
    end_workers(directory)
    elapsed = (Time.instant - started).total_seconds
    verification = verify(@state, @database_path, directory, after_power_cut: false)
    if integrity_failures > 0
      verification = Verification.new(false, verification.list_of_problems + ["#{integrity_failures} concurrent sqlite3 integrity checks failed"],
        verification.acknowledged_commits, verification.acknowledged_by_engine, 0_i64, verification.snapshots_by_writer, verification.integrity)
    end
    finish_cycle(verification, elapsed)
  end

  # A stop request (SIGTERM from the pool or a person) ends the cycle like a
  # crash; the next `run` verifies it as an interruption.
  private def stop_for_signal : Nil
    @list_of_processes.each_value { |process| process.signal(Signal::KILL) rescue nil }
    @list_of_processes.each_value { |process| process.wait rescue nil }
    write_status(@heartbeat_seconds)
  end

  private def concurrent_integrity_ok? : Bool
    output = IO::Memory.new
    Process.run(SQLITE3_TOOL, ["-cmd", ".timeout 10000", @database_path, "PRAGMA integrity_check;"], output: output, error: output)
    output.to_s.strip == "ok" || output.to_s.includes?("database is locked")
  end

  private def start_worker(name : String, directory : String) : Nil
    process = Process.new(Process.executable_path || PROGRAM_NAME,
      ["worker", @directory, name, (@state.seed &+ @state.cycle &* 1000 &+ @random.rand(1000)).to_s],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    @list_of_processes[name] = process
    File.open(File.join(directory, "pids"), "a") { |file| file.puts(process.pid) }
  end

  private def kill_and_restart(directory : String) : Nil
    if @random.rand(5) == 0
      @list_of_processes.each_value { |process| process.signal(Signal::KILL) rescue nil }
      @list_of_processes.each_value { |process| process.wait rescue nil }
      @state.add("all workers killed at once", 1_i64)
      @state.list_of_writer_names.each { |name| start_worker(name, directory) }
    else
      name = @state.list_of_writer_names.sample(@random)
      process = @list_of_processes[name]
      process.signal(Signal::KILL) rescue nil
      process.wait rescue nil
      @state.add("single worker kills", 1_i64)
      start_worker(name, directory)
    end
  end

  # A worker that exits by itself (an exception) is a failure of the soak.
  private def restart_exited_workers(directory : String) : Nil
    @list_of_processes.each do |name, process|
      next unless process.terminated?
      status = process.wait
      @state.list_of_failures << "#{now_text} cycle #{@state.cycle}: worker #{name} exited by itself (#{status.exit_code? || status})"
      start_worker(name, directory)
    end
  end

  private def end_workers(directory : String) : Nil
    if @random.rand(2) == 0
      File.touch(File.join(directory, "stop"))
      deadline = Time.instant + 30.seconds
      while @list_of_processes.values.any? { |process| !process.terminated? } && Time.instant < deadline
        sleep 200.milliseconds
      end
      @state.add("cycles ended by a clean stop", 1_i64)
    else
      @state.add("cycles ended by killing every worker", 1_i64)
    end
    @list_of_processes.each_value { |process| process.signal(Signal::KILL) rescue nil unless process.terminated? }
    @list_of_processes.each_value { |process| process.wait rescue nil }
    @list_of_processes.clear
  end

  private def finish_cycle(verification : Verification, cycle_seconds_run : Float64) : Nil
    directory = cycle_directory(@state.cycle)
    count_worker_totals(directory)
    @state.add("acknowledged commits verified", verification.acknowledged_commits)
    verification.acknowledged_by_engine.each { |engine, count| @state.add("acknowledged commits verified, #{engine}", count) }
    @state.add("acknowledged NORMAL commits rolled back by a power cut (allowed)", verification.rolled_back_by_power_cut)
    @state.last_verified_at = now_text
    unless verification.passed? && @state.list_of_failures.empty?
      @state.outcome = "failed"
      @state.list_of_failures << "#{now_text} cycle #{@state.cycle}: #{verification.summary}" unless verification.passed?
      @state.cycle_in_progress = false
      save_state
      write_status
      return
    end
    checkpoint_and_sync
    @state.snapshots_by_writer = verification.snapshots_by_writer
    @state.soak_seconds_run += cycle_seconds_run
    @state.cycles_verified += 1
    @state.cycle_in_progress = false
    add_hourly_lines
    save_state
    remove_old_cycles
    write_status
  end

  private def count_worker_totals(directory : String) : Nil
    Dir.glob(File.join(directory, "*.counts")).each do |path|
      counts = Hash(String, Int64).from_json(File.read(path)) rescue next
      engine = File.basename(path).starts_with?("g") ? "engine" : "C"
      counts.each do |key, count|
        next unless key == "reads" || key.starts_with?("error")
        @state.add("#{engine} #{key}", count)
      end
    end
  end

  # Moves every committed frame into the database file and makes it
  # durable, so the next cycle starts from a state a power cut keeps.
  private def checkpoint_and_sync : Nil
    Process.run(SQLITE3_TOOL, ["-cmd", ".timeout 20000", @database_path, "PRAGMA wal_checkpoint(TRUNCATE);"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    DurableFile.sync_path(@database_path)
    DurableFile.sync_path("#{@database_path}-wal")
  end

  private def add_hourly_lines : Nil
    while @state.soak_seconds_run >= (@state.list_of_hourly_lines.size + 1) * 3600.0
      hour = @state.list_of_hourly_lines.size + 1
      counts = @state.counts_by_name
      line = "#{now_text} hour #{hour}/#{(@state.target_seconds / 3600).round.to_i}: " \
             "cycles verified #{@state.cycles_verified}, " \
             "acknowledged commits verified engine #{counts.fetch("acknowledged commits verified, engine", 0)} " \
             "C #{counts.fetch("acknowledged commits verified, C", 0)}, " \
             "lost 0, " \
             "kills single #{counts.fetch("single worker kills", 0)} all #{counts.fetch("all workers killed at once", 0)}, " \
             "interruptions #{@state.list_of_interruptions.size}, " \
             "sqlite3 integrity ok (#{counts.fetch("concurrent sqlite3 integrity checks", 0)} concurrent checks)"
      @state.list_of_hourly_lines << line
      File.open(File.join(@directory, "hourly.log"), "a") { |file| file.puts(line) }
    end
  end

  private def remove_old_cycles : Nil
    list_of_cycles = Dir.glob(File.join(@directory, "cycles", "c*")).sort
    list_of_cycles[0...-3].each { |path| FileUtils.rm_rf(path) } if list_of_cycles.size > 3
  end

  def write_status(cycle_seconds_run : Float64 = 0.0) : Nil
    File.write(File.join(@directory, "status.txt"), SoakStatus.new(@state, cycle_seconds_run).text)
  end
end

# The human-readable status file.
struct SoakStatus
  def initialize(@state : SoakState, @cycle_seconds_run : Float64)
  end

  def text : String
    run = @state.soak_seconds_run + (@state.cycle_in_progress? ? @cycle_seconds_run : 0.0)
    remaining = {@state.target_seconds - run, 0.0}.max
    counts = @state.counts_by_name
    String.build do |io|
      io << "Grant SQLite engine durability soak\n"
      io << "outcome:            " << @state.outcome.upcase << "\n"
      io << "updated:            " << now_text << "\n"
      io << "soak time run:      " << "%.2f" % (run / 3600) << " h of " << "%.2f" % (@state.target_seconds / 3600) << " h"
      io << " (verified through cycle " << @state.cycles_verified << ": " << "%.2f" % (@state.soak_seconds_run / 3600) << " h)\n"
      io << "ETA:                " << (Time.utc + remaining.seconds).to_rfc3339 << " if uninterrupted\n" if @state.outcome == "running"
      io << "cycle:              " << @state.cycle << (@state.cycle_in_progress? ? " (running, #{@cycle_seconds_run.round.to_i} s in)" : "") << "\n"
      io << "workers:            " << @state.engine_workers << " engine, " << @state.c_workers << " C (libsqlite3); even-numbered durable (FULL + fullfsync)\n"
      io << "last verified:      " << @state.last_verified_at << "\n"
      io << "lost commits:       0 (any loss ends the soak as FAILED)\n" if @state.outcome != "failed"
      counts.keys.sort.each { |key| io << "  " << key << ": " << counts[key] << "\n" }
      io << "interruptions:      " << @state.list_of_interruptions.size << "\n"
      @state.list_of_interruptions.each do |interruption|
        io << "  cycle " << interruption.cycle << ": " << interruption.kind_of_interruption << ", last heartbeat " << interruption.last_heartbeat_at
        io << ", resumed " << interruption.resumed_at << ", " << interruption.cycle_seconds_run.round.to_i << " s of the cycle counted; verification "
        io << interruption.verification << "\n"
      end
      unless @state.list_of_failures.empty?
        io << "failures:\n"
        @state.list_of_failures.each { |failure| io << "  " << failure << "\n" }
      end
      io << "hourly:\n"
      @state.list_of_hourly_lines.each { |line| io << "  " << line << "\n" }
      io << "resume after a power cycle or stop:\n  " << @state.resume_command << "\n"
    end
  end
end

def option(arguments : Array(String), name : String, default : String) : String
  index = arguments.index(name)
  index ? arguments[index + 1] : default
end

case ARGV[0]?
when "worker"
  directory, name, seed = ARGV[1], ARGV[2], ARGV[3].to_i64
  state = SoakState.from_json(File.read(File.join(directory, "state.json")))
  cycle_directory = File.join(directory, "cycles", "c%06d" % state.cycle)
  SoakWorker.new(name, File.join(directory, "soak.db"), cycle_directory, state.snapshots_by_writer[name]?, seed).run
when "run"
  directory = ARGV[1]
  Dir.mkdir_p(directory)
  lock = File.open(File.join(directory, "supervisor.lock"), "w")
  begin
    lock.flock_exclusive(blocking: false)
  rescue IO::Error
    abort "another supervisor is running this soak (#{directory})"
  end
  state_path = File.join(directory, "state.json")
  state = if File.exists?(state_path)
            SoakState.from_json(File.read(state_path))
          else
            SoakState.new(option(ARGV, "--hours", "72").to_f * 3600, option(ARGV, "--cycle-minutes", "10").to_f * 60,
              option(ARGV, "--engine-workers", "4").to_i, option(ARGV, "--c-workers", "2").to_i,
              option(ARGV, "--seed", "20261124").to_i64, option(ARGV, "--resume-command", "#{PROGRAM_NAME} run #{directory}"), now_text)
          end
  exit SoakSupervisor.new(directory, state).run
when "status"
  state = SoakState.from_json(File.read(File.join(ARGV[1], "state.json")))
  puts SoakStatus.new(state, 0.0).text
when "check"
  # Verifies a soak that is not running against its last verified snapshot:
  # the database must hold exactly the rows the snapshot records.
  state = SoakState.from_json(File.read(File.join(ARGV[1], "state.json")))
  abort "the soak is mid-cycle; run it to resume instead" if state.cycle_in_progress?
  verification = verify(state, File.join(ARGV[1], "soak.db"), File.join(ARGV[1], "no-ledgers"), after_power_cut: false)
  puts verification.summary
  exit verification.passed? ? 0 : 1
else
  abort "usage: run DIRECTORY [--hours H] [--cycle-minutes M] [--engine-workers N] [--c-workers N] [--seed N] [--resume-command TEXT] | status DIRECTORY | check DIRECTORY"
end
