# Grant: Multi-Target Adapters & Large-Scale Query Plan

Companion to `GRANT_AR_PARITY_REVIEW.md`, `GRANT_RELEASE_READINESS.md`, and
`GRANT_PARITY_AND_STI_PLAN.md`. This document covers four threads that go
*beyond* ActiveRecord parity — capabilities Rails cannot offer because of
Ruby's runtime, but which Crystal's compile-time type system and lightweight
fibers make natural:

1. **Compile-target adapters** — one database adapter per compile target
   (mobile / desktop / web), with per-target column availability.
2. **Large-table / high-scale query toolkit** — index hints with safe
   fallback, large-`IN`-list chunking, result streaming, tenant scoping, and a
   benchmark harness validated against a simulated billion-row table.
3. **MySQL 8/9 `caching_sha2_password` authentication** — finish the OpenSSL3
   auth handshake so Grant works against default-configured MySQL 8 and 9.
4. **Async + sharded query hardening** — the async/scatter-gather machinery
   already exists; fix the hard-coded shard-key routing and un-pend the
   integration suite.

The decisions below were confirmed with the project lead:

- **MySQL auth:** locate the existing `open_secure_sockets_layer_three` OpenSSL3
  shard, finish its bindings, and integrate — do not rebuild from scratch.
- **Build order:** implement all four threads in parallel (worktree-isolated
  agents, merged sequentially).
- **Compile-target columns:** design *per-target column gating* now, alongside
  per-target adapter selection — not as a later extension.

---

## 0. Ground truth (verified against current `src/`, `main` @ 80fa836)

Before designing, the current state was audited file-by-file. Key facts that
shape the design:

- **Adapters are already opt-in.** `src/grant.cr` requires only
  `./adapter/base`. The concrete adapters (`src/adapter/pg.cr`,
  `mysql.cr`, `sqlite.cr`) each `require` their driver shard on line 2 and are
  pulled in *only* when the app explicitly requires them. The driver shards
  (`pg`, `mysql`, `sqlite3`) are `development_dependencies`, so a consuming app
  declares only the driver it needs. → **The compile-target boundary is already
  half-built; this thread is mostly an ergonomic DSL + guard rails + per-target
  columns + docs, not a rewrite.**
- **Connection establishment takes a `url : String` eagerly**
  (`ConnectionRegistry.establish_connection`). There is no lazy/proc URL form —
  device targets that compute their DB path at runtime need one.
- **Async + scatter-gather already exist and are genuinely parallel.**
  `Grant::Async::{Result, Coordinator, ShardedExecutor}` (WaitGroup-based),
  `async_count/find/all/select/first/pluck`, and `ScatterGatherExecution`
  spawn a fiber per shard. → **This thread is hardening, not construction.**
- **`QueryRouter` hard-codes shard-key column names** in a `String`→`Symbol`
  `case` (`query_router.cr:43-56`); unknown columns become `:unknown_field`.
  This is the real defect behind the 9 pending `sharding_integration_spec`
  examples.
