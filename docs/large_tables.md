# Large Tables & High-Scale Queries

This is the playbook for operating Grant against a single very large — often
multi-tenant — table: hundreds of millions to billions of rows, live and test
data mixed, where naive `WHERE` / `IN` / pagination falls off a cliff.

It is written for two audiences:

1. You are **adopting Amber onto an existing large database** and need Grant to
   behave well from day one.
2. You started small and are **growing into** a large table and want to get
   ahead of the cliff.

The features compose. Apply them roughly in this order:

1. **Tenant scoping** — never scan the whole table when you meant one tenant.
2. **Keyset batching** — iterate large result sets in bounded memory.
3. **Index hints + safe fallback** — nudge the planner when it picks wrong.
4. **`IN`-list chunking** — stay under the driver's bind-parameter cap.
5. **Result streaming** — single forward pass without materializing the Array.

Each section says **what to expect**, **how to read `EXPLAIN`**, and **which
composite index to add**.

---

## 1. Tenant scoping (start here)

On a billion-row shared table the single most important rule is: *never issue a
query without the tenant filter.* An accidental full scan is the footgun.

Declare the model multi-tenant and Grant installs a `default_scope` that filters
by the current tenant and **raises if no tenant is set** — so a forgotten filter
fails loudly instead of scanning the table.

```crystal
class Todo < Grant::Base
  column id : Int64, primary: true
  column tenant_id : Int64
  column done : Bool = false
  column created_at : Time

  multitenant :tenant_id
end
```

Set the current tenant with a fiber-local context (mirrors Grant's sharding
context — safe across concurrent fibers/requests):

```crystal
Grant::Tenant.with(current_tenant_id) do
  Todo.where(done: false).find_each { |t| ... }   # => WHERE tenant_id = ? AND done = ?
end
```

- `Grant::Tenant.with(id) { ... }` — set the tenant for the block (fiber-local).
- `Grant::Tenant.current` — the current tenant, or `nil`.
- `Grant::Tenant.current!` — the current tenant, raising `Grant::NoTenantError`
  if unset (this is what the default scope calls).

### Bypassing the scope (deliberately)

Admin / cross-tenant jobs use `unscoped`, which skips the default scope and does
**not** require a tenant:

```crystal
Todo.unscoped.where(done: true).count   # every tenant — use with care
```

> **Danger:** `unscoped` removes the guard rail. On a large table an unscoped
> query is a full scan. Reach for it only for genuine cross-tenant work, and
> pair it with `LIMIT` / batching.

### What to expect / EXPLAIN / index

Every query under `Grant::Tenant.with` gains `WHERE tenant_id = ?`. For this to
be fast, the tenant column must lead a composite index that also covers your
common filters and sort:

```sql
CREATE INDEX idx_todos_tenant_created ON todos (tenant_id, created_at);
```

`EXPLAIN` should show an **index scan / range scan on `idx_todos_tenant_created`**
(Postgres: `Index Scan using idx_todos_tenant_created`; MySQL: `type: ref`,
`key: idx_todos_tenant_created`; SQLite: `SEARCH todos USING INDEX ...`). If you
see a **Seq Scan / `type: ALL` / `SCAN todos`**, the index is missing or the
leading column isn't `tenant_id`.

---

## 2. Keyset batching (bounded memory, resumable)

For iterating a large tenant's rows, use keyset (cursor) batching — already built
into Grant via `in_batches` / `find_each` / `find_in_batches`. These page on the
primary key (`WHERE pk > last_seen`), **not** `OFFSET`, so they stay O(batch)
no matter how deep you go.

```crystal
Grant::Tenant.with(t) do
  Todo.where(done: false).find_each(batch_size: 1000) do |todo|
    process(todo)
  end
end
```

### What to expect / EXPLAIN / index

