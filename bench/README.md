# Grant Benchmark Harness (`bench/`)

A runnable, **not-shipped** harness that validates Grant's large-table /
high-scale query playbook (see `GRANT_MULTI_TARGET_AND_SCALE_PLAN.md` §2.5)
against a simulated multi-tenant `todos` table.

It does two things:

1. **`seed.cr`** — generates a configurable multi-tenant dataset via batched
   `insert_all`, with a live progress meter.
2. **`run.cr`** — runs four benchmarks against that dataset and writes
   `bench/RESULTS.md`.

Everything is SQLite-first (Grant's documented local adapter). We benchmark at
1–10M rows locally and document how the patterns scale to 100M+/1B — we do
**not** materialize a literal 1-billion-row table on a laptop.

---

## Quick start

```sh
# 1. Seed 1,000,000 rows across 5,000 tenants into /tmp/grant_bench.db
CURRENT_ADAPTER=sqlite crystal run --release bench/seed.cr -- \
  --rows 1_000_000 --tenants 5_000 --adapter sqlite --db-path /tmp/grant_bench.db

# 2. Run the benchmarks (writes bench/RESULTS.md)
CURRENT_ADAPTER=sqlite crystal run --release bench/run.cr -- \
  --db-path /tmp/grant_bench.db --depth 300 --in-size 100_000
```

Use `--release` for representative numbers; the debug build is fine for a smoke
test but is several times slower.

> The harness needs the SQLite driver shard installed (`shards install`) and
> `CURRENT_ADAPTER=sqlite` set so Grant pulls in the SQLite adapter.

---

## `seed.cr` — dataset generator

Generates a `Todo` table: `id`, `tenant_id`, `title`, `done : Bool`,
`created_at`, plus a composite index `(tenant_id, created_at)`. It seeds **two**
tables with identical data: `todos` (indexed) and `todos_noindex` (no composite
index) so benchmark (b) can isolate the index's effect on the same adapter.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--rows N` | `100_000` | total rows to insert (underscores allowed) |
| `--tenants N` | `1_000` | distinct `tenant_id` values |
| `--adapter X` | `sqlite` / `$CURRENT_ADAPTER` | label recorded in output (only sqlite is wired) |
| `--db-path P` | `/tmp/grant_bench.db` | sqlite file path or `sqlite3:` URL |
| `--batch N` | `5_000` | `insert_all` batch size |
| `--done-pct N` | `30` | percent of rows with `done = true` |
| `--indexed-only` | off | seed only `todos` (skip the no-index copy) |

The progress meter prints `rows/sec` and a percentage to STDERR. The final
summary prints the **actual** row counts read back from the DB — no silent caps.

---

## `run.cr` — the four benchmarks

| Flag | Default | Meaning |
| --- | --- | --- |
| `--db-path P` | `/tmp/grant_bench.db` | sqlite file path or `sqlite3:` URL |
| `--page N` | `1_000` | page size for pagination benchmark |
| `--depth N` | auto (`min(rows/page, 200)`) | number of pages to walk |
| `--in-size N` | `20_000` | size of the big `IN` list (capped to row count) |
| `--in-chunk N` | `900` | chunk size for the chunked `IN` |
| `--results P` | `bench/RESULTS.md` | output file |
| `--skip-noindex` | off | skip the no-index variant (if seeded `--indexed-only`) |

Each benchmark prints the **actual** row/tenant counts it ran against.

### (a) Keyset pagination vs legacy OFFSET — the O(n²) cliff

Walks `--depth` pages two ways:

- **Keyset** (`WHERE id > last ORDER BY id LIMIT page`, fresh query per page):
  flat O(page) cost per page → O(n) to walk the table.
- **Legacy OFFSET** (`LIMIT ? OFFSET ?`, the class-level `find_in_batches` in
  `querying.cr`): each page re-scans and discards `offset` rows → O(n²) to walk
  the table.

It also times **page 1 vs the deepest page** for OFFSET to make the cliff
concrete: the deep page is several × slower than the first, and the gap widens
with depth and table size.

> **Why not the chainable `in_batches`?** Grant's chainable `in_batches`
> (`convenience_methods.cr`) currently mutates and *accumulates* `WHERE id > ?`
> predicates across iterations on the same relation, so deep walks carry
> redundant predicates. That's a separate framework defect (Thread 2's lane);
> the harness uses a clean fresh-query-per-page keyset so the comparison is
> honest. The TODO in `run.cr` notes the switch once that lands / `each_streamed`
> merges.

