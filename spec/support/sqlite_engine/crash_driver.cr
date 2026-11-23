require "./write_driver"

# Runs random write sequences on the crash simulator's file system and, for
# every write unit (one statement, or one transaction), checks every crash
# point: each prefix of the unit's writes, syncs, truncates and deletes,
# with unsynced writes kept, lost or torn. The engine (reopening the files,
# which rolls back a hot journal) and the sqlite3 tool must each find
# exactly the state before the unit or the state after it.
#
# In WAL mode the units also include checkpoints (passive, full, restart,
# truncate, and the automatic ones a small wal_autocheckpoint starts), the
# wal-index writes are crash points too, and a process crash that leaves
# the wal-index to a surviving process is checked as well.
module SQLiteEngineCrashDriver
  DATABASE = "crash.db"
  # Frames that start an automatic checkpoint in WAL mode: small, so most
  # sequences checkpoint and start the WAL over several times.
  WAL_AUTOCHECKPOINT = 6
  # Survivor states checked by one sqlite3 batch; the driver holds one
  # descriptor per state while it runs.
  SURVIVOR_BATCH = 120

  record Summary, sequences : Int32, units : Int32, crash_points : Int32, states_checked : Int32,
    sqlite3_states_checked : Int32, list_of_failures : Array(String)

  def self.engine_dump(database : Grant::SQLiteEngine::Database) : String
    canonical(String.build { |io| Grant::SQLiteEngine::Dump.new(database).write(io) })
  end

  def self.canonical(dump : String) : String
    dump.lines.map { |line| SQLiteEngineDifferential.canonical(line) }.join('\n')
  end

  def self.state_key(state : Hash(String, Bytes), survivor : Bool) : UInt64
    hasher = Crystal::Hasher.new
    hasher = survivor.hash(hasher)
    state.keys.sort!.each do |path|
      hasher = path.hash(hasher)
      hasher = state[path].hash(hasher)
    end
    hasher.result
  end

  # One step a crash may interrupt: a unit of the sequence, or (in WAL
  # mode) a checkpoint.
  alias Step = {Array(SQLiteEngineWriteDriver::Operation), Bool?} | Grant::SQLiteEngine::CheckpointMode

  def self.list_of_steps(sequence : SQLiteEngineWriteDriver::Sequence, wal : Bool, random : Random) : Array(Step)
    steps = [] of Step
    sequence.list_of_units.each do |unit|
      steps << unit
      steps << Grant::SQLiteEngine::CheckpointMode.from_value(random.rand(4)) if wal && random.rand(3) == 0
    end
    steps
  end

  def self.run(count : Int32, seed : Int64, wal : Bool = false,
               synchronous : Grant::SQLiteEngine::Synchronous = Grant::SQLiteEngine::Synchronous::Full) : Summary
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
        text_encoding: sequence.text_encoding, file_system: file_system,
        journal_mode: wal ? Grant::SQLiteEngine::JournalMode::Wal : nil,
        synchronous: synchronous, wal_autocheckpoint: WAL_AUTOCHECKPOINT)
      outcome = SQLiteEngineWriteDriver::Outcome.new
      written = [] of {String, String, String, Bool}
      list_of_steps(sequence, wal, Random.new(seed + number)).each_with_index do |step, unit_number|
        before = file_system.snapshot
        old_dump = engine_dump(database)
        file_system.start_recording
        if step.is_a?(Grant::SQLiteEngine::CheckpointMode)
          database.checkpoint(step)
        else
          SQLiteEngineWriteDriver.apply_unit(database, step, outcome)
        end
        operations = file_system.stop_recording
        new_dump = engine_dump(database)
        units += 1
        crash_points += operations.size + 1
        seen = Set(UInt64).new
        (0..operations.size).each do |prefix|
          SQLiteEngineCrashFileSystem::Variant.each do |variant|
            state = SQLiteEngineCrashFileSystem.crash_state(before, operations, prefix, variant)
            next unless state
            survivor = variant.process_crash?
            next unless seen.add?(state_key(state, survivor))
            states_checked += 1
            label = "#{name} (seed #{sequence.seed}) step #{unit_number} #{step.is_a?(Grant::SQLiteEngine::CheckpointMode) ? step : "unit"} prefix #{prefix}/#{operations.size} #{variant}"
            recovered = begin
              reopened = Grant::SQLiteEngine::Database.open(DATABASE, read_write: true,
                file_system: SQLiteEngineCrashFileSystem.new(state.transform_values(&.dup), survivor: survivor))
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
              failures << "#{label}: the engine recovered a state that is neither the old nor the new one " \
                          "(against the old: #{first_difference(old_dump, recovered)}; against the new: #{first_difference(new_dump, recovered)})"
            end
            state_name = "state_%03d_%04d" % {unit_number, seen.size}
            state_directory = survivor ? directory / "survivor_#{written.count(&.[3]) // SURVIVOR_BATCH}" : directory
            Dir.mkdir_p(state_directory)
            state.each do |path, bytes|
              File.write(state_directory / path.sub(DATABASE, "#{state_name}.crash.db"), bytes)
            end
            File.write(state_directory / "#{state_name}.crash.db", Bytes.empty) unless state.has_key?(DATABASE)
            written << {state_name, old_dump, new_dump, survivor}
            failures.uniq!
          end
        end
      end
      database.close
      SQLiteEngineWriteDriver.ruby(["states", directory.to_s, "crash", "4"])
      Dir.glob((directory / "survivor_*").to_s).sort.each { |batch| verify_survivors(Path[batch]) }
      written.each do |state_name, old_dump, new_dump, survivor|
        sqlite3_checked += 1
        state_directory = survivor ? Dir.glob((directory / "survivor_*" / "#{state_name}.crash.db").to_s).first?.try { |file| Path[file].parent } : directory
        integrity_path = state_directory.try { |found| found / "#{state_name}.crash.integrity" }
        unless integrity_path && File.exists?(integrity_path)
          failures << "#{name} (seed #{sequence.seed}) #{state_name}: sqlite3 wrote no result"
          next
        end
        integrity = File.read(integrity_path)
        unless integrity == "ok\n"
          failures << "#{name} (seed #{sequence.seed}) #{state_name}#{survivor ? " (survivor)" : ""}: sqlite3 integrity_check: #{integrity.strip[0, 300]}"
          next
        end
        expected = canonical(File.read(integrity_path.parent / "#{state_name}.crash.expected"))
        unless expected == old_dump || expected == new_dump
          failures << "#{name} (seed #{sequence.seed}) #{state_name}#{survivor ? " (survivor)" : ""}: sqlite3 recovered a state that is neither the old nor the new one"
        end
      end
      FileUtils.rm_rf(directory) if failures.empty?
    end
    Summary.new(count, units, crash_points, states_checked, sqlite3_checked, failures)
  end

  def self.first_difference(expected : String, actual : String) : String
    expected_lines = expected.lines
    actual_lines = actual.lines
    expected_lines.each_with_index do |line, index|
      return "line #{index + 1}: expected #{line[0, 160]} | read #{actual_lines[index]?.to_s[0, 160]}" if actual_lines[index]? != line
    end
    "read #{actual_lines.size - expected_lines.size} more lines"
  end

  # Checks the survivor states of *batch* with sqlite3 while this process
  # holds each wal-index's dead man switch shared, as the surviving process
  # would, so sqlite3 reads the wal-index as the crash left it.
  def self.verify_survivors(batch : Path) : Nil
    list_of_held = [] of File
    begin
      Dir.glob((batch / "*.crash.db-shm").to_s).each do |shm|
        file = File.open(shm, "r+b")
        list_of_held << file
        request = Grant::SQLiteEngine::LibFileLock::Flock.new
        request.l_type = Grant::SQLiteEngine::LibFileLock::F_RDLCK.to_i16
        request.l_whence = IO::Seek::Set.value.to_i16
        request.l_start = Grant::SQLiteEngine::SharedMemory::DEAD_MAN_BYTE
        request.l_len = 1_i64
        Grant::SQLiteEngine::LibFileLock.fcntl(file.fd, Grant::SQLiteEngine::LibFileLock::F_SETLK, pointerof(request))
      end
      SQLiteEngineWriteDriver.ruby(["states", batch.to_s, "crash", "4"])
    ensure
      list_of_held.each(&.close)
    end
  end
end
