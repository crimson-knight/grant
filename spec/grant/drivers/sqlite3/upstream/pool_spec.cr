require "spec"

{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "./spec_helper"

# Grant's SQLite adapter opens every app database with busy_timeout=5000
# (see spec/adapter/sqlite_pragmas_spec.cr). This file talks to the driver
# directly, so it states the same timeout for its concurrent writers.
POOL_SPEC_BUSY_TIMEOUT_MS = 5000

# How long an example waits for all writers' outcomes before it asks them
# to stop, so a writer that never reports fails the example instead of
# stopping the suite.
POOL_SPEC_OUTCOME_TIMEOUT = 30.seconds

# How long writers get to stop once asked. Each one finishes at most its
# current insert, which busy_timeout bounds at POOL_SPEC_BUSY_TIMEOUT_MS.
POOL_SPEC_STOP_GRACE = (POOL_SPEC_BUSY_TIMEOUT_MS * 2).milliseconds

# The outcome of a writer that saw the stop request before its next insert.
private class PoolSpecWriterStopped < Exception
end

# One stop request shared by an example and all of its writers. It is a
# class so every writer reads the same flag; Atomic itself is a struct and
# would be copied into each call.
private class PoolSpecStopSignal
  @stop_requested = Atomic(Bool).new(false)

  def request_stop : Nil
    @stop_requested.set(true)
  end

  def stop_requested? : Bool
    @stop_requested.get
  end
end

# Writes rows 1..last_n for one writer, then sends its outcome: nil when
# every insert succeeded, or the exception that stopped it.
private def spawn_number_writer(db : DB::Database, table_name : String, writer_number : Int32,
                                last_n : Int32, outcomes : Channel(Exception?),
                                stop_signal : PoolSpecStopSignal)
  spawn name: "pool_spec writer #{writer_number}" do
    outcome = begin
      (1..last_n).each do |row_number|
        if stop_signal.stop_requested?
          raise PoolSpecWriterStopped.new("writer #{writer_number} stopped before row #{row_number} because the wait timed out")
        end
        db.exec "insert into #{table_name} (n, fiber) values (?, ?)", row_number, writer_number
        sleep 0.01.seconds
      end
      nil
    rescue error : Exception
      error
    end
    outcomes.send outcome
  end
end

# Collects one outcome per writer. Past *timeout* it asks the writers to
# stop and keeps collecting, so the example never closes the database
# while a writer is still inserting (that crashes SQLite when
# CRYSTAL_WORKERS > 1).
private def collect_writer_outcomes(outcomes : Channel(Exception?), writer_count : Int32,
                                    stop_signal : PoolSpecStopSignal,
                                    timeout : Time::Span = POOL_SPEC_OUTCOME_TIMEOUT) : Array(Exception?)
  list_of_outcomes = [] of Exception?
  deadline = Time.instant + timeout
  while list_of_outcomes.size < writer_count
    wait = stop_signal.stop_requested? ? POOL_SPEC_STOP_GRACE : {deadline - Time.instant, Time::Span.zero}.max
    select
    when outcome = outcomes.receive
      list_of_outcomes << outcome
    when timeout(wait)
      if stop_signal.stop_requested?
        fail "#{writer_count - list_of_outcomes.size} of #{writer_count} writers did not stop within #{POOL_SPEC_STOP_GRACE}"
      end
      stop_signal.request_stop
    end
  end
  list_of_outcomes
end

describe DB::Pool do
  it "should write from multiple connections" do
    outcomes = Channel(Exception?).new
    fibers = 5
    max_n = 50
    with_sqlite_driver_db "#{SQLITE_DRIVER_DB_FILENAME}?max_pool_size=#{fibers}&busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}" do |db|
      db.exec "create table numbers (n integer, fiber integer)"

      stop_signal = PoolSpecStopSignal.new
      fibers.times do |writer_number|
        spawn_number_writer(db, "numbers", writer_number, max_n, outcomes, stop_signal)
      end

      # Every writer reports before any is judged, so a failure never
      # closes the database under a running writer.
      list_of_errors = collect_writer_outcomes(outcomes, fibers, stop_signal).compact
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
      with_sqlite_driver_db "#{SQLITE_DRIVER_DB_FILENAME}?busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}" do |db|
        db.exec "create table capped_numbers (n integer check (n < 10), fiber integer)"

        spawn_number_writer(db, "capped_numbers", 0, 9, outcomes, PoolSpecStopSignal.new)

        collect_writer_outcomes(outcomes, 1, PoolSpecStopSignal.new).should eq([nil] of Exception?)
        db.scalar("select count(*) from capped_numbers").should eq(9)
      end
    end

    it "reports the error when its last row is one past what the table accepts" do
      outcomes = Channel(Exception?).new
      with_sqlite_driver_db "#{SQLITE_DRIVER_DB_FILENAME}?busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}" do |db|
        db.exec "create table capped_numbers (n integer check (n < 10), fiber integer)"

        spawn_number_writer(db, "capped_numbers", 0, 10, outcomes, PoolSpecStopSignal.new)

        error = collect_writer_outcomes(outcomes, 1, PoolSpecStopSignal.new).first
        error.should be_a(Grant::SQLite3::Exception)
        error.try(&.message).to_s.should contain("CHECK constraint failed")
        db.scalar("select count(*) from capped_numbers").should eq(9)
      end
    end

    it "stops a writer that outlasts the wait and still collects its outcome" do
      outcomes = Channel(Exception?).new
      stop_signal = PoolSpecStopSignal.new
      with_sqlite_driver_db "#{SQLITE_DRIVER_DB_FILENAME}?busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}" do |db|
        db.exec "create table numbers (n integer, fiber integer)"

        # 10,000 rows at 10 ms each would take about 100 seconds.
        spawn_number_writer(db, "numbers", 0, 10_000, outcomes, stop_signal)

        error = collect_writer_outcomes(outcomes, 1, stop_signal, timeout: 200.milliseconds).first
        error.should be_a(PoolSpecWriterStopped)
        stop_signal.stop_requested?.should be_true
        db.scalar("select count(*) from numbers").as(Int64).should be < 10_000
      end
    end
  end
end