### (b) Tenant-scoped fetch: with vs without the composite index

Runs `WHERE tenant_id = ? ORDER BY created_at` against the indexed `todos`
(served by `(tenant_id, created_at)`) and the index-less `todos_noindex`
(full-table scan). Prints the speed-up and the SQLite `EXPLAIN QUERY PLAN` so the
index use is auditable (`SEARCH todos USING INDEX idx_todos_tenant_created`).

> **`force_index` is pending.** Once Thread 2's index hints (§2.1) merge, a third
> variant using `force_index("idx_todos_tenant_created")` will be added (see the
> TODO in `run.cr`). Today the planner already picks the composite index, so the
> with/without comparison stands in for it.

### (c) Single huge `IN` vs chunked `IN`

Builds an `IN` list of `--in-size` ids and runs it two ways:

- **Single huge `IN`** — one statement with N bind params. On engines with a
  bind-param cap (PG 65535, default SQLite 999/32766, MySQL `max_allowed_packet`)
  this *fails* outright; on builds with a high cap it merely *degrades* (linear
  slowdown + full-result memory). The harness records whichever happens — it does
  not assert a failure.
- **Chunked `IN`** — splits into `--in-chunk` chunks, one query per chunk,
  dedups by primary key. Portable and bounded regardless of the engine's cap.

> **Pending automation.** Thread 2's automatic `IN` chunking (§2.2) will do this
> transparently via `Grant.settings.in_clause_limit` / `.in_chunks(of:)`. The
> harness chunks manually until then (TODO in `run.cr`).

### (d) Memory footprint: full `to_a` vs row-by-row streaming

- **`to_a`** materializes the whole result `Array(Todo)` — RSS grows linearly
  with result size.
- **Streamed** (clean keyset walk, small page, discard each row) keeps memory
  bounded — it never holds the full set.

Reports the RSS delta for each (sampled via `ps` on macOS / `/proc/self/statm`
on Linux, falling back to GC heap size). At billion-row scan sizes `to_a` OOMs;
streaming does not.

> **Pending API.** Thread 2's `each_streamed` (§2.3) is the real streaming API.
> The harness approximates it with a clean keyset walk until that merges (TODO in
> `run.cr`).

---

## Interpreting `RESULTS.md`

`run.cr` writes a Markdown table with:

- the **run configuration** (adapter, actual row/tenant counts, page/depth/IN
  sizes, Crystal version, timestamp);
- **headline timings** per benchmark/variant with a one-line note;
- a **"How this scales to 100M+/1B"** section explaining the O-class invariance;
- **notes on the IN-list benchmark** (per-engine bind-param caps).

Read the *ratios*, not the absolute seconds — absolute times depend on the
machine, but the relationships (OFFSET ≫ keyset at depth, full-scan ≫ index,
`to_a` RSS ≫ streamed RSS) hold across hardware and grow with table size.

---

## Scaling up locally, and to 100M+/1B

Bump the seed:

```sh
CURRENT_ADAPTER=sqlite crystal run --release bench/seed.cr -- \
  --rows 10_000_000 --tenants 50_000 --db-path /tmp/grant_bench_10m.db
CURRENT_ADAPTER=sqlite crystal run --release bench/run.cr -- \
  --db-path /tmp/grant_bench_10m.db --depth 1000 --in-size 100_000
```

We benchmark at 1–10M because the access patterns are **O-class invariant** with
respect to row count: the curves measured at 1–10M are the same ones that bite at
100M–1B (the OFFSET cliff is steeper, the unindexed scan is untenable, `to_a`
OOMs sooner). A literal 1B-row SQLite file is ~50–100 GB and not something we
materialize on a laptop — the point is the *shape* of the curve, which the
documented scale demonstrates honestly.

## Running against PostgreSQL / MySQL (optional)

The harness only wires up SQLite. To benchmark another adapter, register its
connection in `bench/bench_helper.cr` the same way (`Grant::Connections <<
Grant::Adapter::Pg.new(name: "bench", url: ...)`) with the driver shard present,
and pass the matching URL. The `--adapter` label is recorded so the harness stays
honest about what it actually ran.
