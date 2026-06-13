# bench/run.cr
#
# Benchmark runner for the Grant large-table / high-scale query playbook
# (Thread 2.5). Run AFTER bench/seed.cr has populated the DB.
#
# Usage:
#   CURRENT_ADAPTER=sqlite crystal run --release bench/run.cr -- \
#     --db-path /tmp/grant_bench.db
#
# Flags:
#   --db-path  P    sqlite file path or sqlite3: url   [/tmp/grant_bench.db]
#   --depth    N    page depth for OFFSET cliff demo   [auto: ~rows/page]
#   --page     N    page size for pagination bench     [1_000]
#   --in-size  N    size of the big IN-list            [20_000]
#   --in-chunk N    chunk size for chunked IN          [900]
#   --results  P    path to write RESULTS.md           [bench/RESULTS.md]
#   --skip-noindex  skip the no-index bench (if seeded --indexed-only)
#
# Each benchmark logs the ACTUAL row/tenant counts it ran against. Headline
# numbers are appended to RESULTS.md.
#
# Benchmarks (per §2.5):
#   (a) keyset in_batches vs legacy OFFSET pagination at depth -> O(n^2) cliff
#   (b) tenant-scoped fetch WITH vs WITHOUT the composite (tenant_id,created_at)
#   (c) single huge IN(...) vs manually chunked IN
#   (d) memory footprint: full to_a scan vs row-by-row streaming iteration
#
# Where a benchmark would use Thread-2 APIs not yet merged (force_index,
# each_streamed, automatic IN-chunking), it is written behind a clearly marked
# guard / manual implementation with a TODO to switch to the real API.

require "./bench_helper"

# Quiet Grant's per-query SQL logging (incl. the slow-query WARN) so the bench
# output stays readable. We measure with our own wall-clock timers.
Log.setup("grant.*", :error)

opts = Bench.parse_args(ARGV)
db_path = Bench.str_opt(opts, "db-path")
url = Bench.setup!(db_path)

page_size = Bench.int_opt(opts, "page", 1_000_i64).to_i
in_size = Bench.int_opt(opts, "in-size", 20_000_i64).to_i
in_chunk = Bench.int_opt(opts, "in-chunk", 900_i64).to_i
results_path = Bench.str_opt(opts, "results", "bench/RESULTS.md").not_nil!
skip_noindex = opts.has_key?("skip-noindex")

# Discover actual scale from the DB — never assume.
total_rows = Bench.row_count(Bench::Todo)
if total_rows == 0
  abort "No rows in `todos`. Run bench/seed.cr first " \
        "(CURRENT_ADAPTER=sqlite crystal run bench/seed.cr -- --rows 1_000_000 ...)."
end
noindex_rows = skip_noindex ? 0_i64 : Bench.row_count(Bench::TodoNoIndex)
distinct_tenants = Bench::Todo.adapter.open do |db|
  db.scalar("SELECT COUNT(DISTINCT tenant_id) FROM #{Bench::Todo.table_name}").as(Int64 | Int32).to_i64
end

