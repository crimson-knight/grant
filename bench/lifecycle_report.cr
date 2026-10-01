# bench/lifecycle_report.cr
#
# Merges the JSON written by bench/lifecycle_bench.cr runs and the compile
# records written by bench/lifecycle_compare.sh into one Markdown report.
#
# Usage:
#   crystal-alpha run bench/lifecycle_report.cr -- compile.jsonl run_a.json [run_b.json ...]

require "json"

module LifecycleReport
  MEGABYTE = 1024.0 * 1024.0

  struct OperationResult
    include JSON::Serializable

    getter operation : String
    getter mean_microseconds : Float64
    getter p99_microseconds : Float64
    getter bytes_per_operation : Float64
    getter statements_per_operation : Float64
  end

  struct RoundSample
    include JSON::Serializable

    getter heap_megabytes : Float64
    getter rss_megabytes : Float64
  end

  struct VariantResult
    include JSON::Serializable

    getter variant : String
    getter list_of_operations : Array(OperationResult)
    getter list_of_rounds : Array(RoundSample)
  end

  struct RunResult
    include JSON::Serializable

    getter adapter : String
    getter iterations : Int32
    getter crystal_version : String
    getter list_of_variants : Array(VariantResult)
  end

  struct CompileRecord
    include JSON::Serializable

    getter label : String
    getter mode : String
    getter seconds : Float64
    getter peak_bytes : Int64
    getter binary_bytes : Int64
  end

  def self.main(arguments : Array(String)) : Nil
    compile_path = arguments.first
    list_of_runs = arguments[1..].map { |path| RunResult.from_json(File.read(path)) }
    list_of_compiles = File.read_lines(compile_path).reject(&.blank?).map { |line| CompileRecord.from_json(line) }
    list_of_variants = list_of_runs.flat_map(&.list_of_variants)
    first_run = list_of_runs.first

    puts "# Grant lifecycle benchmark"
    puts
    puts "Adapter `#{first_run.adapter}`, #{first_run.iterations} records per operation, Crystal #{first_run.crystal_version}."
    puts "`raw` reads columns into tuples; `serializable` parses rows into a DB::Serializable struct;"
    puts "the other columns are Grant builds. Statements are counted from crystal-db's statement log."
    puts

    puts "## Mean time per operation (µs)"
    print_matrix(list_of_variants) { |result| "%.1f" % result.mean_microseconds }
    puts "## p99 time per operation (µs)"
    print_matrix(list_of_variants) { |result| "%.1f" % result.p99_microseconds }
    puts "## Heap bytes allocated per operation"
    print_matrix(list_of_variants) { |result| "%.0f" % result.bytes_per_operation }
    puts "## SQL statements per operation"
    print_matrix(list_of_variants) { |result| "%.2f" % result.statements_per_operation }

    puts "## Memory across repeated create/find/update/destroy cycles"
    puts
    puts "| Variant | heap MB per cycle | RSS MB per cycle | heap growth first→last |"
    puts "| --- | --- | --- | ---: |"
    list_of_variants.each do |variant|
      heaps = variant.list_of_rounds.map(&.heap_megabytes)
      rss = variant.list_of_rounds.map(&.rss_megabytes)
      growth = heaps.empty? ? 0.0 : heaps.last - heaps.first
      puts "| #{variant.variant} | #{heaps.map(&.round(1)).join(", ")} | #{rss.map(&.round(1)).join(", ")} | #{"%+.1f" % growth} MB |"
    end
    puts

    puts "## Cold compile cost of this one-model program"
    puts
    puts "| Build | Mode | seconds | peak compiler memory | binary size |"
    puts "| --- | --- | ---: | ---: | ---: |"
    list_of_compiles.each do |record|
      printf("| %s | %s | %.1f | %.0f MB | %.1f MB |\n", record.label, record.mode, record.seconds,
        record.peak_bytes / MEGABYTE, record.binary_bytes / MEGABYTE)
    end
  end

  def self.print_matrix(list_of_variants : Array(VariantResult), & : OperationResult -> String) : Nil
    puts
    puts "| Operation | #{list_of_variants.map(&.variant).join(" | ")} |"
    puts "| --- |#{" ---: |" * list_of_variants.size}"
    list_of_variants.first.list_of_operations.each_with_index do |operation, position|
      cells = list_of_variants.map { |variant| (measured = variant.list_of_operations[position]?) ? yield(measured) : "—" }
      puts "| #{operation.operation} | #{cells.join(" | ")} |"
    end
    puts
  end
end

LifecycleReport.main(ARGV)
