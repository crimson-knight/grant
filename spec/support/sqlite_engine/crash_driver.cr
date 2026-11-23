require "./write_driver"

# Runs random write sequences on the crash simulator's file system and, for
# every write unit (one statement, or one transaction), checks every crash
# point: each prefix of the unit's writes, syncs, truncates and deletes,
# with unsynced writes kept, lost or torn. The engine (reopening the files,
# which rolls back a hot journal) and the sqlite3 tool must each find
# exactly the state before the unit or the state after it.
module SQLiteEngineCrashDriver
  DATABASE = "crash.db"

  record Summary, sequences : Int32, units : Int32, crash_points : Int32, states_checked : Int32,
    sqlite3_states_checked : Int32, list_of_failures : Array(String)

  def self.engine_dump(database : Grant::SQLiteEngine::Database) : String
    canonical(String.build { |io| Grant::SQLiteEngine::Dump.new(database).write(io) })
  end

  def self.canonical(dump : String) : String
    dump.lines.map { |line| SQLiteEngineDifferential.canonical(line) }.join('\n')
  end

  def self.state_key(state : Hash(String, Bytes)) : UInt64
    hasher = Crystal::Hasher.new
    state.keys.sort!.each do |path|
      hasher = path.hash(hasher)
      hasher = state[path].hash(hasher)
    end
    hasher.result
  end

  def self.run(count : Int32, seed : Int64) : Summary
    failures = [] of String
    units = 0
    crash_points = 0
    states_checked = 0
    sqlite3_checked = 0
    count.times do |number|
      directory = Path[Dir.tempdir] / "grant-sqlite-engine-crash-#{Process.pid}-#{number}"
      FileUtils.rm_rf(directory)
      Dir.mkdir_p(directory)
      SQLiteEngineWriteDriver.ruby(["sequences", directory.to_s, "--count", "1", "--seed", seed.to_s, "--start", number.to_s, "--size", "small"])
      name = "seq_%05d" % number
      sequence = SQLiteEngineWriteDriver::Sequence.from_json(File.read(directory / "#{name}.json"))
      file_system = SQLiteEngineCrashFileSystem.new
      database = Grant::SQLiteEngine::Database.open(DATABASE, read_write: true, page_size: sequence.page_size,
        text_encoding: sequence.text_encoding, file_system: file_system)
      outcome = SQLiteEngineWriteDriver::Outcome.new
      written = [] of {String, String, String}
      sequence.list_of_units.each_with_index do |unit, unit_number|
        before = file_system.snapshot
        old_dump = engine_dump(database)
        file_system.start_recording
        SQLiteEngineWriteDriver.apply_unit(database, unit, outcome)
        operations = file_system.stop_recording
        new_dump = engine_dump(database)
        units += 1
        crash_points += operations.size + 1
        seen = Set(UInt64).new
        (0..operations.size).each do |prefix|
          SQLiteEngineCrashFileSystem::Variant.each do |variant|
            state = SQLiteEngineCrashFileSystem.crash_state(before, operations, prefix, variant)
            next unless state
            next unless seen.add?(state_key(state))
            states_checked += 1
            label = "#{name} (seed #{sequence.seed}) unit #{unit_number} prefix #{prefix}/#{operations.size} #{variant}"
            recovered = begin
              reopened = Grant::SQLiteEngine::Database.open(DATABASE, read_write: true, file_system: SQLiteEngineCrashFileSystem.new(state.transform_values(&.dup)))
              dump = engine_dump(reopened)
              reopened.close
              dump
            rescue error : Grant::SQLiteEngine::Error
              failures << "#{label}: the engine could not open the crashed files: #{error.message}"
              next
            end
            if prefix == operations.size && variant.kept? && recovered != new_dump
              failures << "#{label}: the completed unit did not read back as the new state"
            elsif recovered != old_dump && recovered != new_dump
              failures << "#{label}: the engine recovered a state that is neither the old nor the new one"
            end
            state_name = "state_%03d_%04d" % {unit_number, seen.size}
            state.each do |path, bytes|
              File.write(directory / path.sub(DATABASE, "#{state_name}.crash.db"), bytes)
            end
            File.write(directory / "#{state_name}.crash.db", Bytes.empty) unless state.has_key?(DATABASE)
            written << {state_name, old_dump, new_dump}
            failures.uniq!
          end
        end
      end
      database.close
      SQLiteEngineWriteDriver.ruby(["states", directory.to_s, "crash", "4"])
      written.each do |state_name, old_dump, new_dump|
        sqlite3_checked += 1
        integrity = File.read(directory / "#{state_name}.crash.integrity")
        unless integrity == "ok\n"
          failures << "#{name} (seed #{sequence.seed}) #{state_name}: sqlite3 integrity_check: #{integrity.strip[0, 300]}"
          next
        end
        expected = canonical(File.read(directory / "#{state_name}.crash.expected"))
        unless expected == old_dump || expected == new_dump
          failures << "#{name} (seed #{sequence.seed}) #{state_name}: sqlite3 recovered a state that is neither the old nor the new one"
        end
      end
      FileUtils.rm_rf(directory) if failures.empty?
    end
    Summary.new(count, units, crash_points, states_checked, sqlite3_checked, failures)
  end
end
