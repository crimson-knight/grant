# bench/sqlite_engine_model_bench.cr
#
# Times Grant models writing through Grant's own SQLite engine against the
# same models on the C library: create, update, destroy, and a batch of
# creates inside one transaction.
#
#   crystal-alpha build --release bench/sqlite_engine_model_bench.cr -o out/model_bench
#   out/model_bench ROUNDS ROWS BATCH REPORT_DIR
#
# Each round runs one worker process per engine, the order flipping every
# round, so the two engines take turns on the same machine. A worker opens a
# fresh database file, runs every workload once, checks the rows it wrote,
# and prints its times. Three configurations run, each the same on both
# engines: Grant's default connection (journal_mode=wal,
# synchronous=normal), WAL with synchronous=full, and a rollback journal
# (journal_mode=delete, synchronous=full).
#
# Prints the median of each engine's times and the median of the per-round
# ratios, reported as "N× as fast" or "N× slower".
require "json"
require "../src/grant"
require "../src/adapter/sqlite"
require "../src/adapter/sqlite/grant_engine"

module SQLiteEngineModelBench
  WORKLOADS      = %w[create update destroy transaction_batch]
  CONFIGURATIONS = {
    "default"       => "",
    "wal_full"      => "?synchronous=full",
    "like_for_like" => "?journal_mode=delete&synchronous=full",
  }

  class_property database_url = "sqlite3::memory:"

  class BenchPerson < Grant::Base
    connection bench
    table bench_people

    column id : Int64, primary: true
    column name : String
    column email : String
    column age : Int32
    column score : Float64
    timestamps
  end

  # The times one worker prints, in seconds per workload.
  struct WorkerResult
    include JSON::Serializable

    getter engine : String
    getter times : Hash(String, Float64)

    def initialize(@engine, @times)
    end
  end

  # One worker: every workload on one engine, in this process.
  def self.work(engine : String, file : String, query : String, rows : Int32, batch : Int32) : Nil
    Grant.settings.sqlite_engine = engine == "grant" ? :grant : :libsqlite3
    Grant::Connections << Grant::Adapter::Sqlite.new(name: "bench", url: "sqlite3:#{file}#{query}")
    BenchPerson.migrator.drop_and_create
    BenchPerson.exec("CREATE INDEX bench_people_age ON bench_people (age)")

    times = {} of String => Float64
    ids = [] of Int64
    times["create"] = seconds do
      rows.times do |index|
        person = BenchPerson.create!(name: "Person #{index}", email: "person#{index}@example.com",
          age: 18 + index % 60, score: index * 0.5)
        ids << person.id.as(Int64)
      end
    end
    times["update"] = seconds do
      ids.each do |id|
        person = BenchPerson.find!(id)
        person.score = person.score + 1.0
        person.save!
      end
    end
    times["destroy"] = seconds do
      ids.each { |id| BenchPerson.find!(id).destroy! }
    end
    times["transaction_batch"] = seconds do
      BenchPerson.transaction do
        batch.times do |index|
          BenchPerson.create!(name: "Batch #{index}", email: "batch#{index}@example.com",
            age: 18 + index % 60, score: index * 0.25)
        end
      end
    end
    count = BenchPerson.count.to_i64
    raise "expected #{batch} rows after the batch, found #{count}" unless count == batch
    puts WorkerResult.new(engine, times).to_json
  end

  def self.seconds(& : ->) : Float64
    started = Time.instant
    yield
    (Time.instant - started).total_seconds
  end

  def self.ratio_text(engine_seconds : Float64, c_seconds : Float64) : String
    ratio = c_seconds / engine_seconds
    ratio >= 1.0 ? "#{ratio.round(2)}× as fast" : "#{(1.0 / ratio).round(2)}× slower"
  end

  def self.median(values : Array(Float64)) : Float64
    sorted = values.sort
    middle = sorted.size // 2
    sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
  end

  def self.drive(rounds : Int32, rows : Int32, batch : Int32, report_dir : String) : Nil
    Dir.mkdir_p(File.join(report_dir, "work"))
    report = String::Builder.new
    report << "Grant models on Grant's SQLite engine against libsqlite3: #{rounds} rounds, " \
              "#{rows} rows for create, update and destroy, #{batch} creates in the transaction batch\n"
    CONFIGURATIONS.each do |label, query|
      engine_times = Hash(String, Array(Float64)).new { |hash, key| hash[key] = [] of Float64 }
      c_times = Hash(String, Array(Float64)).new { |hash, key| hash[key] = [] of Float64 }
      ratios = Hash(String, Array(Float64)).new { |hash, key| hash[key] = [] of Float64 }
      rounds.times do |round|
        order = round.even? ? %w[grant libsqlite3] : %w[libsqlite3 grant]
        results = {} of String => Hash(String, Float64)
        order.each do |engine|
          file = File.join(report_dir, "work", "#{label}-#{engine}.db")
          %w[-journal -wal -shm].each { |suffix| File.delete?(file + suffix) }
          File.delete?(file)
          output = IO::Memory.new
          status = Process.run(Process.executable_path || PROGRAM_NAME,
            ["worker", engine, file, query, rows.to_s, batch.to_s], output: output, error: STDERR)
          raise "worker #{engine} failed (#{status.exit_code})" unless status.success?
          results[engine] = WorkerResult.from_json(output.to_s.lines.last).times
          %w[-journal -wal -shm].each { |suffix| File.delete?(file + suffix) }
          File.delete?(file)
        end
        WORKLOADS.each do |workload|
          engine_time = results["grant"][workload]
          c_time = results["libsqlite3"][workload]
          engine_times[workload] << engine_time
          c_times[workload] << c_time
          ratios[workload] << c_time / engine_time
        end
        STDERR.puts "#{label} round #{round + 1}: #{results.to_json}"
      end
      report << "\n## #{label}#{query.empty? ? " (Grant's default PRAGMAs)" : " (#{query})"}\n\n"
      report << "| Workload | Engine | libsqlite3 | Result | Range of round ratios |\n|---|---|---|---|---|\n"
      WORKLOADS.each do |workload|
        sorted = ratios[workload].sort
        low = sorted[sorted.size > 2 ? 1 : 0]
        high = sorted[sorted.size > 2 ? -2 : -1]
        median_ratio = median(ratios[workload])
        result = ratio_text(1.0, median_ratio)
        report << "| #{workload} | #{(median(engine_times[workload]) * 1000).round(2)} ms | " \
                  "#{(median(c_times[workload]) * 1000).round(2)} ms | **#{result}** | " \
                  "#{ratio_text(1.0, low)} to #{ratio_text(1.0, high)} |\n"
      end
    end
    Dir.delete(File.join(report_dir, "work")) rescue nil
    text = report.to_s
    File.write(File.join(report_dir, "model_bench.md"), text)
    puts text
  end
end

if ARGV[0]? == "worker"
  SQLiteEngineModelBench.work(ARGV[1], ARGV[2], ARGV[3], ARGV[4].to_i, ARGV[5].to_i)
elsif ARGV.size == 4
  SQLiteEngineModelBench.drive(ARGV[0].to_i, ARGV[1].to_i, ARGV[2].to_i, ARGV[3])
else
  STDERR.puts "usage: model_bench ROUNDS ROWS BATCH REPORT_DIR"
  exit 2
end
