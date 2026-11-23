require "json"
require "file_utils"
require "./differential"
require "./crash_file"

# Applies the random write sequences fixtures/operations.rb generates
# through the engine's write API, and compares the files the engine writes
# with the files the sqlite3 tool built from the same operations.
module SQLiteEngineWriteDriver
  OPERATIONS = SQLiteEngineDifferential::ENGINE_SPECS / "fixtures" / "operations.rb"

  # A value as the generator writes it: exactly one key is set, or the
  # value is JSON null.
  struct TypedValue
    include JSON::Serializable

    @[JSON::Field(key: "i")]
    getter integer_text : String? = nil
    @[JSON::Field(key: "r")]
    getter real_bits : String? = nil
    @[JSON::Field(key: "t")]
    getter text : String? = nil
    @[JSON::Field(key: "b")]
    getter blob_hex : String? = nil

    def to_value : Grant::SQLiteEngine::Value
      if integer = @integer_text
        return integer.to_i64
      end
      if bits = @real_bits
        return bits.to_u64(16).unsafe_as(Float64)
      end
      if text = @text
        return text
      end
      if blob = @blob_hex
        return blob.hexbytes
      end
      nil
    end
  end

  struct Operation
    include JSON::Serializable

    getter op : String
    getter table : String? = nil
    getter rowid : String? = nil
    getter sql : String? = nil
    getter name : String? = nil
    @[JSON::Field(key: "values")]
    getter list_of_values : Array(TypedValue?)? = nil
    @[JSON::Field(key: "key")]
    getter list_of_key_values : Array(TypedValue?)? = nil
  end

  struct Sequence
    include JSON::Serializable

    getter page_size : Int32
    getter encoding : String
    getter seed : Int64
    @[JSON::Field(key: "operations")]
    getter list_of_operations : Array(Operation)

    def text_encoding : Grant::SQLiteEngine::TextEncoding
      case @encoding
      when "UTF-16le" then Grant::SQLiteEngine::TextEncoding::UTF16LE
      when "UTF-16be" then Grant::SQLiteEngine::TextEncoding::UTF16BE
      else                 Grant::SQLiteEngine::TextEncoding::UTF8
      end
    end

    # The operations grouped into units: one operation, or the operations
    # of a BEGIN ... COMMIT/ROLLBACK block.
    def list_of_units : Array({Array(Operation), Bool?})
      units = [] of {Array(Operation), Bool?}
      position = 0
      while position < @list_of_operations.size
        operation = @list_of_operations[position]
        if operation.op == "begin"
          finish = (position + 1...@list_of_operations.size).find { |index| @list_of_operations[index].op.in?("commit", "rollback") } || @list_of_operations.size
          ending = @list_of_operations[finish]?
          units << {@list_of_operations[position + 1...finish], ending.nil? || ending.op == "commit"}
          position = finish + 1
        else
          units << {[operation], nil}
          position += 1
        end
      end
      units
    end
  end

  # What applying a sequence did: the statements the engine rejected, and
  # the messages of rejections other than constraint and schema errors.
  class Outcome
    property errors = 0
    getter list_of_messages = [] of String
    getter list_of_unexpected = [] of String
  end

  def self.values(list : Array(TypedValue?)?) : Array(Grant::SQLiteEngine::Value)
    (list || [] of TypedValue?).map { |typed| typed.try(&.to_value) }
  end

  # Applies one unit (see `Sequence#list_of_units`).
  def self.apply_unit(database : Grant::SQLiteEngine::Database, unit : {Array(Operation), Bool?}, outcome : Outcome) : Nil
    operations, commit = unit
    if commit.nil?
      apply(database, operations.first, outcome)
      return
    end
    database.transaction do |writer|
      operations.each { |operation| apply(writer, operation, outcome) }
      raise Grant::SQLiteEngine::Rollback.new unless commit
    end
  end

  def self.apply(database : Grant::SQLiteEngine::Database, operation : Operation, outcome : Outcome) : Nil
    table = operation.table || ""
    case operation.op
    when "create_table" then database.create_table(operation.sql || "")
    when "create_index" then database.create_index(operation.sql || "")
    when "drop"         then database.drop(operation.name || "")
    when "insert"       then database.insert(table, operation.rowid.try(&.to_i64), values(operation.list_of_values))
    when "update"       then database.update(table, (operation.rowid || "0").to_i64, values(operation.list_of_values))
    when "delete"       then database.delete(table, (operation.rowid || "0").to_i64)
    when "update_key"   then database.update(table, values(operation.list_of_key_values), values(operation.list_of_values))
    when "delete_key"   then database.delete(table, values(operation.list_of_key_values))
    else                     raise "unknown operation #{operation.op}"
    end
  rescue error : Grant::SQLiteEngine::ConstraintViolation | Grant::SQLiteEngine::SchemaError | Grant::SQLiteEngine::UnknownSchemaObject
    outcome.errors += 1
    outcome.list_of_messages << "#{operation.op} #{table}: #{error.message}"
  rescue error : Grant::SQLiteEngine::Error
    outcome.errors += 1
    outcome.list_of_unexpected << "#{operation.op}: #{error.class}: #{error.message}"
  end

  # Writes *sequence* to *path* through the engine. In WAL mode the engine
  # commits with synchronous=NORMAL (Grant's setting) and checkpoints
  # automatically; *checks* runs while the engine still has the database
  # open, so sqlite3 reads the frames through the engine's wal-index.
  def self.build(sequence : Sequence, path : String, wal : Bool = false, & : ->) : Outcome
    File.delete?(path)
    outcome = Outcome.new
    database = Grant::SQLiteEngine::Database.open(path, read_write: true, page_size: sequence.page_size, text_encoding: sequence.text_encoding,
      journal_mode: wal ? Grant::SQLiteEngine::JournalMode::Wal : nil,
      synchronous: wal ? Grant::SQLiteEngine::Synchronous::Normal : Grant::SQLiteEngine::Synchronous::Full)
    sequence.list_of_units.each { |unit| apply_unit(database, unit, outcome) }
    yield
    database.close
    outcome
  end

  def self.build(sequence : Sequence, path : String, wal : Bool = false) : Outcome
    build(sequence, path, wal) { }
  end

  def self.ruby(arguments : Array(String)) : Nil
    output = IO::Memory.new
    status = Process.run(SQLiteEngineDifferential::RUBY, [OPERATIONS.to_s] + arguments, output: output, error: output)
    raise "operations.rb #{arguments.first} failed:\n#{output}" unless status.success?
  end

  # Compares two canonical dumps line by line; returns the first difference.
  def self.first_difference(expected : String, actual : String) : String?
    expected_lines = expected.lines
    actual_lines = actual.lines
    expected_lines.each_with_index do |line, index|
      other = actual_lines[index]?
      next if other && SQLiteEngineDifferential.canonical(line) == SQLiteEngineDifferential.canonical(other)
      return "line #{index + 1}: C #{line[0, 300]} | engine #{other.to_s[0, 300]}"
    end
    return "C has #{expected_lines.size} lines, engine #{actual_lines.size}" if expected_lines.size != actual_lines.size
    nil
  end

  def self.engine_dump(path : String) : String
    database = Grant::SQLiteEngine::Database.open(path)
    String.build { |io| Grant::SQLiteEngine::Dump.new(database).write(io) }
  ensure
    database.try &.close
  end

  record Summary, sequences : Int32, operations : Int32, rows_compared : Int32, list_of_failures : Array(String), list_of_unexpected : Array(String)

  # Generates, applies and checks *count* sequences from *seed*, in chunks
  # so the files never pile up. Failing files are copied to *keep* when set.
  #
  # With *wal*, both sides write in journal_mode=WAL, and every tenth
  # sequence is read by sqlite3 (integrity_check and a row count) while the
  # engine still holds it open with frames in the WAL.
  def self.run(count : Int32, seed : Int64, size : String = "regular", chunk : Int32 = 200, keep : String? = nil, wal : Bool = false) : Summary
    failures = [] of String
    unexpected = [] of String
    operations = 0
    rows = 0
    start = 0
    while start < count
      batch = Math.min(chunk, count - start)
      directory = Path[Dir.tempdir] / "grant-sqlite-engine-writes-#{Process.pid}-#{start}"
      Dir.mkdir_p(directory)
      ruby(["sequences", directory.to_s, "--count", batch.to_s, "--seed", seed.to_s, "--start", start.to_s, "--size", size, "--wal", wal ? "1" : "0"])
      ruby(["verify", directory.to_s, "c"])
      batch.times do |offset|
        name = "seq_%05d" % (start + offset)
        sequence = Sequence.from_json(File.read(directory / "#{name}.json"))
        operations += sequence.list_of_operations.size
        engine_path = (directory / "#{name}.e.db").to_s
        outcome = build(sequence, engine_path, wal) do
          if wal && (start + offset) % 10 == 0
            if problem = live_wal_problem(engine_path)
              failures << "#{name}: #{problem}"
            end
          end
        end
        File.write(directory / "#{name}.e.errors", ([outcome.errors.to_s] + outcome.list_of_messages).join('\n'))
        outcome.list_of_unexpected.first(3).each { |message| unexpected << "#{name} (seed #{sequence.seed}): #{message}" }
      end
      ruby(["verify", directory.to_s, "e"])
      batch.times do |offset|
        name = "seq_%05d" % (start + offset)
        problem = check(directory, name, wal)
        rows += File.read(directory / "#{name}.c.expected").count('\n') if File.exists?(directory / "#{name}.c.expected")
        next unless problem
        failures << "#{name}: #{problem}"
        if keep
          Dir.mkdir_p(keep)
          Dir.glob((directory / "#{name}.*").to_s).each { |file| File.copy(file, Path[keep] / Path[file].basename) }
        end
      end
      FileUtils.rm_rf(directory)
      start += batch
    end
    Summary.new(count, operations, rows, failures, unexpected)
  end

  # sqlite3 reading a database the engine holds open in WAL mode: the
  # integrity check passes, and it reads the same rows as a later read of
  # the checkpointed file (checked in `check`).
  def self.live_wal_problem(path : String) : String?
    output = IO::Memory.new
    status = Process.run("sqlite3", [path, "PRAGMA integrity_check;"], output: output, error: output)
    return "sqlite3 on the live WAL database: #{output.to_s.strip[0, 300]}" unless status.success? && output.to_s == "ok\n"
    nil
  end

  # The first way the engine's file differs from the C file, or nil.
  def self.check(directory : Path, name : String, wal : Bool = false) : String?
    integrity = File.read(directory / "#{name}.e.integrity")
    return "integrity_check: #{integrity.strip[0, 400]}" unless integrity == "ok\n"
    if wal
      header = Bytes.new(20)
      File.open(directory / "#{name}.e.db", "rb") { |file| file.read_fully(header) }
      return "the engine's file is not in WAL mode (header bytes 18, 19: #{header[18]}, #{header[19]})" unless header[18] == 2 && header[19] == 2
    end
    c_errors = File.read(directory / "#{name}.c.errors").strip
    e_errors = File.read(directory / "#{name}.e.errors").lines.first?.to_s.strip
    return "sqlite3 rejected #{c_errors} statements, the engine #{e_errors}" unless c_errors == e_errors
    c_schema = File.read(directory / "#{name}.c.schema")
    e_schema = File.read(directory / "#{name}.e.schema")
    return "schema differs: C #{c_schema[0, 600]} | engine #{e_schema[0, 600]}" unless c_schema == e_schema
    expected = File.read(directory / "#{name}.c.expected")
    if difference = first_difference(expected, File.read(directory / "#{name}.e.expected"))
      return "sqlite3 reads the engine's file differently: #{difference}"
    end
    if difference = first_difference(expected, engine_dump((directory / "#{name}.e.db").to_s))
      return "the engine reads its own file differently: #{difference}"
    end
    nil
  end
end