Each batch is one indexed range query (`pk > ? LIMIT n`). Avoid `OFFSET`
pagination at depth: `OFFSET 1_000_000` makes the database walk and discard a
million rows per page — an O(n²) cliff over a full pass. `EXPLAIN` an `OFFSET`
query at depth shows a large `rows`/cost; the keyset query stays flat.

Keyset batching needs the primary key (or your cursor column) indexed — it
already is for the PK. If you batch with a custom `start`/`finish` window on
another column, index that column (ideally trailing `tenant_id`).

---

## 3. Index hints with safe fallback

Sometimes the planner picks the wrong index (stale statistics, skewed data,
mixed live+test rows). Grant lets you hint — and, crucially, **degrade safely**
when the hint can't be honored, because a hint changes the *plan*, never the
*results*.

```crystal
Todo.where(tenant_id: t).use_index("idx_todos_tenant_created").to_a
Todo.where(...).force_index("idx_todos_tenant_created")
Todo.where(...).ignore_index("idx_bad")              # MySQL only
```

Rendering is per-adapter (virtual dispatch — no hard-coded adapter checks):

| Adapter   | `use_index`        | `force_index`      | `ignore_index` |
|-----------|--------------------|--------------------|----------------|
| MySQL     | `USE INDEX (...)`  | `FORCE INDEX (...)`| `IGNORE INDEX (...)` |
| SQLite    | `INDEXED BY x`     | `INDEXED BY x`     | (degrades)     |
| Postgres  | (degrades)         | (degrades)         | (degrades)     |

PostgreSQL has no core planner-hint syntax. If you truly need it, the
`pg_hint_plan` extension exists, but Grant does **not** depend on it — the
safe-fallback path covers Postgres by degrading.

### The safe fallback — `Grant.settings.index_hint_mode`

