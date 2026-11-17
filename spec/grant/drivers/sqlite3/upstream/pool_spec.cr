require "spec"

{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "./spec_helper"

# Grant's SQLite adapter opens app databases with busy_timeout=5000 unless
# the app sets its own (see spec/adapter/sqlite_pragmas_spec.cr). This file
# talks to the driver directly, so it states that default for its
# concurrent writers.
POOL_SPEC_BUSY_TIMEOUT_MS = 5000

# How long an example waits for all writers' outcomes before it asks them
# to stop, so a writer that never reports fails the example instead of
# stopping the suite.
POOL_SPEC_OUTCOME_TIMEOUT = 30.seconds

# How long writers get to stop once asked. A writer checks for the request
# before each insert, so it stops after the insert it is running.
POOL_SPEC_STOP_GRACE = 10.seconds

# The outcome of a writer that saw the stop request before its next insert.
private class PoolSpecWriterStopped < Exception
end

# The writers of one example: a stop request they all read, and a count of
# those still running. It is a class so every writer shares one copy;
# Atomic itself is a struct and would be copied into each call.
private class PoolSpecWriterCrew
  @stop_requested = Atomic(Bool).new(false)
  @running_writers = Atomic(Int32).new(0)

  def request_stop : Nil
    @stop_requested.set(true)
  end

  def stop_requested? : Bool
    @stop_requested.get
  end

  def writer_started : Nil
    @running_writers.add(1)
  end

  def writer_finished : Nil
    @running_writers.sub(1)
  end

  def any_writer_running? : Bool
    @running_writers.get > 0
  end
end

# Opens a fresh database for an example's writers and closes it afterward
# only when none of them is still running. Closing it under a running
# writer crashes SQLite when CRYSTAL_WORKERS > 1, so an example whose
# writer never finished leaves the database open and fails on its own.
private def with_writer_database(pragmas : String, crew : PoolSpecWriterCrew, &block : DB::Database ->)
  File.delete(SQLITE_DRIVER_DB_FILENAME) rescue nil
  db = DB.open "sqlite3:#{SQLITE_DRIVER_DB_FILENAME}?#{pragmas}"
  begin
    block.call(db)
  ensure
    unless crew.any_writer_running?
      db.close
      File.delete(SQLITE_DRIVER_DB_FILENAME) rescue nil
    end
  end
end

# Writes rows 1..last_n for one writer, then sends its outcome: nil when
# every insert succeeded, or the exception that stopped it.
private def spawn_number_writer(db : DB::Database, table_name : String, writer_number : Int32,
                                last_n : Int32, outcomes : Channel(Exception?),
                                crew : PoolSpecWriterCrew)
  crew.writer_started
  spawn name: "pool_spec writer #{writer_number}" do
    outcome = begin
      (1..last_n).each do |row_number|
        if crew.stop_requested?
          raise PoolSpecWriterStopped.new("writer #{writer_number} stopped before row #{row_number} because the wait timed out")
        end
        db.exec "insert into #{table_name} (n, fiber) values (?, ?)", row_number, writer_number
        sleep 0.01.seconds
      end
      nil
    rescue error : Exception
      error
    ensure
      crew.writer_finished
    end
    outcomes.send outcome
  end
end

# Collects one outcome per writer. Past *timeout* it asks the writers to
# stop and keeps collecting for POOL_SPEC_STOP_GRACE; a writer still
# running after that fails the example, and `with_writer_database` leaves
# its database open.
private def collect_writer_outcomes(outcomes : Channel(Exception?), writer_count : Int32,
                                    crew : PoolSpecWriterCrew,
                                    timeout : Time::Span = POOL_SPEC_OUTCOME_TIMEOUT) : Array(Exception?)
  list_of_outcomes = [] of Exception?
  deadline = Time.instant + timeout
  while list_of_outcomes.size < writer_count
    wait = crew.stop_requested? ? POOL_SPEC_STOP_GRACE : {deadline - Time.instant, Time::Span.zero}.max
    select
    when outcome = outcomes.receive
      list_of_outcomes << outcome
    when timeout(wait)
      if crew.stop_requested?
        fail "#{writer_count - list_of_outcomes.size} of #{writer_count} writers did not stop within #{POOL_SPEC_STOP_GRACE}"
      end
      crew.request_stop
    end
  end
  list_of_outcomes
end

describe DB::Pool do
  it "should write from multiple connections" do
    outcomes = Channel(Exception?).new
    crew = PoolSpecWriterCrew.new
    fibers = 5
    max_n = 50
    with_writer_database "max_pool_size=#{fibers}&busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}", crew do |db|
      db.exec "create table numbers (n integer, fiber integer)"

      fibers.times do |writer_number|
        spawn_number_writer(db, "numbers", writer_number, max_n, outcomes, crew)
      end

      # Every writer reports before any is judged, so a failure never
      # closes the database under a running writer.
      list_of_errors = collect_writer_outcomes(outcomes, fibers, crew).compact
      unless list_of_errors.empty?
        fail "#{list_of_errors.size} of #{fibers} writers failed: " +
             list_of_errors.map { |error| "#{error.class}: #{error.message}" }.join("; ")
      end

      # all numbers were inserted
      expected_sum = fibers * max_n * (max_n + 1) // 2
      db.scalar("select sum(n) from numbers").should eq(expected_sum)

      # numbers were not inserted one fiber at a time
      rows = db.query_all "select n, fiber from numbers", as: {Int32, Int32}
      rows.map(&.[1]).should_not eq(rows.map(&.[1]).sort)
    end
  end

  describe "a writer's outcome reaches the receiver" do
    it "reports success when its last row is the last row the table accepts" do
      outcomes = Channel(Exception?).new
      crew = PoolSpecWriterCrew.new
      with_writer_database "busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}", crew do |db|
        db.exec "create table capped_numbers (n integer check (n < 10), fiber integer)"

        spawn_number_writer(db, "capped_numbers", 0, 9, outcomes, crew)

        collect_writer_outcomes(outcomes, 1, crew).should eq([nil] of Exception?)
        db.scalar("select count(*) from capped_numbers").should eq(9)
      end
    end

    it "reports the error when its last row is one past what the table accepts" do
      outcomes = Channel(Exception?).new
      crew = PoolSpecWriterCrew.new
      with_writer_database "busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}", crew do |db|
        db.exec "create table capped_numbers (n integer check (n < 10), fiber integer)"

        spawn_number_writer(db, "capped_numbers", 0, 10, outcomes, crew)

        error = collect_writer_outcomes(outcomes, 1, crew).first
        error.should be_a(Grant::SQLite3::Exception)
        error.try(&.message).to_s.should contain("CHECK constraint failed")
        db.scalar("select count(*) from capped_numbers").should eq(9)
      end
    end

    it "stops a writer that outlasts the wait and still collects its outcome" do
      outcomes = Channel(Exception?).new
      crew = PoolSpecWriterCrew.new
      with_writer_database "busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}", crew do |db|
        db.exec "create table numbers (n integer, fiber integer)"

        # 10,000 rows at 10 ms each would take about 100 seconds.
        spawn_number_writer(db, "numbers", 0, 10_000, outcomes, crew)

        error = collect_writer_outcomes(outcomes, 1, crew, timeout: 200.milliseconds).first
        error.should be_a(PoolSpecWriterStopped)
        crew.any_writer_running?.should be_false
        db.scalar("select count(*) from numbers").as(Int64).should be < 10_000
      end
    end
  end

  describe "the writer database" do
    it "closes when every writer has finished" do
      crew = PoolSpecWriterCrew.new
      pooled_connection = nil
      with_writer_database "busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}", crew do |db|
        pooled_connection = db.checkout
        pooled_connection.try(&.release)
      end

      pooled_connection.try(&.closed?).should be_true
    end

    it "stays open while one writer is still running" do
      crew = PoolSpecWriterCrew.new
      pooled_connection = nil
      opened_db = nil
      crew.writer_started
      with_writer_database "busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}", crew do |db|
        opened_db = db
        pooled_connection = db.checkout
        pooled_connection.try(&.release)
      end

      pooled_connection.try(&.closed?).should be_false
      crew.writer_finished
      opened_db.try(&.close)
      File.delete(SQLITE_DRIVER_DB_FILENAME) rescue nil
    end
  end
end
