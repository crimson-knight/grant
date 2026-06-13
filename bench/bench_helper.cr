# bench/bench_helper.cr
#
# Shared setup for the Grant benchmark harness (Thread 2.5).
#
# NOT part of the shipped library — this lives under bench/ and is run locally
# (and in CI) to validate the large-table / high-scale query playbook against a
# simulated multi-tenant "todos" table.
#
# Responsibilities:
#   * require Grant + the SQLite adapter (sqlite is the default local adapter)
#   * register a connection from --db-path / SQLITE_DATABASE_URL / a temp file
#   * define the multi-tenant `Todo` model used by seed.cr and run.cr
#   * provide a second, *index-less* table (`todos_noindex`) so the index
#     benchmark can compare an identical dataset with vs without the composite
#     index, on the SAME adapter
#   * small utilities: arg parsing, progress meter, wall-clock timer, RSS sampler
#
# The model intentionally mirrors §2.5: id, tenant_id, title, done : Bool,
# created_at, plus a composite index (tenant_id, created_at).

require "../src/grant"
require "../src/adapter/sqlite"

module Bench
  # ---- adapter / connection bootstrap -------------------------------------

  # The harness is SQLite-first (the documented local adapter). The --adapter
  # flag is accepted for forward-compat and to keep the harness honest about
  # what it actually ran, but only sqlite is wired up here. pg/mysql can be
  # benchmarked by registering their connection the same way (left as a doc
  # note — see README) once those drivers are present locally.
  ADAPTER_NAME = (ENV["CURRENT_ADAPTER"]? || "sqlite")

  # Resolve a SQLite database URL. Priority:
  #   1. explicit --db-path (passed in by seed.cr / run.cr)
  #   2. SQLITE_DATABASE_URL env var
  #   3. a stable default file in /tmp so seed + run share the same DB
  def self.resolve_db_url(db_path : String?) : String
    if db_path
      db_path.starts_with?("sqlite3:") ? db_path : "sqlite3:#{db_path}"
    elsif (env = ENV["SQLITE_DATABASE_URL"]?)
      env
    else
      "sqlite3:/tmp/grant_bench.db"
    end
  end

  @@connection_registered = false

  # Register the SQLite connection exactly once. Idempotent so seed.cr and
  # run.cr can both call it.
  def self.setup!(db_path : String? = nil) : String
    url = resolve_db_url(db_path)
    unless @@connection_registered
      Grant::Connections << Grant::Adapter::Sqlite.new(name: "bench", url: url)
      @@connection_registered = true
    end
    url
  end

  # ---- models -------------------------------------------------------------

  # Primary benchmark model. Backed by the `todos` table which carries the
  # composite index (tenant_id, created_at).
  class Todo < Grant::Base
    connection bench
    table todos

    column id : Int64, primary: true
    column tenant_id : Int64
    column title : String
    column done : Bool = false
    column created_at : Time?
  end

  # Identical shape, but backed by an index-less table. Used solely for the
  # "with vs without composite index" benchmark so both sides run on the same
  # adapter and same row count — the only difference is the index.
  class TodoNoIndex < Grant::Base
    connection bench
    table todos_noindex

    column id : Int64, primary: true
    column tenant_id : Int64
    column title : String
    column done : Bool = false
    column created_at : Time?
  end

  # ---- schema management --------------------------------------------------

  COMPOSITE_INDEX_NAME = "idx_todos_tenant_created"

  # (Re)create both tables from the model definitions and add the composite
  # index to the indexed table. Drops first so a re-seed starts clean.
  def self.create_schema!
    Todo.migrator.drop_and_create
    TodoNoIndex.migrator.drop_and_create
    create_composite_index!
  end

  def self.create_composite_index!
    # CREATE INDEX is idempotent via IF NOT EXISTS. SQLite + PG + MySQL 8 all
    # accept this form.
    Todo.exec(
      "CREATE INDEX IF NOT EXISTS #{COMPOSITE_INDEX_NAME} " \
      "ON #{Todo.table_name} (tenant_id, created_at)"
    )
  end

  # Row counts straight from the DB (no model materialization).
  def self.row_count(model : Grant::Base.class) : Int64
    model.adapter.open do |db|
      db.scalar("SELECT COUNT(*) FROM #{model.table_name}").as(Int64 | Int32).to_i64
    end
  end

  # ---- CLI arg parsing ----------------------------------------------------

  # Tiny flag parser for `--key value` and `--key=value`. Underscores in
  # numeric values are stripped (so `--rows 1_000_000` works like Crystal
  # literals). Returns a Hash(String, String).
  def self.parse_args(argv : Array(String)) : Hash(String, String)
    opts = {} of String => String
    i = 0
    while i < argv.size
      arg = argv[i]
      if arg.starts_with?("--")
        key_val = arg[2..]
        if key_val.includes?('=')
          k, _, v = key_val.partition('=')
          opts[k] = v
        else
          # next token is the value (unless it's another flag or absent)
          nxt = argv[i + 1]?
          if nxt && !nxt.starts_with?("--")
            opts[key_val] = nxt
            i += 1
          else
            opts[key_val] = "true"
          end
        end
      end
      i += 1
    end
    opts
  end

  def self.int_opt(opts : Hash(String, String), key : String, default : Int64) : Int64
    if (raw = opts[key]?)
      raw.gsub("_", "").to_i64
    else
      default
    end
  end

  def self.str_opt(opts : Hash(String, String), key : String, default : String? = nil) : String?
    opts[key]? || default
  end

  # ---- progress meter -----------------------------------------------------

  # Lightweight, carriage-return progress meter for the seed loop. Prints
  # rows/sec and a percentage; never lies about the total.
  class Progress
    @start : Time::Span
    @last_print : Time::Span

    def initialize(@total : Int64, @label : String = "seeding")
      @start = Time.monotonic
      @last_print = @start
      @done = 0_i64
    end

    def advance(n : Int64)
      @done += n
      now = Time.monotonic
      # throttle redraws to ~5/sec
      if (now - @last_print).total_seconds >= 0.2 || @done >= @total
        @last_print = now
        render(now)
      end
    end

    private def render(now : Time::Span)
      elapsed = (now - @start).total_seconds
      rate = elapsed > 0 ? (@done / elapsed) : 0.0
      pct = @total > 0 ? (@done * 100.0 / @total) : 100.0
      STDERR.print(
        "\r#{@label}: #{@done}/#{@total} (#{pct.round(1)}%) " \
        "#{rate.round(0).to_i} rows/s, #{elapsed.round(1)}s elapsed   "
      )
      STDERR.flush
    end

    def finish
      render(Time.monotonic)
      STDERR.puts
    end
  end

  # ---- timing + memory ----------------------------------------------------

  # Wall-clock a block, returning {result, seconds}.
  def self.timed(&block : -> T) : Tuple(T, Float64) forall T
    start = Time.monotonic
    result = block.call
    {result, (Time.monotonic - start).total_seconds}
  end

  # Current resident set size in MB, read from the OS (portable enough for
  # macOS/Linux dev machines). Falls back to Crystal's GC heap size if the OS
  # call is unavailable. Used by the streaming-vs-to_a memory benchmark.
  def self.rss_mb : Float64
    {% if flag?(:darwin) %}
      # `ps -o rss=` reports KB on macOS.
      out = `ps -o rss= -p #{Process.pid}`.strip
      if (kb = out.to_i64?)
        return kb / 1024.0
      end
    {% elsif flag?(:linux) %}
      if File.exists?("/proc/self/statm")
        # statm: size resident ... (in pages)
        fields = File.read("/proc/self/statm").split
        if fields.size >= 2 && (pages = fields[1].to_i64?)
          page_kb = 4 # 4KB pages on typical x86_64/arm64 Linux
          return (pages * page_kb) / 1024.0
        end
      end
    {% end %}
    # Fallback: GC heap size (not RSS, but directionally useful).
    GC.stats.heap_size / (1024.0 * 1024.0)
  end

  # Force a GC and return RSS — gives a cleaner baseline before a measured op.
  def self.rss_mb_after_gc : Float64
    GC.collect
    rss_mb
  end
end