When the adapter can't honor a hint, or the named index doesn't exist (Grant
catches the adapter's "no such index" error), behavior is controlled by:

- `:warn` (**default**) — log a warning and **re-run the query without the
  hint**. The query always succeeds and returns identical results.
- `:strict` — raise `Grant::UnsupportedIndexHintError` (unsupported kind/adapter)
  or surface the DB error (missing index). For environments that want hints
  guaranteed.
- `:ignore` — silently drop the unsupported hint (no warning).

```crystal
Grant.settings.index_hint_mode = :strict   # fail loudly in CI/staging
```

This is the "safe way to fail from optimized query patterns": you can sprinkle
hints for performance and trust that a typo'd or dropped index can never break
production — it just falls back to the planner's default.

### What to expect / EXPLAIN / index

Hints only matter if the index exists. Add the composite index first (§1), then
hint toward it only if `EXPLAIN` shows the planner ignoring it. Compare
`EXPLAIN` with and without the hint: identical row output, (hopefully) a cheaper
plan with it. If the plans are identical, the hint isn't helping — remove it.

---

## 4. Large-`IN`-list chunking

`where(col: array)` with a huge array (e.g. one million ids) would emit a single
`IN (?, ?, ... ×1M)` and blow the driver's bind-parameter cap
(SQLite's `SQLITE_MAX_VARIABLE_NUMBER`, etc.). Grant transparently splits it.

When `array.size > Grant.settings.in_clause_limit` (default **1000**):

- **Reads** (`select` / `pluck` / `ids` / `count`) split the list into chunks,
  run one query per chunk, and combine:
  - `select` concatenates and **de-duplicates full records by primary key**.
  - `count` **sums** chunk counts.
  - `ids` concatenates and de-duplicates primary keys.
  - `pluck` concatenates rows.
- **`order` + `limit` are honored across chunks.** With an `order`, chunk results
  are **merge-sorted in memory** to produce the correct global ordering (this
  costs O(total rows) memory for the merged set). With a `limit` and no order,
  collection **stops early** once enough rows are gathered.
- **Writes** (`update_all` / `delete_all`) chunk the conditions and run N
  statements **inside a single transaction**, returning the **summed**
  `rows_affected`.

Override the chunk size per query, or globally:

```crystal
Todo.where(id: huge_id_array).in_chunks(of: 500).to_a
Grant.settings.in_clause_limit = 2000
```

Chunking logs at **debug** (`grant.query`) when it engages, including the column,
total value count, and chunk size.

### Caveats

- **`count` is a sum of per-chunk counts.** Because `IN`-list chunks partition
  the value set, a plain `COUNT(*)` over a single oversized `IN` column is not
  double-counted. If you need a `DISTINCT` count across chunks (e.g. the rows
  could match via overlapping conditions), prefer `ids` (which de-duplicates) and
  count the result: `query.ids.size`.
- Only a **single oversized `IN` list** is chunked (the documented common case).
  Other `WHERE` conditions are replayed verbatim on every chunk.
- `NOT IN` is **not** chunked (splitting a `NOT IN` by union would change
  semantics); keep `NOT IN` lists under the limit.

### What to expect / EXPLAIN / index

Each chunk is an ordinary `IN (...)` query — `EXPLAIN` it like any other. Ensure
the `IN` column is indexed (often the primary key, already indexed). The
in-memory merge for `order` is the price of correctness across chunks; if you
can express the filter as a range (`BETWEEN`) instead of a giant `IN`, prefer the
range — it's one indexed query with no merge.

---

## 5. Result streaming

For a single, unbounded forward pass over a very large result set — where even
batching's per-batch Array is too much, or you simply want to pipe rows straight
through — stream them one at a time off the live `DB::ResultSet`:

```crystal
Grant::Tenant.with(t) do
  Todo.where(done: false).each_streamed do |todo|   # hydrated one row at a time
    export(todo)
  end
end

# Class-level form respects the model's current scope (incl. multitenant):
Todo.each_streamed { |t| ... }
```

Grant hydrates one record per row and never builds the full `Array`. Index-hint
safe fallback still applies.

### Streaming vs. `in_batches`

| Use **`each_streamed`** when…            | Use **`in_batches` / `find_each`** when…       |
|------------------------------------------|------------------------------------------------|
| Single forward pass, read-only           | You're writing as you go (long-running updates) |
| Unbounded, fire-and-forget               | You need it resumable / restartable             |
| Minimal memory, no per-batch overhead    | You want a bounded transaction per batch        |
| You don't need eager-loaded associations | You need `includes`/`preload` associations      |

`each_streamed` holds one database connection open for the duration of
iteration. For very long passes prefer `in_batches`, which checks out a
connection per batch and is safe to interleave with writes.

### Adapter caveats

Streaming relies on the driver yielding rows lazily from the result set. Some
client/driver combinations **buffer the whole result set** on the client before
yielding the first row (notably classic MySQL client buffering) — in that case
memory is not actually bounded. Where true server-side cursors matter, prefer
keyset `in_batches`, which is bounded regardless of driver buffering.

---

## Putting it together

The canonical answer to *"how do I pull just that tenant's rows from a massive
table, fast?"*:

```crystal
# 1. tenant column + composite index: (tenant_id, created_at)
# 2. scope to the tenant   3. batch by keyset   4. (optionally) hint the index
Grant::Tenant.with(tenant_id) do
  Todo.where(done: false)
    .use_index("idx_todos_tenant_created")   # degrades safely if absent
    .find_each(batch_size: 1000) do |todo|
      process(todo)
    end
end
```

| Setting                          | Default | Purpose                                   |
|----------------------------------|---------|-------------------------------------------|
| `Grant.settings.index_hint_mode` | `:warn` | How unsupported/missing hints behave      |
| `Grant.settings.in_clause_limit` | `1000`  | `IN`-list size before chunking engages    |

For benchmark numbers (keyset vs OFFSET, hinted vs un-hinted, chunked `IN`,
streaming memory profile) see `bench/RESULTS.md`.
