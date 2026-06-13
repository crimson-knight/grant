# Async & Sharded Queries

Grant ships a genuinely parallel async query layer and a horizontal-sharding
router that fans queries out across shards. Both are built on Crystal's
**fibers** — lightweight, cooperative, scheduler-managed coroutines. This is
where Grant has a real edge over Rails/ActiveRecord:

- **No thread pool to size or starve.** Rails' `load_async` hands work to a
  fixed `async_query_executor` thread pool; if it's exhausted the query runs
  synchronously on the calling thread. Grant spawns a fiber per operation —
  spawning thousands is cheap.
- **No GVL.** Ruby's Global VM Lock serializes Ruby execution, so async mostly
  helps overlap I/O wait. Crystal fibers also overlap I/O, but without a GVL
  contending on the interpreter.
- **Cooperative, not preemptive.** Fibers yield at I/O points (the DB driver's
  socket reads), so scatter-gather across N shards overlaps all N round-trips
  without OS-thread overhead.

> The async machinery and the scatter-gather executor already existed in Grant;
> this layer is about ergonomics and correct routing, not new concurrency
> primitives.

---

## 1. Async query methods (`async_*`)

Every async method returns a `Grant::Async::Result(T)` immediately and runs the
work on a background fiber. Call `.wait` to block for the value.

### Model-class level (`Grant::Async::ClassMethods`)

```crystal
User.async_count          # => Result(Int64)
User.async_sum(:age)      # => Result(Float64)
User.async_avg(:age)      # => Result(Float64?)
User.async_min(:age)      # => Result(Grant::Columns::Type)
User.async_max(:age)      # => Result(Grant::Columns::Type)
User.async_pluck(:email)  # => Result(Array(Grant::Columns::Type))
User.async_pick(:email)   # => Result(Grant::Columns::Type?)
User.async_find(1)        # => Result(User?)
User.async_find!(1)       # => Result(User)
User.async_find_by(email: "a@b.c")  # => Result(User?)
User.async_first          # => Result(User?)
User.async_last           # => Result(User?)
User.async_all            # => Result(Array(User))
```

### Query-builder / relation level (`Grant::Async::QueryMethods`)

```crystal
rel = User.where(active: true).order(created_at: :desc)

rel.async_select          # => Result(Array(User))
rel.async_count           # => Result(Int64)
rel.async_sum(:age)       # => Result(Float64)
rel.async_avg(:age)       # => Result(Float64?)
rel.async_min(:age) / rel.async_max(:age)
rel.async_exists?         # => Result(Bool)
rel.async_pluck(:email)   # => Result(Array(Grant::Columns::Type))
rel.async_pick(:email)    # => Result(Grant::Columns::Type?)
rel.async_first / rel.async_last
rel.async_delete          # => Result(DB::ExecResult)
rel.async_update_all("status = 'archived'")  # => Result(DB::ExecResult)
rel.async_touch_all(:updated_at)             # => Result(Int64)
```

---

## 2. `load_async` (Rails-familiar alias)

`load_async` is an alias for the async read on both the relation and the model
class, returning the same `Async::Result(Array(Model))`. It exists so code (and
muscle memory) coming from Rails 7+/8 reads naturally:

```crystal
# Relation form (preferred — filtered reads)
result = User.where(active: true).load_async   # fiber starts immediately
# ... fire other queries, do unrelated work ...
users = result.wait                            # block for the rows

# Model-class form (whole-table read)
result = User.load_async
users  = result.wait
```

`load_async` on a relation == `async_select`; on the model class == `async_all`.

---

## 3. Working with a `Result(T)`

`Grant::Async::Result(T)` (aliased as `Grant::Async::AsyncResult`) is the handle
returned by every async method. It runs its block on a fiber spawned at
construction time.

