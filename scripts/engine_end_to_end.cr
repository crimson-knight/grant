# An app's round trip through Grant's SQLite adapter on Grant's own engine
# (no C SQLite library linked), on real files, in both journal modes:
# create a table, insert, query, reopen from a new process and read back,
# then processes contending for the write lock. CI runs it on Windows,
# where it proves the engine's WindowsFileSystem:
#
#   crystal build scripts/engine_end_to_end.cr -o engine_end_to_end
#   ./engine_end_to_end run <directory> [<sqlite3 shell>]
#
# `run` starts this same program as the other processes (the roles below)
# and prints one line per check; it exits 1 when any check fails. With a
# sqlite3 shell, C SQLite also reads each database and checks its integrity.
require "../src/grant"
require "../src/adapter/sqlite/grant_engine"

# Each process prints its answer on standard output; logs go to standard error.
Log.setup(:warn, Log::IOBackend.new(STDERR))

module EngineEndToEnd
  # Rows each contending inserter adds, one transaction each.
  INSERTS_EACH = 25

  # How long the "hold" process keeps its write transaction open.
  HOLD_TIME = 1500.milliseconds

  def self.connect(journal_mode : String, path : String, busy_timeout : String = "5000") : Nil
    Grant::Connections << Grant::Adapter::Sqlite.new(name: "primary", url: "sqlite3:#{path}",
      pragmas: {journal_mode: journal_mode, busy_timeout: busy_timeout})
  end

  def self.list_of_titles : Array(String)
    EngineNote.order(id: :asc).map(&.title)
  end

  def self.start(role : String, journal_mode : String, path : String, *arguments) : Process
    Process.new(Process.executable_path || PROGRAM_NAME, [role, journal_mode, path] + arguments.map(&.to_s).to_a,
      output: Process::Redirect::Pipe, error: Process::Redirect::Inherit)
  end

  # Runs *role* in a new process and returns what it printed.
  def self.run_role(role : String, journal_mode : String, path : String, *arguments) : String
    finish(start(role, journal_mode, path, *arguments))
  end

  def self.finish(process : Process) : String
    output = process.output.gets_to_end
    process.wait
    output.strip
  end

  class Checks
    getter list_of_failures = [] of String

    def check(label : String, actual : String, expected : String) : Nil
      passed = actual == expected
      STDOUT.puts "#{passed ? "ok  " : "FAIL"} #{label}: #{actual}#{passed ? "" : " (expected #{expected})"}"
      list_of_failures << label unless passed
    end
  end

  def self.run(directory : String, sqlite3_shell : String?) : Nil
    Dir.mkdir_p(directory)
    checks = Checks.new
    STDOUT.puts "platform: #{{{ flag?(:win32) ? "windows" : "posix" }}}, file system: #{Grant::SQLiteEngine::FileSystem.native.class}"
    {"delete", "wal"}.each do |journal_mode|
      path = File.join(directory, "end_to_end_#{journal_mode}.sqlite3")
      {path, "#{path}-journal", "#{path}-wal", "#{path}-shm"}.each { |file| File.delete?(file) }
      STDOUT.puts "-- journal_mode=#{journal_mode} (#{path})"

      checks.check("#{journal_mode}: create, insert, query", run_role("write", journal_mode, path), "rows 3: alpha, beta, gamma")
      checks.check("#{journal_mode}: reopen and read back", run_role("read", journal_mode, path), "rows 3: alpha, beta, gamma")
      header = File.open(path, &.read_at(18, 2, &.getb_to_end))
      checks.check("#{journal_mode}: header read/write versions", header.to_a.inspect, journal_mode == "wal" ? "[2, 2]" : "[1, 1]")

      # One process holds a write transaction open; a writer that will not
      # wait is refused, and one that waits commits after it.
      holder = start("hold", journal_mode, path)
      ready = holder.output.gets
      checks.check("#{journal_mode}: holder has the write lock", ready.to_s, "holding")
      checks.check("#{journal_mode}: writer with busy_timeout=0 is refused", run_role("insert", journal_mode, path, "impatient", "1", "0"), "locked")
      waiting = start("insert", journal_mode, path, "patient", "1", "5000")
      checks.check("#{journal_mode}: holder commits", finish(holder), "committed")
      checks.check("#{journal_mode}: waiting writer commits after it", finish(waiting), "inserted 1")

      # Two processes insert at once, every transaction waiting its turn.
      list_of_inserters = {"left", "right"}.map { |label| start("insert", journal_mode, path, label, INSERTS_EACH.to_s, "5000") }
      list_of_inserters.each_with_index do |inserter, index|
        checks.check("#{journal_mode}: contending inserter #{index + 1}", finish(inserter), "inserted #{INSERTS_EACH}")
      end
      total = 3 + 2 + 2 * INSERTS_EACH
      checks.check("#{journal_mode}: rows after contention", run_role("count", journal_mode, path), "rows #{total}")

      if sqlite3_shell
        output = IO::Memory.new
        Process.run(sqlite3_shell, [path, "PRAGMA integrity_check; SELECT count(*) FROM engine_notes;"], output: output, error: output)
        checks.check("#{journal_mode}: C SQLite integrity_check and count", output.to_s.strip.split.join(" "), "ok #{total}")
      end
    end
    if checks.list_of_failures.empty?
      STDOUT.puts "end-to-end: all checks passed"
    else
      STDOUT.puts "end-to-end: #{checks.list_of_failures.size} failed"
      exit 1
    end
  end
end

class EngineNote < Grant::Base
  connection primary
  table engine_notes

  column id : Int64, primary: true
  column title : String
end

role = ARGV[0]? || "run"
case role
when "run"
  directory = ARGV[1]? || File.join(Dir.tempdir, "grant_engine_end_to_end")
  EngineEndToEnd.run(directory, ARGV[2]?)
when "write"
  EngineEndToEnd.connect(ARGV[1], ARGV[2])
  EngineNote.migrator.drop_and_create
  EngineNote.transaction do
    {"alpha", "beta", "gamma"}.each { |title| EngineNote.create!(title: title) }
  end
  titles = EngineEndToEnd.list_of_titles
  puts "rows #{titles.size}: #{titles.join(", ")}"
when "read"
  EngineEndToEnd.connect(ARGV[1], ARGV[2])
  titles = EngineEndToEnd.list_of_titles.first(3)
  puts "rows #{EngineNote.count}: #{titles.join(", ")}"
when "count"
  EngineEndToEnd.connect(ARGV[1], ARGV[2])
  puts "rows #{EngineNote.count}"
when "hold"
  EngineEndToEnd.connect(ARGV[1], ARGV[2])
  EngineNote.transaction do
    EngineNote.create!(title: "held")
    puts "holding"
    STDOUT.flush
    sleep EngineEndToEnd::HOLD_TIME
  end
  puts "committed"
when "insert"
  EngineEndToEnd.connect(ARGV[1], ARGV[2], ARGV[5])
  count = ARGV[4].to_i
  begin
    count.times { |index| EngineNote.transaction { EngineNote.create!(title: "#{ARGV[3]} #{index}") } }
    puts "inserted #{count}"
  rescue error
    puts (error.message || "").includes?("locked") ? "locked" : "error: #{error.message}"
  end
else
  abort "unknown role #{role}"
end
