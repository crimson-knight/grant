require "../../support/sqlite_engine/crash_driver"

# Crash simulation over small random write sequences in
# journal_mode=DELETE: every write, sync, truncate and delete of every unit
# is a crash point. The regular run keeps one seed and a few sequences; the
# nightly run sets SQLITE_ENGINE_CRASH_SEQUENCES=1000 with a fresh
# SQLITE_ENGINE_CRASH_SEED.
DEFAULT_CRASH_SEED = "20261123"

describe "Grant::SQLiteEngine crash recovery" do
  count = ENV.fetch("SQLITE_ENGINE_CRASH_SEQUENCES", "6").to_i
  seed = (ENV["SQLITE_ENGINE_CRASH_SEED"]? || DEFAULT_CRASH_SEED).to_i64

  it "recovers every crash point to the state before or after the write (#{count} sequences, seed #{seed})" do
    summary = SQLiteEngineCrashDriver.run(count, seed)
    STDOUT.puts "\n  crash simulation: #{summary.sequences} sequences, seed #{seed}, #{summary.units} write units, " \
                "#{summary.crash_points} crash points, #{summary.states_checked} distinct crash states opened by the engine, " \
                "#{summary.sqlite3_states_checked} by sqlite3, #{summary.list_of_failures.size} neither old nor new"
    summary.list_of_failures.first(10).each { |failure| STDOUT.puts "  #{failure}" }
    summary.list_of_failures.should be_empty
  end
end
