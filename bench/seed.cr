# bench/seed.cr
#
# Configurable multi-tenant "todos" seed generator (Thread 2.5).
#
# Usage:
#   CURRENT_ADAPTER=sqlite crystal run bench/seed.cr -- \
#     --rows 1_000_000 --tenants 5_000 --adapter sqlite --db-path /tmp/grant_bench.db
#
# Flags (all optional; defaults in brackets):
#   --rows     N    total rows to insert            [100_000]
#   --tenants  N    number of distinct tenant_ids   [1_000]
#   --adapter  X    adapter label (sqlite only wired)[sqlite / $CURRENT_ADAPTER]
#   --db-path  P    sqlite file path or sqlite3: url [/tmp/grant_bench.db]
#   --batch    N    insert_all batch size            [5_000]
#   --done-pct N    percent of rows marked done=true [30]
#
# Behavior:
#   * Inserts into BOTH `todos` (indexed) and `todos_noindex` so the index
#     benchmark in run.cr compares identical data. Pass --indexed-only to skip
#     the no-index copy when you only need the keyset/OFFSET/IN/streaming runs.
#   * Uses batched `insert_all` (the convenience-method bulk path) with a live
#     progress meter on STDERR.
#   * NEVER silently caps: it inserts exactly --rows and prints the real number.
#
# NOTE on scale: we benchmark at 1-10M locally; we do NOT materialize a literal
# 1B rows on a laptop. The access patterns (keyset batching, composite index,
# IN chunking, streaming) are O-class invariant w.r.t. row count, so a 1-10M
# measurement demonstrates the same cliff/curve that bites at 100M-1B. See
# bench/README.md "Scaling to 100M+/1B".

require "./bench_helper"

opts = Bench.parse_args(ARGV)

rows = Bench.int_opt(opts, "rows", 100_000_i64)
tenants = Bench.int_opt(opts, "tenants", 1_000_i64)
batch_size = Bench.int_opt(opts, "batch", 5_000_i64).to_i
done_pct = Bench.int_opt(opts, "done-pct", 30_i64)
db_path = Bench.str_opt(opts, "db-path")
indexed_only = opts.has_key?("indexed-only")
adapter_lbl = Bench.str_opt(opts, "adapter", Bench::ADAPTER_NAME).not_nil!

if adapter_lbl != "sqlite"
  STDERR.puts "WARNING: this harness only wires up sqlite; --adapter #{adapter_lbl} " \
              "is recorded but the run uses sqlite. See README to add pg/mysql."
end

url = Bench.setup!(db_path)

puts "=== Grant bench seed ==="
puts "  adapter : sqlite (label: #{adapter_lbl})"
puts "  db url  : #{url}"
puts "  rows    : #{rows}"
puts "  tenants : #{tenants}"
puts "  batch   : #{batch_size}"
puts "  done%   : #{done_pct}"
puts "  tables  : todos#{indexed_only ? "" : " + todos_noindex"}"
puts

# Fresh schema (drops + recreates both tables, adds composite index).
Bench.create_schema!

# Stable-ish pseudo-random title pool to keep row size realistic without the
# cost of generating a unique string per row.
TITLE_POOL = [
  "Review PR", "Write spec", "Fix flaky test", "Update docs", "Refactor query",
  "Ship release", "Triage issue", "Pair on bug", "Plan sprint", "Reply to email",
]

# Insert into one model in batches with a progress meter.
def seed_table(model, rows : Int64, tenants : Int64, batch_size : Int32, done_pct : Int64, label : String)
  progress = Bench::Progress.new(rows, label)
  base_time = Time.utc - 365.days
  rng = Random.new(42) # deterministic so re-runs are comparable

  inserted = 0_i64
  while inserted < rows
    this_batch = Math.min(batch_size.to_i64, rows - inserted).to_i
    attrs = Array(Hash(String | Symbol, Grant::Columns::Type)).new(this_batch)

    this_batch.times do |i|
      n = inserted + i
      tenant = (n % tenants) + 1
      # spread created_at across a year so range/ordering is meaningful
      created = base_time + (n % 31_536_000).seconds
      done = rng.rand(100) < done_pct
      row = Hash(String | Symbol, Grant::Columns::Type).new
      row["tenant_id"] = tenant
      row["title"] = TITLE_POOL[n % TITLE_POOL.size]
      row["done"] = done
      row["created_at"] = created
      attrs << row
    end

    # insert_all is the bulk path from convenience_methods.cr. We let it set
    # timestamps off (we provide created_at; there's no updated_at column).
    model.insert_all(attrs, record_timestamps: false)

    inserted += this_batch
    progress.advance(this_batch.to_i64)
  end
  progress.finish
end

elapsed = Bench.timed do
  seed_table(Bench::Todo, rows, tenants, batch_size, done_pct, "todos (indexed)")
  unless indexed_only
    seed_table(Bench::TodoNoIndex, rows, tenants, batch_size, done_pct, "todos_noindex")
  end
  nil
end[1]

# Verify actual counts straight from the DB — no pretending.
todos_count = Bench.row_count(Bench::Todo)
noindex_count = indexed_only ? 0_i64 : Bench.row_count(Bench::TodoNoIndex)

puts
puts "=== seed complete ==="
puts "  todos rows         : #{todos_count}"
puts "  todos_noindex rows : #{noindex_count}#{indexed_only ? " (skipped)" : ""}"
puts "  distinct tenants   : #{tenants}"
puts "  total wall time    : #{elapsed.round(2)}s"
puts "  composite index    : #{Bench::COMPOSITE_INDEX_NAME} ON todos (tenant_id, created_at)"
puts
puts "Next: CURRENT_ADAPTER=sqlite crystal run bench/run.cr -- --db-path #{db_path || "/tmp/grant_bench.db"}"