- **Keyset batching already exists.** `in_batches`/`find_each`/`find_in_batches`
  on the query builder are keyset (`WHERE pk > last`), not OFFSET. (The legacy
  *class-level* `find_in_batches` in `querying.cr` is still OFFSET-based — leave
  it, it's documented as backward-compat.)
- **Absent for scale:** index hints, large-`IN` chunking, result streaming, a
  first-class tenant-scoping helper, and any benchmark harness.
- **MySQL auth is partially done in a local fork.**
  `~/open_source_coding_projects/crystal-mysql` (v0.15.0) has skeleton
  `caching_sha2_password` code, but `connection.cr:60` raises "not implemented"
  and references `LibCrypto.rsa_size`/`rsa_oaep_encrypt` that are **not
  defined** (won't link). A separate OpenSSL3 shard
  (`open_secure_sockets_layer_three`, ~11 passing tests, described in the
  2025-06-01 voice transcript) exists but was **not found** in either working
  root — it must be located.
- **CI runs `mysql:8.0` with the default `caching_sha2_password`** and no
  `mysql_native_password` override — MySQL specs may be silently relying on a
  workaround.

---

## Thread 1 — Compile-Target Adapters

### 1.1 The design decision (documented, deliberate)

> **A Grant model is compiled for exactly one database adapter per build
> target. The adapter is chosen at compile time by a target flag. Targets may
> share an adapter (e.g. iOS and desktop both use SQLite); the web target uses
> Postgres or MySQL. A single binary never links more than one adapter it
> doesn't use.**

Rationale and the boundary we are *intentionally* drawing:

- A mobile/desktop binary that ships Postgres/MySQL client code is bloated and,
  for iOS/watchOS, may not link at all. Opt-in adapters keep each target lean.
- **We deliberately do NOT support a device talking to a remote Postgres
  directly.** A device uses SQLite locally and **synchronizes to the server via
  the API layer**; the server owns the Postgres/MySQL connection. "Cutting out
  the middleman" (device → cloud DB) is rejected on purpose: it leaks
  credentials to the device, couples the schema to the client, and defeats the
  API as the integrity/permission boundary. This is a feature, not a
  limitation, and must be stated plainly in the docs.
- The *same model classes* are shared across targets in a monorepo. Only the
  adapter binding (and, per §1.4, the column set) differs per target.

### 1.2 Target flags

Adopt three semantic target flags, mutually exclusive by convention, set with
`crystal build -Dgrant_target_<x>`:

- `grant_target_mobile`
- `grant_target_desktop`
- `grant_target_web`

Plus three adapter-presence flags that gate the actual `require`s and driver
linkage (a target maps to one of these):

- `grant_sqlite`, `grant_pg`, `grant_mysql`

Targets → adapters is a convention the app expresses once (mobile+desktop →
sqlite, web → pg/mysql). Keeping *both* layers lets a power user override (e.g.
a desktop build that talks to Postgres).

### 1.3 Ergonomic binding DSL + lazy URL provider

Provide `src/grant/target.cr` exposing a macro that an app uses once in its
boot/config file. It must (a) guard the adapter `require` so only the active
adapter links, and (b) register the connection. Because `require` is top-level
only, the macro expands to top-level guarded requires + a registration call:

```crystal
# config/database.cr  (compiled per target)
Grant.configure_target do
  mobile_or_desktop do            # expands under {% if flag?(:grant_target_mobile) || flag?(:grant_target_desktop) %}
    use Grant::Adapter::Sqlite
    primary url: -> { "sqlite3://#{Device.app_support_dir}/app.db" }   # lazy: resolved at first checkout
  end
  web do                          # expands under {% if flag?(:grant_target_web) %}
    use Grant::Adapter::Pg
    primary url: ENV["DATABASE_URL"]
    replica url: ENV["DATABASE_REPLICA_URL"]?     # optional reader role
  end
end
```

The blessed *low-level* pattern (what the macro expands to, and what users can
write by hand) already works today and must be documented as the fallback:

```crystal
{% if flag?(:grant_target_mobile) || flag?(:grant_target_desktop) %}
  require "grant/adapter/sqlite"
  Grant::ConnectionRegistry.establish_connection(
    database: "primary", adapter: Grant::Adapter::Sqlite,
    url_provider: -> { "sqlite3://#{Device.app_support_dir}/app.db" })
{% elsif flag?(:grant_target_web) %}
  require "grant/adapter/pg"
  Grant::ConnectionRegistry.establish_connection(
    database: "primary", adapter: Grant::Adapter::Pg, url: ENV["DATABASE_URL"])
{% end %}
```

**Framework changes required:**

1. **Lazy URL provider.** Add an `establish_connection` overload accepting
   `url_provider : -> String` (and the same on `establish_connections`). The
   provider is invoked lazily on first pool build, not at registration. Device
   targets often don't know the DB path at boot. Keep the eager `url : String`
   overload.
2. **`Grant.configure_target` macro** (`src/grant/target.cr`) — sugar over the
   guarded pattern above. Must emit the `require` at top level. Keep it thin;
   it only organizes the guarded requires + registration calls.
3. **Guard rail.** When a model resolves an adapter for a connection that was
   never established (e.g. the active target didn't register `"primary"`, or the
   adapter wasn't compiled in), raise `Grant::AdapterNotAvailableError` naming
   the connection, the active target flag(s), and the adapters that *were*
   compiled in. Today `ConnectionRegistry#get_adapter` rescues into a vague
   fallback — replace that with the explicit error.
4. **`Grant.compiled_adapters`** — a compile-time-populated list (built from the
   presence flags) for diagnostics and the guard-rail message.

### 1.4 Per-target column gating (design now)

Extend the `column` macro with a `targets:` argument. When the active build
target is **not** in the list, the column — its ivar, getter/setter,
(de)serialization, and inclusion in `INSERT/UPDATE/SELECT *` — is **compiled out
entirely** (zero runtime cost; it does not exist on that target).

```crystal
class User < Grant::Base
  column id : Int64, primary: true
  column email : String                                   # all targets
  column password_digest : String, targets: [:web]        # server-only
  column push_token : String?, targets: [:mobile]         # device-only
  column avatar_cache : Bytes?, targets: [:mobile, :desktop]
end
```

**Semantics & rules:**

- Default (no `targets:`) = present on every target. These are the **shared
  sync columns**.
- A column gated to a target is absent from the model's field list on other
  targets — the assembler never references it, and the per-target SQL schema
  reflects the subset.
- **Primary key and any sync-key columns must be shared** (validated at
  compile time — raise if a `primary: true` column is gated).
- **Sync implications (document heavily):** the synchronization layer (the API
  boundary) must tolerate columns that exist on one side and not the other.
  Server-only columns (`password_digest`) never travel to the device;
  device-only columns (`push_token`) are pushed up explicitly via the API, not
  via blanket row sync. The doc must give a worked mobile↔web example and state
  the rule: *only shared columns participate in automatic row sync; gated
  columns are handled by explicit API endpoints.*
- Implementation: the `column` macro reads `targets:` and wraps the emitted
  ivar/accessors/serialization hooks in `{% if <active target in targets> %}`.
  The active target is read from the `grant_target_*` flags. A column with no
  matching target emits **nothing**. Must compose with STI (`include
  Grant::STI`), `attr_readonly`, encryption, and the abstract-base serialization
  fix (#41) — verify a gated column on an STI subclass and on a
  `YAML::Serializable` base round-trips on each target.

### 1.5 Tests

- Compile the same model under each of the three target flags; assert the
  compiled adapter and that the other drivers are absent (grep the generated
  code / use `Grant.compiled_adapters`).
- Lazy URL provider: connection not built until first query; provider invoked
  once.
- Guard rail: a model pointing at an unregistered connection raises
  `AdapterNotAvailableError` with a useful message.
- Per-target columns: gated column present under its target, absent under
  others (compile-time); shared columns always present; gating a `primary:`
  column fails to compile; gated column composes with STI + serialization.

### 1.6 Docs

`docs/compile_target_adapters.md`: the design decision and the device→API→DB
boundary; the `configure_target` DSL and the hand-rolled fallback; per-target
columns with a full mobile↔web sync worked example; the build commands
(`crystal build -Dgrant_target_mobile …`); the guard-rail error and how to fix
it; an explicit "why not device→cloud-DB direct" rationale.

---

## Thread 2 — Large-Table / High-Scale Query Toolkit

Target scenario (the lead's real-world case): a single multi-tenant table with
hundreds of millions to billions of rows (live + customer test data mixed),
where naive `WHERE`/`IN`/pagination falls off a cliff. We get this right from
the start rather than retrofitting (Rails only added much of this in 8.1).

### 2.1 Index hints with safe fallback

New chainable builder methods storing a hint on the query; rendered per adapter
by the assembler:

```crystal
User.where(tenant_id: t).use_index("idx_users_tenant").to_a
User.where(...).force_index("idx_users_tenant_created")
User.where(...).ignore_index("idx_bad")          # MySQL only
```

Adapter rendering (virtual dispatch on the adapter, like the `lock_clause` fix —
**no hard-coded adapter constants**):

- **MySQL:** `... FROM users USE INDEX (idx) ...` / `FORCE INDEX` / `IGNORE
  INDEX`.
- **SQLite:** `... FROM users INDEXED BY idx ...` (no force/ignore — map
  `use_index`→`INDEXED BY`, others degrade).
- **Postgres:** no planner hints in core. Degrade (see below); optionally note
  `pg_hint_plan` in docs but do not depend on it.

**Safe fallback — the "safe way to fail from optimized query patterns" the lead
asked for.** Controlled by `Grant.settings.index_hint_mode`:

- `:warn` (**default**) — if the adapter doesn't support hints, or the named
  index doesn't exist (catch the adapter's "no such index" error code), log a
  warning and **re-run the query without the hint**. The query always succeeds.
- `:strict` — raise `Grant::UnsupportedIndexHintError` / surface the DB error.
  For envs that want hints guaranteed.
- `:ignore` — silently drop unsupported hints (no warning).

The fallback must be implemented so a hint never changes *results*, only the
plan — re-running without the hint is always semantically safe.

### 2.2 Large-`IN`-list chunking

When `where(col: array)` (or `where(col, :in, array)`) has
`array.size > Grant.settings.in_clause_limit` (default **1000**), Grant must not
emit one `IN (?, ?, … ×1M)` that blows the driver's bind-parameter cap. Behavior:

- For **reads** (`select`, `pluck`, `ids`, `count`, `find_each`): split the list
  into chunks of `in_clause_limit`, run one query per chunk, and concatenate
  (de-duplicating by primary key for full-record reads). Preserve `order/limit`
  semantics correctly: when `limit` is set, stop once satisfied; when `order` is
  set across chunks, merge-sort the chunk results (document the in-memory merge
  cost). For `count`, sum chunk counts (only correct without `DISTINCT` across
  chunks — document; offer `distinct` path that unions ids first).
- For **`update_all`/`delete_all`**: chunk the affected ids and run N statements
  in a transaction; return summed `rows_affected`.
- Expose `Grant.settings.in_clause_limit` and a per-query
  `.in_chunks(of: n)` override. Log at debug when chunking engages.

### 2.3 Result streaming

For full scans / very large reads that shouldn't be fully materialized in
memory, add a streaming path over crystal-db's `ResultSet` (which yields rows
lazily):

```crystal
User.where(tenant_id: t).each_streamed do |user|   # hydrate + yield one at a time
  process(user)
end
```

- Backed by the adapter executing `db.query` and iterating the result set,
  hydrating one record per row, never building the full `Array`.
- Combine with keyset `in_batches` for the bounded-memory + bounded-txn pattern;
  document when to use streaming (single pass, unbounded) vs `in_batches`
  (chunked, resumable, safe for long-running writes).
- Note adapter caveats (e.g. server-side cursors vs client buffering) in docs.

### 2.4 First-class tenant scoping

A multi-tenancy helper built on the existing `default_scope` + a fiber-local
current-tenant context (mirror `ShardManager`'s fiber-local pattern):

```crystal
class Todo < Grant::Base
  multitenant :tenant_id           # adds default_scope filtering by Tenant.current
end

Grant::Tenant.with(tenant_id) do   # fiber-local; all queries inside auto-filter
  Todo.where(done: false).find_each { |t| ... }   # => WHERE tenant_id = ? AND ...
end
```

- `multitenant(col)` installs a `default_scope { |q| q.where(col => Grant::Tenant.current!) }`
  and a guard that **raises if no tenant is set** (prevent accidental
  cross-tenant full-table scans — the billion-row footgun).
- `Grant::Tenant.with(id, &)` / `Grant::Tenant.current` / `current!` — fiber-local.
- `Todo.unscoped { ... }` still bypasses for admin/cross-tenant jobs (document
  the danger).
- This is the *primary* documented answer to "how do I pull just that tenant's
  rows from a massive table": tenant column + composite index `(tenant_id, …)` +
  keyset batching + (optionally) index hint.

### 2.5 Benchmark harness + billion-row simulation

A `bench/` directory (not part of the shipped lib; runnable locally and in CI):

- **Seed generator** — a configurable multi-tenant "todos" generator:
  `crystal run bench/seed.cr -- --rows 10_000_000 --tenants 5_000 --adapter sqlite`.
  Inserts via batched `insert_all` with a progress meter. Documented path to
  scale to 100M+/1B (and why we benchmark at 1–10M locally but the pattern holds
  — state this honestly; we are **not** materializing a literal 1B rows on a
  laptop).
- **Benchmarks** comparing, with `Benchmark.ips`/wall-clock and row counts
  logged:
  1. keyset `in_batches` vs legacy OFFSET pagination at depth (show OFFSET's
     O(n²) cliff);
  2. tenant-scoped fetch with vs without a `(tenant_id, created_at)` composite
     index, and with `force_index`;
  3. single huge `IN` (pre-chunking, expect failure/slow) vs chunked `IN`;
  4. `each_streamed` memory profile vs `to_a` on a large scan.
- **Output** a `bench/RESULTS.md` table the docs link to, with the adapter,
  row/tenant counts, and the headline numbers. **No silent caps:** if a bench is
  run at reduced scale, the harness logs the actual N it used.

### 2.6 Docs

`docs/large_tables.md`: the whole playbook — tenant scoping first, then keyset
batching, then index hints + safe fallback, then `IN` chunking, then streaming —
each with "what to expect / how to read EXPLAIN / how to apply it back to your
schema (which composite index to add)". Link `bench/RESULTS.md`. Frame it as
"adopting Amber onto an existing large database, or growing into one."

---

## Thread 3 — MySQL 8/9 `caching_sha2_password` Authentication

Goal: Grant works out-of-the-box against default-configured MySQL 8 and 9 (whose
default auth plugin is `caching_sha2_password`), with no
`mysql_native_password` workaround.

### 3.1 Locate & finish the OpenSSL3 shard (per the lead's decision)

1. **Find** `open_secure_sockets_layer_three` (the OpenSSL3 shard from the
   2025-06-01 call — native password response, caching_sha2 fast-auth, public-key
   full-auth, secure random; ~11 passing tests). Search the whole disk, not just
   the two working roots. If genuinely unrecoverable, report that and fall back
   to completing the bindings in-fork (do not silently rebuild without saying
   so).
2. **Complete the missing FFI bindings** referenced but undefined in
   `~/open_source_coding_projects/crystal-mysql/src/openssl/lib_crypto.cr`
   (`rsa_size`, `rsa_oaep_encrypt`). OpenSSL 3 deprecates the legacy `RSA_*`
   API — prefer the `EVP_PKEY` route (`EVP_PKEY_encrypt` with
   `RSA_PKCS1_OAEP_PADDING`, SHA-256 OAEP) over `RSA_public_encrypt`. Reuse the
   located shard's bindings if present rather than duplicating.
3. **Finish the handshake** in `crystal-mysql/src/mysql/connection.cr` (currently
   `raise "… not implemented"` at line ~60) and `packets.cr`: detect
   `auth_plugin_name`; for `caching_sha2_password`, send the fast-auth
   SHA-256 scramble; on `full_auth` request the server public key (`0x02`),
   XOR the password with the nonce, RSA-OAEP encrypt, and send. Handle the
   `mysql_native_password` and empty-password paths already sketched.

### 3.2 Integrate into Grant

- Point Grant's `shard.yml`/`shard.lock` MySQL dependency at the fixed fork
  (the lead's `crimson-knight/crystal-mysql` once pushed; until then, document
  the path/branch). Keep the upstream pin documented so we can switch back if
  upstream merges it.
- Remove any `mysql_native_password` reliance from CI/compose once real auth
  works (Thread 3b below).
- Add a Grant-level integration spec that connects to MySQL 8 **and** 9 with the
  default plugin and round-trips a model.

### 3.3 Thread 3b — Dedicated Docker test image (separate agent, as requested)

A standalone agent whose **only** job is to stand up the MySQL test
infrastructure (it does not touch the auth code):

- Extend `docker-compose.test.yml` (and `.github/workflows/spec.yml`) with
  **MySQL 8.x and MySQL 9.x** services using the **default
  `caching_sha2_password`** (no `--default-authentication-plugin` override),
  plus a user created with that plugin and the RSA public key exposed for the
  full-auth path.
- Provide a one-command bring-up (`make mysql-auth-test` or a script) and a
  health-check/wait loop so specs don't race the server.
- Document how to point local specs at it (`CURRENT_ADAPTER=mysql`,
  `MYSQL_DATABASE_URL=…`). Docker Desktop is running on the lead's machine.

### 3.4 Docs

`docs/mysql8_authentication.md`: which MySQL versions/plugins are supported, how
the handshake works (fast-auth vs full-auth, TLS vs RSA-public-key), how to
configure the user, and the OpenSSL 3 requirement. Credit/locate the security
shard. Include the "what to do if you see `caching_sha2_password … not
implemented`" troubleshooting entry.

---

## Thread 4 — Async + Sharded Query Hardening

The machinery exists and is genuinely parallel; this thread makes it correct and
tested.

### 4.1 Fix the hard-coded shard-key routing (the real defect)

`QueryRouter#extract_shard_keys` maps `where` field strings to symbols with a
hard-coded `case` (`id/user_id/tenant_id/…`); anything else becomes
`:unknown_field` and silently fails to route. Fix:

- When a model declares `shards_by :col` (or `[:c1, :c2]`), register the
  shard-key **column name strings** for that model (compile-time or at
  registration) so the router looks up by string and resolves *any* declared
  shard key — no symbol guessing.
- Route on the registered keys; if a query lacks all shard keys, fall back to
  scatter-gather (already implemented) rather than misrouting.
- Add a spec proving a custom shard-key column (e.g. `account_id`) routes to a
  single shard.

### 4.2 Un-pend the integration suite

Activate the 9 pending examples in `spec/sharding_integration_spec.cr` using the
existing `spec/support/simple_virtual_sharding.cr` harness (`with_virtual_shards`,
`track_shard_queries`): cross-strategy routing, scatter-gather correctness,
parallel-execution verification, nil-key/edge cases, data consistency. Also the
3 pending in `sharding_spec.cr` and 1 in `range_sharding_spec.cr` where feasible.

### 4.3 Async API ergonomics + docs

- Add Rails-familiar aliases: `relation.load_async` → returns the existing
  `Async::Result`; document `.wait`/`.then`/`map`/`on_error`.
- Document the parallel-shard story end-to-end: `async_*`, `parallel_execute`,
  `ShardedExecutor.{execute_and_wait, execute_and_aggregate, map_reduce,
  execute_with_timeout, execute_with_fallback}`, and that scatter-gather already
  fans out on fibers. `docs/async_and_sharded_queries.md`.
- Note Crystal's edge over Rails here: fibers make scatter-gather cheap and
  cooperative; no thread-pool/GVL caveats.

---

## Out of scope / explicitly deferred

- Device↔server **sync engine** itself (conflict resolution, change feeds). This
  plan makes the *schema/adapter* side multi-target-ready and documents the
  boundary; the sync protocol is a separate effort.
- **Postgres planner hints** beyond documenting `pg_hint_plan` (PG has no core
  hint syntax; the safe-fallback path covers PG by degrading).
- **Distributed transactions / cross-shard joins** — already explicitly
  unsupported (`sharding/limitations.cr`); unchanged.
- The previously-logged parity follow-ups (`strict_loading`, `insert_all!` bang,
  `store_accessor`, `locking_column=`, DX #37/#38) remain tracked in
  `GRANT_PARITY_AND_STI_PLAN.md`; not part of this plan.

---

## Parallel delegation plan

Six worktree-isolated agents, each on its own branch off `main`, build + test in
isolation, commit to the branch, and **report back without merging or pushing**.
Standard guardrails for every agent: test with `CURRENT_ADAPTER=sqlite`; **never
`git add lib`** (the lib symlink self-points and crashes the compiler on merge);
**never `git add -A`**; commit messages end with the project co-author trailer;
**do not push**.

| # | Agent | Repo | Deliverables |
|---|-------|------|--------------|
| 1 | Compile-target adapters | grant | §1.3 lazy URL provider + `configure_target` macro + guard rail + `compiled_adapters` + §1.4 per-target columns + tests + `docs/compile_target_adapters.md` |
| 2 | Large-table toolkit | grant | §2.1 index hints + safe fallback, §2.2 IN chunking, §2.3 streaming, §2.4 tenant scoping + tests + `docs/large_tables.md` |
| 3 | Benchmark harness | grant | §2.5 `bench/` seed generator + benchmarks + `bench/RESULTS.md` (builds against existing keyset/offset; extends to Agent 2's features after merge) |
| 4 | MySQL 8/9 auth | crystal-mysql fork (+ grant shard.yml) | §3.1 locate shard + finish FFI + handshake; §3.2 integrate + integration spec |
| 5 | Docker MySQL test image | grant | §3.3 MySQL 8.x + 9.x compose/CI services with default caching_sha2_password + bring-up script + docs |
| 6 | Async/sharding hardening | grant | §4.1 dynamic shard-key routing, §4.2 un-pend integration suite, §4.3 `load_async` alias + `docs/async_and_sharded_queries.md` |

Agents 1, 2, 6 touch `src/grant` and merge sequentially (disjoint regions
auto-merge; conflicts resolved by hand). Agent 3 is additive (`bench/`). Agent 5
touches infra files. Agent 4 is mostly a different repo. Merge order:
2 → 1 → 6 → 3 (after 2) → 5 → 4, full SQLite suite verified at each step,
nothing pushed until the lead confirms.

## Risks

- **Per-target column gating × STI × serialization** is the highest-risk
  interaction (three macro systems composing). Agent 1 must verify the #41
  abstract-base serialization fix still holds with gated columns on STI
  subclasses.
- **Index-hint safe fallback** must guarantee identical results with/without the
  hint — re-run-without-hint is only safe because hints change plans, not
  semantics; assert this in tests.
- **MySQL OpenSSL3 bindings** are the most likely to not link cleanly (FFI +
  OpenSSL 3 API churn). Locating the proven shard de-risks this; if unfound,
  flag before burning time rebuilding.
- **`IN` chunking with `order`+`limit`** has subtle merge semantics across
  chunks — test explicitly.
