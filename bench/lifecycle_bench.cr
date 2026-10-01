# bench/lifecycle_bench.cr
#
# Record lifecycle benchmark: what one model costs at runtime, measured three
# ways against the same table on the same adapter.
#
#   raw           crystal-db with SQL strings; rows are read into tuples, no
#                 objects. The floor: nothing is parsed into a type.
#   serializable  crystal-db with rows parsed into a DB::Serializable struct.
#                 The floor for "SQL plus objects", with no ORM.
#   grant         the Grant model API (create!, find!, where, save!, destroy!).
#
# Each variant runs the same operations: build an object in memory, create,
# find by id, a 100-row indexed page, load every row, count, load-and-update,
# and load-and-destroy. For each operation it reports mean, p50 and p99
# microseconds, heap bytes allocated per operation, and SQL statements per
# operation (counted from crystal-db's own statement log, so the count is the
# same instrument for every variant and every Grant version).
#
# After the operations, each variant runs repeated full cycles (create, find,
# update, destroy) and samples the GC heap and RSS after every cycle. A heap
# that keeps growing across cycles is a leak signal.
#
# The file uses only API that Grant has had since before the parity work, so
# bench/lifecycle_compare.sh can build it unchanged against older revisions.
# It is not part of the spec suite.
#
# --trace prints the SQL each operation runs on its first call.
#
# Usage:
#   BENCH_ADAPTER=sqlite crystal-alpha run --release bench/lifecycle_bench.cr -- \
#     --iterations 2000 --rounds 5 --label current --json /tmp/lifecycle.json
#
# BENCH_ADAPTER (sqlite, pg or mysql) is read at compile time to pick the
# driver. BENCH_DATABASE_URL overrides the default URL for that adapter.

require "json"
require "option_parser"
require "../src/grant"
{% if env("BENCH_ADAPTER") == "pg" %}
  require "../src/adapter/pg"
{% elsif env("BENCH_ADAPTER") == "mysql" %}
  require "../src/adapter/mysql"
{% else %}
  require "../src/adapter/sqlite"
{% end %}