| Method | Returns | Description |
|--------|---------|-------------|
| `wait` | `T` | Block until the operation finishes; re-raises any error. |
| `wait_with_timeout(span)` | `T` | Block up to `span`; raises `AsyncTimeoutError` past the deadline. |
| `completed?` | `Bool` | Non-blocking check of whether the fiber finished. |
| `on_error { \|ex\| ... }` | `T` | Block for the value; on failure, call the recovery block (must return a `T`). |
| `then { \|v\| ... }` | `Result(U)` | Chain: when this resolves, run the block on a new fiber. |
| `map { \|v\| ... }` | `Result(U)` | Transform the resolved value (same shape as `then`). |
| `flat_map { \|v\| ... }` | `Result(U)` | Chain when the block itself returns a `Result(U)`. |

```crystal
# wait
count = User.async_count.wait

# then / map — chain a transformation on its own fiber
names = User.where(active: true)
            .load_async
            .map { |users| users.map(&.name) }
            .wait

# on_error — recover with a fallback value
total = User.async_count.on_error { |_ex| 0_i64 }

# wait_with_timeout
begin
  rows = User.where(active: true).async_select.wait_with_timeout(2.seconds)
rescue Grant::Async::AsyncTimeoutError
  # deadline exceeded
end
```

> Note: an error raised inside the async block is captured and only surfaces
> when you `wait` (or via `on_error`). A `Result` you never wait on can swallow
> its exception — always `wait` (or coordinate) the results you care about.

---

## 4. Running many in parallel (`parallel_execute` + `Coordinator`)

`parallel_execute` yields a `Coordinator`, fires the async ops you add, and
blocks until all complete (raising `AsyncCoordinationError` if any failed):

```crystal
results = {} of String => Grant::Async::Result(Int64)

User.parallel_execute do |coordinator|
  results["users"]    = User.async_count
  results["posts"]    = Post.async_count
  results["comments"] = Comment.async_count

  coordinator.add(results["users"])
  coordinator.add(results["posts"])
  coordinator.add(results["comments"])
end
# all three counts ran concurrently
user_count = results["users"].wait
```

The `Coordinator` is `WaitGroup`-backed; `add` registers a result and spawns a
fiber that waits on it, `wait_all` blocks for the group. `ResultCoordinator(T)`
is a typed variant that also stores the values for retrieval by id.

---

## 5. Horizontal sharding & scatter-gather

A model opts into sharding by including `Grant::Sharding::Model` and declaring a
shard key with `shards_by`:

```crystal
class Account < Grant::Base
  connection "primary"
  table accounts

  include Grant::Sharding::Model

  # Any column works as a shard key — not just id/user_id/tenant_id.
  shards_by :account_id, strategy: :hash, count: 4

  column id : Int64, primary: true
  column account_id : Int64
  column name : String
end
```

Supported strategies: `:hash` (even distribution), `:range` /  `:time_range`
(ordered key ranges), `:geo` (region lookup). Composite keys are supported:
`shards_by [:region, :customer_id], strategy: :hash, count: 4`.

### How routing works (the fix)

When you build a query, the `QueryRouter` inspects the `WHERE` conditions and
matches their **column-name strings** against the model's declared shard-key
column names — registered from `shards_by` as `ShardConfig#key_column_names`.
There is **no hard-coded list of routable columns**; any declared shard key
routes:

- If the query pins **every** declared shard key with an equality (`=`)
  condition, the router resolves the exact shard (`SingleShardExecution`) and
  the query touches **one** shard.
- Otherwise (missing key, range/`IN`/non-equality on the key, or a value outside
  all defined ranges) it falls back to **scatter-gather** across all shards —
  correct, never misrouted.

```crystal
# Pins the shard key -> single shard
Account.where(account_id: 42_i64).select        # one shard

# No shard key -> scatter-gather across every shard
Account.where(name: "Acme").select              # all shards, in parallel

# Force a shard / all shards explicitly
Account.on_shard(:shard_2).where(name: "x").select
Account.on_all_shards.count
```

### Scatter-gather is fiber-parallel

