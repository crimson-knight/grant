require "spec"

{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "./spec_helper"

# Grant's SQLite adapter opens every app database with busy_timeout=5000
# (see spec/adapter/sqlite_pragmas_spec.cr). This file talks to the driver
# directly, so it states the same timeout for its concurrent writers.
POOL_SPEC_BUSY_TIMEOUT_MS = 5000

# Upper bound on the wait for one writer's outcome, so a writer that never
# reports fails the example instead of stopping the suite.
POOL_SPEC_OUTCOME_TIMEOUT = 30.seconds

# Writes rows 1..last_n for one writer, then sends its outcome: nil when
# every insert succeeded, or the exception that stopped it.
private def spawn_number_writer(db : DB::Database, table_name : String, writer_number : Int32,
                                last_n : Int32, outcomes : Channel(Exception?))
  spawn name: "pool_spec writer #{writer_number}" do
    outcome = begin
      (1..last_n).each do |row_number|
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

private def receive_writer_outcome(outcomes : Channel(Exception?)) : Exception?
  select
  when outcome = outcomes.receive
    outcome
  when timeout(POOL_SPEC_OUTCOME_TIMEOUT)
    fail "a writer sent no outcome within #{POOL_SPEC_OUTCOME_TIMEOUT}"
  end
end

describe DB::Pool do
  it "should write from multiple connections" do
    outcomes = Channel(Exception?).new
    fibers = 5
    max_n = 50
    with_sqlite_driver_db "#{SQLITE_DRIVER_DB_FILENAME}?max_pool_size=#{fibers}&busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}" do |db|
      db.exec "create table numbers (n integer, fiber integer)"

      fibers.times do |writer_number|
        spawn_number_writer(db, "numbers", writer_number, max_n, outcomes)
      end

      # Wait for every writer before judging any of them: failing on the
      # first error would close the database while the other writers are
      # still inserting, which crashes SQLite under CRYSTAL_WORKERS > 1.
      list_of_outcomes = Array.new(fibers) { receive_writer_outcome(outcomes) }
      list_of_errors = list_of_outcomes.compact
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

        spawn_number_writer(db, "capped_numbers", 0, 9, outcomes)

        receive_writer_outcome(outcomes).should be_nil
        db.scalar("select count(*) from capped_numbers").should eq(9)
      end
    end

    it "reports the error when its last row is one past what the table accepts" do
      outcomes = Channel(Exception?).new
      with_sqlite_driver_db "#{SQLITE_DRIVER_DB_FILENAME}?busy_timeout=#{POOL_SPEC_BUSY_TIMEOUT_MS}" do |db|
        db.exec "create table capped_numbers (n integer check (n < 10), fiber integer)"

        spawn_number_writer(db, "capped_numbers", 0, 10, outcomes)

        error = receive_writer_outcome(outcomes)
        error.should be_a(Grant::SQLite3::Exception)
        error.try(&.message).to_s.should contain("CHECK constraint failed")
        db.scalar("select count(*) from capped_numbers").should eq(9)
      end
    end
  end
end