module LifecycleBench
  ADAPTER = {{ env("BENCH_ADAPTER") || "sqlite" }}

  DEFAULT_URLS = {
    "sqlite" => "sqlite3:/tmp/grant_lifecycle_bench.db",
    "pg"     => "postgres://localhost/grant_lifecycle_bench",
    "mysql"  => "mysql://root@localhost/grant_lifecycle_bench",
  }

  DATABASE_URL = ENV["BENCH_DATABASE_URL"]? || DEFAULT_URLS[ADAPTER]

  PAGE_SIZE   = 100
  AGE_SPREAD  =  60
  MEGABYTE    = 1024.0 * 1024.0
  COLUMN_LIST = "id, name, email, age, active, score, created_at, updated_at"

  {% if env("BENCH_ADAPTER") == "pg" %}
    Grant::Connections << Grant::Adapter::Pg.new(name: "bench", url: DATABASE_URL)
  {% elsif env("BENCH_ADAPTER") == "mysql" %}
    Grant::Connections << Grant::Adapter::Mysql.new(name: "bench", url: DATABASE_URL)
  {% else %}
    Grant::Connections << Grant::Adapter::Sqlite.new(name: "bench", url: DATABASE_URL)
  {% end %}

  class BenchPerson < Grant::Base
    connection bench
    table bench_people

    column id : Int64, primary: true
    column name : String
    column email : String
    column age : Int32
    column active : Bool
    column score : Float64
    timestamps
  end

  struct PersonRow
    include DB::Serializable

    getter id : Int64
    getter name : String
    getter email : String
    getter age : Int32
    getter active : Bool
    getter score : Float64
    getter created_at : Time?
    getter updated_at : Time?

    def initialize(@id, @name, @email, @age, @active, @score, @created_at, @updated_at)
    end
  end

  # Deterministic attributes for the i-th record.
  record Attributes, name : String, email : String, age : Int32, active : Bool, score : Float64 do
    def self.for(index : Int32) : Attributes
      new("Person #{index}", "person#{index}@example.com", 18 + index % AGE_SPREAD, index.even?, index * 0.5)
    end
  end

  # Counts the statements crystal-db executes while it is bound.
  # Counts the statements crystal-db executes while it is bound, and keeps the
  # SQL text of those executed while `recording` is set.
  class StatementCounter < Log::Backend
    getter count = 0_i64
    getter list_of_recorded_statements = [] of String
    property recording = false

    def initialize
      super(:direct)
    end

    def write(entry : Log::Entry) : Nil
      return unless entry.message == "Executing query"
      @count += 1
      @list_of_recorded_statements << entry.data[:query].to_s if recording
    end
  end

  class_property trace = false

  struct OperationResult
    include JSON::Serializable

    getter operation : String
    getter iterations : Int32
    getter total_seconds : Float64
    getter mean_microseconds : Float64
    getter p50_microseconds : Float64
    getter p99_microseconds : Float64
    getter bytes_per_operation : Float64
    getter statements_per_operation : Float64

    def initialize(@operation, @iterations, @total_seconds, @mean_microseconds, @p50_microseconds,
                   @p99_microseconds, @bytes_per_operation, @statements_per_operation)
    end
  end

  struct RoundSample
    include JSON::Serializable

    getter round : Int32
    getter heap_megabytes : Float64
    getter rss_megabytes : Float64

    def initialize(@round, @heap_megabytes, @rss_megabytes)
    end
  end

  struct VariantResult
    include JSON::Serializable

    getter variant : String
    getter list_of_operations : Array(OperationResult)
    getter list_of_rounds : Array(RoundSample)

    def initialize(@variant, @list_of_operations, @list_of_rounds)
    end
  end

  struct RunResult
    include JSON::Serializable

    getter label : String
    getter adapter : String
    getter iterations : Int32
    getter crystal_version : String
    getter list_of_variants : Array(VariantResult)

    def initialize(@label, @adapter, @iterations, @crystal_version, @list_of_variants)
    end
  end

  # Values written here keep the optimizer from discarding a result.
  class_property checksum = 0.0

  def self.placeholder(position : Int32) : String
    ADAPTER == "pg" ? "$#{position}" : "?"
  end

  def self.rss_megabytes : Float64
    kilobytes = `ps -o rss= -p #{Process.pid}`.strip.to_i64?
    kilobytes ? kilobytes / 1024.0 : GC.stats.heap_size / MEGABYTE
  end

  abstract class Variant
    getter name : String

    def initialize(@name : String)
    end

    # Recreates the table from the model, so every variant gets the same schema.
    def reset_table : Nil
      BenchPerson.migrator.drop_and_create
      BenchPerson.exec("CREATE INDEX bench_people_age ON bench_people (age)")
    end

    abstract def build(index : Int32) : Nil
    abstract def create(index : Int32) : Int64
    abstract def find(id : Int64) : Nil
    abstract def page(age : Int32) : Int32
    abstract def load_all : Int32
    abstract def count_active : Int64
    abstract def update(id : Int64) : Nil
    abstract def destroy(id : Int64) : Nil
  end

  # Shared SQL for the two crystal-db variants.
  abstract class SqlVariant < Variant
    @insert_sql : String
    @find_sql : String
    @page_sql : String
    @all_sql : String
    @count_sql : String
    @update_sql : String
    @delete_sql : String

    def initialize(name : String, @database : DB::Database)
      super(name)
      placeholder_at = ->(position : Int32) { LifecycleBench.placeholder(position) }
      @insert_sql = "INSERT INTO bench_people (name, email, age, active, score, created_at, updated_at) " \
                    "VALUES (#{placeholder_at.call(1)}, #{placeholder_at.call(2)}, #{placeholder_at.call(3)}, #{placeholder_at.call(4)}, #{placeholder_at.call(5)}, #{placeholder_at.call(6)}, #{placeholder_at.call(7)})"
      @insert_sql += " RETURNING id" if ADAPTER == "pg"
      @find_sql = "SELECT #{COLUMN_LIST} FROM bench_people WHERE id = #{placeholder_at.call(1)}"
      @page_sql = "SELECT #{COLUMN_LIST} FROM bench_people WHERE age = #{placeholder_at.call(1)} LIMIT #{PAGE_SIZE}"
      @all_sql = "SELECT #{COLUMN_LIST} FROM bench_people"
      @count_sql = "SELECT COUNT(*) FROM bench_people WHERE active = #{placeholder_at.call(1)}"
      @update_sql = "UPDATE bench_people SET score = #{placeholder_at.call(1)}, updated_at = #{placeholder_at.call(2)} WHERE id = #{placeholder_at.call(3)}"
      @delete_sql = "DELETE FROM bench_people WHERE id = #{placeholder_at.call(1)}"
    end

    def create(index : Int32) : Int64
      attributes = Attributes.for(index)
      now = Time.utc
      if ADAPTER == "pg"
        @database.query_one(@insert_sql, attributes.name, attributes.email, attributes.age, attributes.active,
          attributes.score, now, now, as: Int64)
      else
        @database.exec(@insert_sql, attributes.name, attributes.email, attributes.age, attributes.active,
          attributes.score, now, now).last_insert_id
      end
    end

    def count_active : Int64
      @database.scalar(@count_sql, true).as(Int).to_i64
    end

    def destroy(id : Int64) : Nil
      find(id)
      @database.exec(@delete_sql, id)
    end
  end

  # crystal-db with no objects: columns are read straight into a tuple.
  class RawVariant < SqlVariant
    def build(index : Int32) : Nil
      attributes = Attributes.for(index)
      tuple = {0_i64, attributes.name, attributes.email, attributes.age, attributes.active, attributes.score}
      LifecycleBench.checksum += tuple[5]
    end

    def find(id : Int64) : Nil
      row = @database.query_one(@find_sql, id) { |result_set| read_row(result_set) }
      LifecycleBench.checksum += row[5]
    end

    def page(age : Int32) : Int32
      loaded = 0
      @database.query_each(@page_sql, age) do |result_set|
        LifecycleBench.checksum += read_row(result_set)[5]
        loaded += 1
      end
      loaded
    end

    def load_all : Int32
      loaded = 0
      @database.query_each(@all_sql) do |result_set|
        LifecycleBench.checksum += read_row(result_set)[5]
        loaded += 1
      end
      loaded
    end

    def update(id : Int64) : Nil
      row = @database.query_one(@find_sql, id) { |result_set| read_row(result_set) }
      @database.exec(@update_sql, row[5] + 1.0, Time.utc, id)
    end

    private def read_row(result_set : DB::ResultSet)
      {result_set.read(Int64), result_set.read(String), result_set.read(String), result_set.read(Int32),
       result_set.read(Bool), result_set.read(Float64), result_set.read(Time?), result_set.read(Time?)}
    end
  end

  # crystal-db with rows parsed into a DB::Serializable struct.
  class SerializableVariant < SqlVariant
    def build(index : Int32) : Nil
      attributes = Attributes.for(index)
      row = PersonRow.new(0_i64, attributes.name, attributes.email, attributes.age, attributes.active,
        attributes.score, nil, nil)
      LifecycleBench.checksum += row.score
    end

    def find(id : Int64) : Nil
      LifecycleBench.checksum += @database.query_one(@find_sql, id, as: PersonRow).score
    end

    def page(age : Int32) : Int32
      rows = @database.query_all(@page_sql, age, as: PersonRow)
      rows.each { |row| LifecycleBench.checksum += row.score }
      rows.size
    end

    def load_all : Int32
      rows = @database.query_all(@all_sql, as: PersonRow)
      rows.each { |row| LifecycleBench.checksum += row.score }
      rows.size
    end

    def update(id : Int64) : Nil
      row = @database.query_one(@find_sql, id, as: PersonRow)
      @database.exec(@update_sql, row.score + 1.0, Time.utc, id)
    end
  end

  class GrantVariant < Variant
    def build(index : Int32) : Nil
      attributes = Attributes.for(index)
      person = BenchPerson.new(name: attributes.name, email: attributes.email, age: attributes.age,
        active: attributes.active, score: attributes.score)
      LifecycleBench.checksum += person.score
    end

    def create(index : Int32) : Int64
      attributes = Attributes.for(index)
      person = BenchPerson.create!(name: attributes.name, email: attributes.email, age: attributes.age,
        active: attributes.active, score: attributes.score)
      person.id.as(Int64)
    end

    def find(id : Int64) : Nil
      LifecycleBench.checksum += BenchPerson.find!(id).score
    end

    def page(age : Int32) : Int32
      loaded = 0
      BenchPerson.where(age: age).limit(PAGE_SIZE).each do |person|
        LifecycleBench.checksum += person.score
        loaded += 1
      end
      loaded
    end

    def load_all : Int32
      loaded = 0
      BenchPerson.all.each do |person|
        LifecycleBench.checksum += person.score
        loaded += 1
      end
      loaded
    end

    def count_active : Int64
      # A grouped count returns a Hash, so the compile-time type is a union;
      # Granite releases return a lazy value that runs on `run`.
      total = BenchPerson.where(active: true).count
      if total.is_a?(Int)
        total.to_i64
      elsif total.responds_to?(:run)
        value = total.run
        value.is_a?(Array) ? value.sum.to_i64 : value.to_i64
      else
        raise "expected a scalar count, got #{total.class}"
      end
    end

    def update(id : Int64) : Nil
      person = BenchPerson.find!(id)
      person.score = person.score + 1.0
      person.save!
    end

    def destroy(id : Int64) : Nil
      BenchPerson.find!(id).destroy!
    end
  end

  # Times `iterations` calls of the block. The first `warmup` calls run with the
  # statement counter bound and are not timed; the rest run with logging off.
  def self.measure(operation : String, iterations : Int32, warmup : Int32, & : Int32 -> _) : OperationResult
    counter = StatementCounter.new
    Log.builder.bind("db", :debug, counter)
    counter.recording = true
    yield 0
    counter.recording = false
    (1...warmup).each { |index| yield index }
    Log.builder.unbind("db", :debug, counter)
    if trace
      STDERR.puts "-- #{operation}"
      counter.list_of_recorded_statements.each { |statement| STDERR.puts "   #{statement}" }
    end

    timed = iterations - warmup
    samples = Array(Float64).new(timed)
    GC.collect
    bytes_before = GC.stats.total_bytes
    started = Time.instant
    (warmup...iterations).each do |index|
      call_started = Time.instant
      yield index
      samples << (Time.instant - call_started).total_microseconds
    end
    total_seconds = (Time.instant - started).total_seconds
    bytes = GC.stats.total_bytes - bytes_before

    samples.sort!
    OperationResult.new(
      operation, timed, total_seconds,
      samples.sum / timed,
      samples[timed // 2],
      samples[Math.min(timed - 1, (timed * 0.99).to_i)],
      bytes.to_f / timed,
      counter.count.to_f / warmup,
    )
  end

  def self.run_variant(variant : Variant, iterations : Int32, rounds : Int32) : VariantResult
    warmup = Math.max(10, iterations // 20)
    variant.reset_table
    operations = [] of OperationResult
    ids = Array(Int64).new(iterations, 0_i64)

    operations << measure("build (no database)", iterations, warmup) { |index| variant.build(index) }
    operations << measure("create", iterations, warmup) { |index| ids[index] = variant.create(index) }
    operations << measure("find by id", iterations, warmup) { |index| variant.find(ids[index]) }
    page_iterations = Math.max(warmup + 10, iterations // 10)
    operations << measure("page of #{PAGE_SIZE} by index", page_iterations, warmup) { |index| variant.page(18 + index % AGE_SPREAD) }
    operations << measure("load all #{iterations} rows", 15, 3) { variant.load_all }
    operations << measure("count", page_iterations, warmup) { variant.count_active }
    operations << measure("load and update", iterations, warmup) { |index| variant.update(ids[index]) }
    operations << measure("load and destroy", iterations, warmup) { |index| variant.destroy(ids[index]) }

    VariantResult.new(variant.name, operations, leak_rounds(variant, rounds, Math.max(100, iterations // 2)))
  end

  # Full create/find/update/destroy cycles, sampling the heap after each one.
  def self.leak_rounds(variant : Variant, rounds : Int32, per_round : Int32) : Array(RoundSample)
    samples = [] of RoundSample
    rounds.times do |round|
      ids = Array(Int64).new(per_round) { |index| variant.create(index) }
      ids.each { |id| variant.find(id) }
      ids.each { |id| variant.update(id) }
      ids.each { |id| variant.destroy(id) }
      GC.collect
      samples << RoundSample.new(round + 1, GC.stats.heap_size / MEGABYTE, rss_megabytes)
    end
    samples
  end

  def self.print_table(result : RunResult, io : IO) : Nil
    io.puts "## #{result.label} (#{result.adapter}, #{result.iterations} records)"
    io.puts
    io.puts "| Operation | Variant | mean µs | p50 µs | p99 µs | bytes/op | statements/op |"
    io.puts "| --- | --- | ---: | ---: | ---: | ---: | ---: |"
    first_variant = result.list_of_variants.first
    first_variant.list_of_operations.each_with_index do |operation, position|
      result.list_of_variants.each do |variant|
        measured = variant.list_of_operations[position]
        io.printf("| %s | %s | %.1f | %.1f | %.1f | %.0f | %.2f |\n", operation.operation, variant.variant,
          measured.mean_microseconds, measured.p50_microseconds, measured.p99_microseconds,
          measured.bytes_per_operation, measured.statements_per_operation)
      end
    end
    io.puts
    io.puts "| Variant | heap MB after each cycle | RSS MB after each cycle |"
    io.puts "| --- | --- | --- |"
    result.list_of_variants.each do |variant|
      heaps = variant.list_of_rounds.map { |sample| sample.heap_megabytes.round(1) }.join(", ")
      rss = variant.list_of_rounds.map { |sample| sample.rss_megabytes.round(1) }.join(", ")
      io.puts "| #{variant.variant} | #{heaps} | #{rss} |"
    end
  end

  def self.main(arguments : Array(String)) : Nil
    iterations = 2000
    rounds = 5
    label = "grant"
    json_path = nil
    only_grant = false

    OptionParser.parse(arguments) do |parser|
      parser.on("--iterations N", "records per operation (default 2000)") { |value| iterations = value.to_i }
      parser.on("--rounds N", "leak-check cycles per variant (default 5)") { |value| rounds = value.to_i }
      parser.on("--label NAME", "name for this Grant build in the report") { |value| label = value }
      parser.on("--json PATH", "also write results as JSON") { |value| json_path = value }
      parser.on("--grant-only", "skip the raw and serializable variants") { only_grant = true }
      parser.on("--trace", "print the SQL of each operation's first call to STDERR") { self.trace = true }
    end

    database = DB.open(DATABASE_URL)
    variants = [] of Variant
    unless only_grant
      variants << RawVariant.new("raw", database)
      variants << SerializableVariant.new("serializable", database)
    end
    variants << GrantVariant.new(label)

    results = variants.map { |variant| run_variant(variant, iterations, rounds) }
    database.close

    run = RunResult.new(label, ADAPTER, iterations, Crystal::VERSION, results)
    print_table(run, STDOUT)
    if path = json_path
      File.write(path, run.to_json)
    end
    STDERR.puts "checksum #{checksum}"
  end
end

LifecycleBench.main(ARGV)
