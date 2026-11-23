require "spec"
require "json"
require "../../../../src/grant/sqlite_engine"

# Builds fixtures with the sqlite3 tool (fixtures/generate.rb) and compares
# what Grant's engine reads from each file with what C SQLite returns.
module SQLiteEngineDifferential
  GENERATOR = Path[__DIR__].parent / "fixtures" / "generate.rb"
  CORPUS    = Path[__DIR__].parent / "corpus" / "grant_sql_corpus.txt"
  RUBY      = File.exists?("/usr/bin/ruby") ? "/usr/bin/ruby" : "ruby"

  # One fixture from a generator manifest.
  struct ManifestEntry
    include JSON::Serializable

    getter name : String
    getter kind : String
    getter sha256 : String
    getter wal_sha256 : String?
    getter seed : Int64?
    getter create_statements : Int32?
    getter create_statements_accepted : Int32?
    getter tables : Int32?
    getter rows : Int32?
  end

  struct Manifest
    include JSON::Serializable

    getter mode : String
    getter seed : Int64
    getter sqlite3_version : String
    getter fixtures : Array(ManifestEntry)
  end

  # The outcome of comparing one fixture.
  record Comparison, fixture : String, lines : Int32, objects : Int32, first_difference : String?

  @@generated = {} of String => {Path, Manifest}

  # Runs the generator once per mode and arguments, into a temporary
  # directory that lives for the spec run.
  def self.generate(mode : String, arguments : Array(String) = [] of String) : {Path, Manifest}
    key = ([mode] + arguments).join(' ')
    if cached = @@generated[key]?
      return cached
    end
    directory = Path[Dir.tempdir] / "grant-sqlite-engine-#{Process.pid}-#{mode}-#{@@generated.size}"
    Dir.mkdir_p(directory)
    output = IO::Memory.new
    status = Process.run(RUBY, [GENERATOR.to_s, mode, directory.to_s] + arguments, output: output, error: output)
    raise "fixture generator failed:\n#{output}" unless status.success?
    manifest = Manifest.from_json(File.read(directory / "manifest.json"))
    @@generated[key] = {directory, manifest}
  end

  # Reads the fixture with the engine and compares every line of its dump
  # with the expected dump C SQLite produced.
  def self.compare(directory : Path, fixture : String) : Comparison
    expected = File.read_lines(directory / "#{fixture}.expected")
    database = Grant::SQLiteEngine::Database.open(directory / "#{fixture}.db")
    actual = String.build { |io| Grant::SQLiteEngine::Dump.new(database).write(io) }.lines
    database.close
    objects = expected.count(&.starts_with?("# "))
    difference = nil
    if expected.size != actual.size
      difference = "expected #{expected.size} lines, read #{actual.size}"
    end
    expected.each_with_index do |line, index|
      read = actual[index]?
      next if read && canonical(line) == canonical(read)
      difference = "line #{index + 1}: expected #{line[0, 400]}\n  read     #{read.to_s[0, 400]}"
      break
    end
    Comparison.new(fixture, expected.size, objects, difference)
  end

  # Rewrites a JSON line through one builder so both sides escape strings the
  # same way; header lines pass through.
  def self.canonical(line : String) : String
    return line if line.starts_with?("# ")
    String.build do |io|
      JSON.build(io) do |builder|
        copy_value(JSON::PullParser.new(line), builder)
      end
    end
  end

  private def self.copy_value(parser : JSON::PullParser, builder : JSON::Builder) : Nil
    case parser.kind
    when .begin_array?
      builder.array do
        parser.read_array { copy_value(parser, builder) }
      end
    when .begin_object?
      builder.object do
        parser.read_object do |key|
          builder.field(key) { copy_value(parser, builder) }
        end
      end
    when .string?
      builder.scalar(parser.read_string)
    when .int?
      builder.scalar(parser.read_int)
    when .float?
      builder.scalar(parser.read_float)
    when .bool?
      builder.scalar(parser.read_bool)
    else
      parser.read_null
      builder.null
    end
  end

  # The file's sha256, from the system tool (the specs link no crypto
  # library).
  def self.sha256(path : Path) : String
    output = IO::Memory.new
    status = Process.run("shasum", ["-a", "256", path.to_s], output: output)
    status = Process.run("sha256sum", [path.to_s], output: output) unless status.success?
    raise "no sha256 tool for #{path}" unless status.success?
    output.to_s.split(' ').first
  end
end
