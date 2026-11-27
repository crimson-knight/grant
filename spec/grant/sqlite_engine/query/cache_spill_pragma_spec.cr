require "spec"
require "file_utils"
require "../../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../../src/grant/drivers/sqlite3/libsqlite3"
require "../../../support/sqlite_engine/reference_library"

# PRAGMA cache_size and cache_spill on Grant's engine and on the linked C
# SQLite, each in a connection of its own: the defaults a new connection
# reads, and what each value of cache_spill sets (pragma.c's
# PragTyp_CACHE_SPILL, pcache.c's sqlite3PcacheSetSpillsize).
private module CacheSpillPragma
  alias Engine = Grant::SQLite3::Engine

  # Each statement's result code and rows, one line per statement.
  def self.outcomes(engine : Engine, path : String, list_of_statements : Array(String)) : Array(String)
    FileUtils.rm_rf(path)
    code, database = engine.open(path)
    raise "open failed (#{code})" unless code == Engine::OK_CODE
    begin
      list_of_statements.map do |sql|
        code, statement = database.prepare(sql)
        next "#{sql} => prepare #{code}" unless code == Engine::OK_CODE
        list_of_rows = [] of String
        step = statement.step
        while step == Engine::ROW_CODE
          list_of_rows << statement.column_text(0)
          step = statement.step
        end
        columns = (0...statement.column_count).join(",") { |index| statement.column_name(index) }
        statement.finalize_statement
        "#{sql} => #{step} [#{columns}] #{list_of_rows}"
      end
    ensure
      database.close
    end
  end

  def self.both(list_of_statements : Array(String)) : {Array(String), Array(String)}
    directory = File.tempname("cache-spill-pragma")
    Dir.mkdir_p(directory)
    begin
      c_lines = outcomes(Engine::LibSQLite3Engine.new, File.join(directory, "c.db"), list_of_statements)
      engine_lines = outcomes(Engine::GrantEngine.new, File.join(directory, "grant.db"), list_of_statements)
      {engine_lines, c_lines}
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  def self.c_answer(sql : String) : String
    code, database = Engine::LibSQLite3Engine.new.open(":memory:")
    raise "open failed (#{code})" unless code == Engine::OK_CODE
    code, statement = database.prepare(sql)
    answer = code == Engine::OK_CODE && statement.step == Engine::ROW_CODE ? statement.column_text(0) : ""
    statement.finalize_statement
    database.close
    answer
  end

  # Apple's build marks its source id with "apl".
  class_getter? linked_to_apple_build : Bool { c_answer("SELECT sqlite_source_id()").ends_with?("apl") }

  # True when the linked C library is the build this platform ships, whose
  # defaults the engine takes: Apple's on macOS, an upstream one elsewhere.
  def self.platform_build? : Bool
    {% if flag?(:darwin) %}
      linked_to_apple_build?
    {% else %}
      !linked_to_apple_build?
    {% end %}
  end

  # Every statement starts from the same settings in both libraries
  # (cache_spill=1 is upstream's own szSpill), so the defaults of the
  # platform's build do not enter.
  START = ["PRAGMA cache_size=-2000", "PRAGMA cache_spill=1"]

  # Values on which Apple's build and upstream's pragma.c agree.
  LIST_OF_SEQUENCES = [
    ["PRAGMA cache_spill"],
    ["PRAGMA cache_spill=-4000", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=5000", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=50000", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=300", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=300", "PRAGMA cache_size=5000", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=off", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=OFF", "PRAGMA cache_spill=on", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=-4000", "PRAGMA cache_spill=false", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill='no'", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill = 0x10", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=2.5", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill='-1'", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=yes", "PRAGMA cache_spill"],
    ["PRAGMA main.cache_spill=2600", "PRAGMA main.cache_spill"],
    ["PRAGMA cache_size=100", "PRAGMA cache_spill=-1000", "PRAGMA cache_size=-8000", "PRAGMA cache_spill"],
  ]

  # Values Apple's build answers otherwise (it turns spills on for any
  # integer, and resets szSpill on ON or 0); upstream's pragma.c only.
  LIST_OF_UPSTREAM_SEQUENCES = [
    ["PRAGMA cache_spill=0", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=-0", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=256", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=30000", "PRAGMA cache_spill=on", "PRAGMA cache_spill"],
    ["PRAGMA cache_spill=99999999999", "PRAGMA cache_spill"],
  ]
end

describe "Grant::SQLiteEngine PRAGMA cache_spill" do
  it "starts with the page cache defaults of the C library this platform ships" do
    statements = ["PRAGMA cache_size", "PRAGMA cache_spill"]
    engine_lines, c_lines = CacheSpillPragma.both(statements)
    {% if flag?(:darwin) %}
      engine_lines.should eq(["PRAGMA cache_size => 101 [cache_size] [\"2000\"]", "PRAGMA cache_spill => 101 [cache_spill] [\"20000\"]"])
    {% else %}
      engine_lines.should eq(["PRAGMA cache_size => 101 [cache_size] [\"-2000\"]", "PRAGMA cache_spill => 101 [cache_spill] [\"483\"]"])
    {% end %}
    engine_lines.should eq(c_lines) if CacheSpillPragma.platform_build? && SQLiteEngineReferenceLibrary.linked?
  end

  it "reads the same default at every page size" do
    {1024, 4096, 65536}.each do |page_size|
      statements = ["PRAGMA page_size=#{page_size}", "CREATE TABLE t (x)", "PRAGMA cache_spill"]
      engine_lines, c_lines = CacheSpillPragma.both(statements)
      {% if flag?(:darwin) %}
        engine_lines.last.should end_with("[\"20000\"]")
      {% end %}
      engine_lines.last.should eq(c_lines.last) if CacheSpillPragma.platform_build? && SQLiteEngineReferenceLibrary.linked?
    end
  end

  it "reads and sets the spill size and switch as C does" do
    CacheSpillPragma::LIST_OF_SEQUENCES.each do |sequence|
      engine_lines, c_lines = CacheSpillPragma.both(CacheSpillPragma::START + sequence)
      engine_lines.should eq(c_lines)
    end
  end

  it "reads and sets as upstream's pragma.c does where Apple's build differs" do
    pending!("Apple's build answers these otherwise") if CacheSpillPragma.linked_to_apple_build?
    CacheSpillPragma::LIST_OF_UPSTREAM_SEQUENCES.each do |sequence|
      engine_lines, c_lines = CacheSpillPragma.both(CacheSpillPragma::START + sequence)
      engine_lines.should eq(c_lines)
    end
  end
end