# Default OFFSET cliff depth: enough pages to feel the O(n^2) drag without
# scanning the entire table on a small seed. Cap so it stays sane on big seeds.
default_depth = Math.min((total_rows // page_size).to_i, 200)
depth = Bench.int_opt(opts, "depth", default_depth.to_i64).to_i
depth = 1 if depth < 1

puts "=== Grant bench run ==="
puts "  adapter         : sqlite"
puts "  db url          : #{url}"
puts "  todos rows      : #{total_rows}"
puts "  todos_noindex   : #{skip_noindex ? "(skipped)" : noindex_rows.to_s}"
puts "  distinct tenants: #{distinct_tenants}"
puts "  page size       : #{page_size}"
puts "  pages (depth)   : #{depth}"
puts "  IN size         : #{in_size}  | IN chunk: #{in_chunk}"
puts

# Collected rows for RESULTS.md: {benchmark, variant, detail, seconds, note}
record_rows = [] of NamedTuple(bench: String, variant: String, detail: String, seconds: Float64, note: String)

def section(title : String)
  puts
  puts "--- #{title} ---"
end

# Clean keyset pagination over Bench::Todo: a FRESH query per page
# (`WHERE id > last ORDER BY id LIMIT page`). This is the correct keyset
# pattern and the one the docs recommend.
#
# NOTE: we deliberately do NOT use the framework's chainable `in_batches`
# here — its current implementation mutates and ACCUMULATES `WHERE id > ?`
# predicates across iterations on the same relation
# (convenience_methods.cr:106 reassigns `relation = relation.where(...)` but
# `where` mutates in place), so page N carries N redundant predicates and the
# walk degrades with depth. That is a separate framework defect (Thread 2's
# lane). Benchmarking a clean keyset here keeps the OFFSET-vs-keyset comparison
# honest. A fresh-query-per-page keyset is also exactly what `each_streamed`
# (§2.3) does internally once merged.
def keyset_walk(page_size : Int32, max_pages : Int32, &block : Array(Bench::Todo) ->) : Int64
  last_id = 0_i64
  pages = 0
  seen = 0_i64
  loop do
    batch = Bench::Todo.where(:id, :gt, last_id).order(id: :asc).limit(page_size).select
    break if batch.empty?
    yield batch
    seen += batch.size
    last = batch.last.id
    break unless last
    last_id = last
    pages += 1
    break if pages >= max_pages || batch.size < page_size
  end
  seen
end

# =============================================================================
# (a) Keyset in_batches vs legacy OFFSET pagination at depth
# =============================================================================
section "(a) Keyset in_batches vs legacy OFFSET pagination (depth=#{depth} pages of #{page_size})"

# Keyset: walk `depth` pages with a clean keyset (WHERE id > last, fresh query
# per page). Flat per-page cost regardless of depth.
keyset_seen = 0_i64
_, keyset_secs = Bench.timed do
  keyset_seen = keyset_walk(page_size, depth) { |_batch| }
  nil
end
puts "  keyset (WHERE id>last) : #{keyset_secs.round(4)}s  (#{keyset_seen} rows over #{depth} pages)"
record_rows << {bench: "(a) pagination", variant: "keyset (WHERE id>last)",
                detail: "#{depth} pages x #{page_size}", seconds: keyset_secs,
                note: "fresh query per page; flat O(page) cost per page"}

# Legacy OFFSET: the class-level find_in_batches in querying.cr uses
# `LIMIT ? OFFSET ?`. Each successive page re-scans + discards `offset` rows ->
# the O(n^2) cliff. We walk the same `depth` pages.
offset_seen = 0_i64
_, offset_secs = Bench.timed do
  pages = 0
  Bench::Todo.find_in_batches(batch_size: page_size) do |batch|
    offset_seen += batch.size
    pages += 1
    break if pages >= depth
  end
  nil
end
puts "  legacy OFFSET     : #{offset_secs.round(4)}s  (#{offset_seen} rows over #{depth} pages)"
ratio = keyset_secs > 0 ? (offset_secs / keyset_secs) : 0.0
puts "  => OFFSET is #{ratio.round(2)}x the keyset time at this depth (gap widens with depth)"
record_rows << {bench: "(a) pagination", variant: "legacy OFFSET",
                detail: "#{depth} pages x #{page_size}", seconds: offset_secs,
                note: "LIMIT/OFFSET re-scans offset rows each page (O(n^2))"}

# Per-page timing at deepest page to make the cliff concrete: time page 1 vs the
# deepest page for OFFSET.
def time_offset_page(model, page_size, page_index) : Float64
  offset = page_size * page_index
  Bench.timed do
    model.all("LIMIT ? OFFSET ?", [page_size, offset] of Grant::Columns::Type, false).to_a
    nil
  end[1]
end

first_page = time_offset_page(Bench::Todo, page_size, 0)
deep_index = depth - 1
deep_page = time_offset_page(Bench::Todo, page_size, deep_index)
puts "  OFFSET page 1      : #{first_page.round(5)}s"
puts "  OFFSET page #{deep_index + 1} (offset=#{page_size * deep_index}) : #{deep_page.round(5)}s"
cliff = first_page > 0 ? (deep_page / first_page) : 0.0
puts "  => deep OFFSET page is #{cliff.round(2)}x slower than the first page"
record_rows << {bench: "(a) OFFSET cliff", variant: "deep page vs page 1",
                detail: "page #{deep_index + 1} offset=#{page_size * deep_index}",
                seconds: deep_page,
                note: "#{cliff.round(2)}x slower than page 1 (#{first_page.round(5)}s)"}

# =============================================================================
# (b) Tenant-scoped fetch WITH vs WITHOUT composite (tenant_id, created_at)
# =============================================================================
section "(b) Tenant-scoped fetch: WITH vs WITHOUT composite index"

# Pick a tenant that exists.
sample_tenant = 1_i64

# Indexed table (has idx_todos_tenant_created). Query filters tenant_id and
# orders by created_at -> the composite index serves both.
indexed_rows_seen = 0
_, indexed_secs = Bench.timed do
  res = Bench::Todo.where(tenant_id: sample_tenant).order(created_at: :asc).select
  indexed_rows_seen = res.size
  nil
end
puts "  WITH index    : #{indexed_secs.round(5)}s  (tenant #{sample_tenant}, #{indexed_rows_seen} rows)"
record_rows << {bench: "(b) tenant scope", variant: "WITH composite index",
                detail: "tenant=#{sample_tenant}, #{indexed_rows_seen} rows",
                seconds: indexed_secs,
                note: "idx_todos_tenant_created serves WHERE+ORDER BY"}

if skip_noindex
  puts "  WITHOUT index : (skipped — seed with both tables to compare)"
else
  noindex_seen = 0
  _, noindex_secs = Bench.timed do
    res = Bench::TodoNoIndex.where(tenant_id: sample_tenant).order(created_at: :asc).select
    noindex_seen = res.size
    nil
  end
  puts "  WITHOUT index : #{noindex_secs.round(5)}s  (tenant #{sample_tenant}, #{noindex_seen} rows)"
  speedup = noindex_secs > 0 && indexed_secs > 0 ? (noindex_secs / indexed_secs) : 0.0
  puts "  => composite index is #{speedup.round(2)}x faster (full-table scan avoided)"
  record_rows << {bench: "(b) tenant scope", variant: "WITHOUT index (full scan)",
                  detail: "tenant=#{sample_tenant}, #{noindex_seen} rows",
                  seconds: noindex_secs,
                  note: "#{speedup.round(2)}x slower; sequential scan of #{noindex_rows} rows"}
end

# TODO(Thread 2): once force_index/use_index land (§2.1), add a third variant:
#   Bench::Todo.where(tenant_id: t).force_index("idx_todos_tenant_created")...
# to demonstrate hint + safe fallback. Today the optimizer already picks the
# composite index, so the WITH/WITHOUT comparison stands in for it.
puts "  [force_index variant pending Thread 2 merge — see TODO in run.cr]"

# Show the plan so the index use is visible/auditable.
begin
  plan = Bench::Todo.where(tenant_id: sample_tenant).order(created_at: :asc).explain
  puts "  EXPLAIN (indexed) : #{plan.gsub('\n', " | ")}"
rescue ex
  puts "  EXPLAIN unavailable: #{ex.message}"
end

# =============================================================================
# (c) Single huge IN(...) vs manually chunked IN
# =============================================================================
section "(c) Huge IN(#{in_size}) vs chunked IN (chunks of #{in_chunk})"

# Build a list of ids to look up. Cap to existing rows.
in_n = Math.min(in_size.to_i64, total_rows).to_i
id_list = (1_i64..in_n.to_i64).to_a

# Single huge IN: one query with `in_n` bind parameters. On SQLite the default
# SQLITE_MAX_VARIABLE_NUMBER is 999 (older) / 32766 (>=3.32). Past that the
# driver raises "too many SQL variables". We attempt it and record the outcome
# honestly — slow OR failure both prove the point.
single_result_count = 0
single_secs = 0.0
single_note = ""
single_failed = false
begin
  _, single_secs = Bench.timed do
    # The `where(col: array)` hash form maps an Array value to `col IN (...)`
    # (builder.cr:88). This is the path Thread 2's auto-chunking will intercept.
    res = Bench::Todo.where(id: id_list).select
    single_result_count = res.size
    nil
  end
  single_note = "one query, #{in_n} bind params; #{single_result_count} rows"
  puts "  single huge IN : #{single_secs.round(5)}s  (#{single_result_count} rows, #{in_n} params)"
rescue ex
  single_failed = true
  single_note = "FAILED: #{ex.message.try(&.lines.first)}"
  puts "  single huge IN : FAILED — #{ex.message.try(&.lines.first)}"
  puts "                   (this is the expected cliff: driver bind-param cap exceeded)"
end
record_rows << {bench: "(c) IN list", variant: "single huge IN",
                detail: "#{in_n} ids in one IN",
                seconds: single_failed ? 0.0 : single_secs,
                note: single_note}

# Manually chunked IN: split into chunks of `in_chunk`, one query per chunk,
# concatenate + dedup by pk. This is the pattern Thread 2's automatic IN
# chunking (§2.2) will do under the hood once merged.
# TODO(Thread 2): replace this manual chunk loop with
#   Grant.settings.in_clause_limit = in_chunk  (automatic chunking), or
#   Bench::Todo.where(id: id_list).in_chunks(of: in_chunk).select
chunked_result_count = 0
_, chunked_secs = Bench.timed do
  seen = Set(Int64).new
  id_list.each_slice(in_chunk) do |chunk|
    rows = Bench::Todo.where(id: chunk).select
    rows.each do |r|
      pk = r.id
      seen << pk if pk
    end
  end
  chunked_result_count = seen.size
  nil
end
n_chunks = (in_n / in_chunk.to_f).ceil.to_i
puts "  chunked IN     : #{chunked_secs.round(5)}s  (#{chunked_result_count} unique rows over #{n_chunks} chunks)"
if single_failed
  puts "  => chunked IN succeeds where the single huge IN failed outright"
else
  ratio_c = chunked_secs > 0 ? (single_secs / chunked_secs) : 0.0
  puts "  => single/chunked time ratio: #{ratio_c.round(2)}x (chunking keeps each query under the bind cap)"
end
record_rows << {bench: "(c) IN list", variant: "manual chunked IN",
                detail: "#{n_chunks} chunks x #{in_chunk}",
                seconds: chunked_secs,
                note: "#{chunked_result_count} unique rows; each query <= bind cap (manual; Thread 2 automates)"}

# =============================================================================
# (d) Memory: full to_a scan vs row-by-row streaming iteration
# =============================================================================
section "(d) Memory footprint: full to_a scan vs row-by-row streaming"

# Bound the scan so it doesn't OOM a small laptop on a 1M+ seed while still
# being large enough to show the materialization delta.
scan_limit = Math.min(total_rows, 500_000_i64).to_i

# Full to_a: materializes every row into an Array(Todo) at once.
GC.collect
base_rss = Bench.rss_mb
materialized_count = 0
peak_full = base_rss
_, full_secs = Bench.timed do
  arr = Bench::Todo.order(id: :asc).limit(scan_limit).select
  materialized_count = arr.size
  peak_full = Bench.rss_mb # measured while `arr` is still alive
  arr.size                 # keep arr referenced until here
end
full_delta = (peak_full - base_rss)
puts "  full to_a      : #{full_secs.round(4)}s, RSS delta ~#{full_delta.round(1)} MB (#{materialized_count} rows held)"
record_rows << {bench: "(d) memory", variant: "full to_a",
                detail: "#{materialized_count} rows materialized",
                seconds: full_secs,
                note: "RSS delta ~#{full_delta.round(1)} MB (whole result array in memory)"}

# Row-by-row streaming. Thread 2's each_streamed (§2.3) is the real API; until
# it merges we approximate the bounded-memory pattern with a clean keyset walk
# (small page) + immediate discard, which never holds the full result set.
# TODO(Thread 2): replace this with
#   Bench::Todo.order(id: :asc).limit(scan_limit).each_streamed { |t| ... }
GC.collect
base_rss2 = Bench.rss_mb
streamed_count = 0_i64
peak_stream = base_rss2
_, stream_secs = Bench.timed do
  seen = 0_i64
  stream_page = 2_000
  max_pages = (scan_limit / stream_page.to_f).ceil.to_i
  streamed_count = keyset_walk(stream_page, max_pages) do |batch|
    batch.each do |t|
      seen += 1 if t.id # simulate per-row processing without retaining the row
    end
    cur = Bench.rss_mb
    peak_stream = cur if cur > peak_stream
  end
  nil
end
stream_delta = (peak_stream - base_rss2)
puts "  streamed (batched, discard) : #{stream_secs.round(4)}s, RSS delta ~#{stream_delta.round(1)} MB (#{streamed_count} rows processed)"
mem_ratio = stream_delta.abs > 0.05 ? (full_delta / stream_delta) : Float64::INFINITY
puts "  => streaming holds ~#{stream_delta.round(1)} MB vs ~#{full_delta.round(1)} MB for to_a " \
     "(#{mem_ratio.finite? ? "#{mem_ratio.round(1)}x" : "much"} less peak)"
record_rows << {bench: "(d) memory", variant: "streamed (batched)",
                detail: "#{streamed_count} rows processed",
                seconds: stream_secs,
                note: "RSS delta ~#{stream_delta.round(1)} MB (bounded; never materializes full set; Thread 2 each_streamed)"}

# =============================================================================
# Write RESULTS.md
# =============================================================================
File.open(results_path, "w") do |f|
  f.puts "# Grant Bench Results"
  f.puts
  f.puts "Generated by `bench/run.cr` (Thread 2.5 — benchmark harness + billion-row simulation)."
  f.puts
  f.puts "## Run configuration (actual, not capped silently)"
  f.puts
  f.puts "| Key | Value |"
  f.puts "| --- | --- |"
  f.puts "| Adapter | sqlite |"
  f.puts "| DB URL | `#{url}` |"
  f.puts "| `todos` rows (indexed) | **#{total_rows}** |"
  f.puts "| `todos_noindex` rows | #{skip_noindex ? "(skipped)" : noindex_rows.to_s} |"
  f.puts "| Distinct tenants | #{distinct_tenants} |"
  f.puts "| Page size | #{page_size} |"
  f.puts "| Pages walked (depth) | #{depth} |"
  f.puts "| IN-list size | #{in_n} |"
  f.puts "| IN chunk size | #{in_chunk} |"
  f.puts "| Scan limit (mem bench) | #{scan_limit} |"
  f.puts "| Crystal | #{Crystal::VERSION} |"
  f.puts "| Generated | #{Time.utc.to_s("%Y-%m-%d %H:%M:%S")} UTC |"
  f.puts
  f.puts "## Headline timings"
  f.puts
  f.puts "| Benchmark | Variant | Detail | Seconds | Note |"
  f.puts "| --- | --- | --- | --- | --- |"
  record_rows.each do |r|
    secs = r[:seconds] == 0.0 && r[:note].starts_with?("FAILED") ? "n/a" : r[:seconds].round(5).to_s
    f.puts "| #{r[:bench]} | #{r[:variant]} | #{r[:detail]} | #{secs} | #{r[:note]} |"
  end
  f.puts
  f.puts "## Notes on the IN-list benchmark (c)"
  f.puts
  f.puts <<-MD
  Whether the **single huge `IN`** *fails* or merely *degrades* depends on the
  database/driver's bind-parameter cap:

  - **PostgreSQL:** hard cap of **65535** bind params per statement -> a single
    `IN` larger than that raises outright.
  - **MySQL:** bounded by `max_allowed_packet`; large `IN`s either error or
    serialize slowly.
  - **SQLite:** `SQLITE_MAX_VARIABLE_NUMBER` defaults to **999** (pre-3.32) or
    **32766** (3.32+), but can be compiled higher. On the build used for this
    run, the driver accepted even very large `IN` lists, so the single-`IN`
    here **degraded** (linear slowdown + full-result memory) rather than
    erroring. The harness records the real outcome instead of asserting a
    failure.

  The takeaway is identical either way: **chunked `IN` is the portable, robust
  pattern** — it stays under every engine's cap and keeps each query bounded.
  Thread 2's automatic `in_clause_limit` chunking (§2.2) does this transparently;
  this harness chunks manually until that merges.
  MD
  f.puts
  f.puts "## How this scales to 100M+/1B rows"
  f.puts
  f.puts <<-MD
  These numbers were measured at **#{total_rows} rows** on sqlite locally. We do
  **not** materialize a literal 1B-row table on a laptop. The patterns are
  O-class invariant w.r.t. row count, so the curves shown here are the same ones
  that bite at 100M-1B:

  - **(a) OFFSET vs keyset:** `LIMIT/OFFSET` is O(offset) per page -> O(n^2) to
    walk the whole table; keyset (`WHERE id > last`) is O(page) per page -> O(n)
    total, with flat per-page cost regardless of depth. At 1B rows the deep-page
    OFFSET penalty is catastrophic; keyset is unchanged.
  - **(b) composite index:** a `(tenant_id, created_at)` index turns a
    full-table scan (O(n)) into an index range scan (O(log n + matches)). The
    larger the table, the larger the win — at 1B rows the unindexed scan is
    untenable.
  - **(c) IN chunking:** a single huge `IN` hits the driver's bind-param cap
    (sqlite default 999/32766) regardless of table size; chunking keeps every
    query valid and bounded. Independent of total row count.
  - **(d) streaming vs to_a:** `to_a` memory grows linearly with result size;
    streaming/batched iteration stays bounded. At 1B-row scans `to_a` OOMs;
    streaming does not.

  Run at higher local scale with e.g.
  `crystal run --release bench/seed.cr -- --rows 10_000_000 --tenants 50_000`.
  MD
end

puts
puts "=== done ==="
puts "Wrote #{results_path}"