`ScatterGatherExecution` does not query shards one-by-one. It uses
`Grant::Async::ShardedExecutor.execute_and_wait`, which spawns one
`AsyncResult` (fiber) per shard and waits on all of them with a `Coordinator`.
The N shard round-trips overlap; results are merged, then any `ORDER BY` /
`LIMIT` from the original query is re-applied to the combined set. `count`
sums the per-shard counts; `exists?` short-circuits on the first shard that
has a match.

---

## 6. `ShardedExecutor` — the parallel-shard toolkit

`Grant::Async::ShardedExecutor` is the building block for fanning an operation
across shards on fibers. All methods set the per-fiber shard context via
`ShardManager.with_shard` so the block runs against the right connection.

| Method | Returns | Use |
|--------|---------|-----|
| `execute_across_shards(shards) { \|shard\| AsyncResult }` | `Hash(Symbol, AsyncResult(T))` | Kick off one async op per shard; don't wait. |
| `execute_and_wait(shards) { \|shard\| AsyncResult }` | `Hash(Symbol, T)` | Run per shard in parallel, wait, return per-shard values. |
| `execute_and_aggregate(shards) { ... }` | `T` | As above, then auto-aggregate: sum numbers, flatten arrays, `any?` for bools. |
| `map_reduce(shards, map:, reduce:)` | `U` | Parallel map per shard, then reduce the values. |
| `execute_with_timeout(shards, timeout) { ... }` | `Hash(Symbol, T?)` | Per-shard timeout; slow/failed shards yield `nil`. |
| `execute_with_fallback(primary, fallbacks) { ... }` | `T` | Try the primary shard; on error walk the fallback shards in order. |

```crystal
shards = Grant::ShardManager.shards_for_model("Account")

# Per-shard counts, all in parallel:
per_shard = Grant::Async::ShardedExecutor.execute_and_wait(shards) do |shard|
  Grant::Async::AsyncResult.new do
    Grant::ShardManager.with_shard(shard) { Account.where(active: true).count }
  end
end
# => {:shard_0 => 10_i64, :shard_1 => 7_i64, ...}

# Aggregate total across shards:
total = Grant::Async::ShardedExecutor.execute_and_aggregate(shards) do |shard|
  Grant::Async::AsyncResult.new do
    Grant::ShardManager.with_shard(shard) { Account.where(active: true).count }
  end
end

# map_reduce — collect all matching rows, then post-process:
names = Grant::Async::ShardedExecutor.map_reduce(
  shards,
  map: ->(shard : Symbol) {
    Grant::Async::AsyncResult.new do
      Grant::ShardManager.with_shard(shard) { Account.where(active: true).select }
    end
  },
  reduce: ->(per_shard_rows : Array(Array(Account))) {
    per_shard_rows.flatten.map(&.name).sort
  }
)
```

`execute_with_timeout` and `execute_with_fallback` are the resilience knobs:
the first bounds how long you'll wait on any one shard; the second lets a
read fall back to replica/sibling shards if its primary is down.

---

## 7. Why this beats Rails' async story

- **Scatter-gather for free.** Rails has no built-in cross-shard fan-out; you'd
  hand-roll threads. Grant's router fans out on fibers automatically when a
  query lacks a shard key.
- **Fibers, not threads.** No pool sizing, no GVL, no silent fallback to
  synchronous execution under load. Spawning a fiber per shard (or per async
  query) is cheap enough that the natural code is also the fast code.
- **Cooperative scheduling at I/O points.** While one shard's socket read is in
  flight, the scheduler runs the others — the wall-clock cost of N shards
  approaches the cost of the slowest single shard, not their sum.

---

## See also

- `docs/async.md` — original async feature notes.
- `docs/SHARDING.md` — sharding strategies, resolvers, and limitations.
- `src/grant/async/` — `Result`, `Coordinator`, `ShardedExecutor`, `Promise`.
- `src/grant/sharding/` — `QueryRouter`, `ShardedQueryBuilder`, resolvers.
