# Grant — Parity Closure & Single Table Inheritance Plan

**Companions:** [`GRANT_AR_PARITY_REVIEW.md`](GRANT_AR_PARITY_REVIEW.md) (verified 211-feature audit),
[`GRANT_RELEASE_READINESS.md`](GRANT_RELEASE_READINESS.md) (release gate / blocker punch list).

**Purpose:** drive the remaining Grant↔ActiveRecord-8 parity gaps to closure, and implement
**Single Table Inheritance** as a foundational feature — designed for Crystal's static type system so
it can back type-safe **personas and permissions**.

## Principles

1. **Implement what earns its keep.** Close the gaps that real apps hit and that fit a statically
   typed compiled language.
2. **Skip Ruby-isms that hurt.** Several AR features exist only to paper over Ruby's dynamism, or rely
   on runtime reflection / metaprogramming that would cost performance or defeat Crystal's type
   system. We deliberately do **not** port these (rationale per item below).
3. **Defer the large/peripheral.** A few real gaps are big enough to be their own beta-track efforts
   (migration DSL) or belong in the framework, not the ORM (DatabaseSelector middleware).
4. **Type system is a feature, not an obstacle.** Where Rails uses strings/symbols and runtime
   dispatch, prefer compile-time macros and real classes. STI is the prime example: subclasses are
   real Crystal types, so the compiler enforces persona/permission distinctions.

## Gap disposition

### ✅ IMPLEMENT (this effort)

**Single Table Inheritance** — see the dedicated design section below. The headline.

**Persistence helpers** (all standard AR, no Ruby-ism, high frequency):
- `update_attribute` / `update_attribute!`, `update_columns` (validation-skipping targeted saves)
- `increment!` / `decrement!` / `toggle!` (in-memory + persist)
- `update_all(Hash)` (AR accepts a hash; Grant currently only takes a raw SQL string — route through
  bound params / `Grant::Sanitization`)
- `insert_all!` / `upsert_all!` bang variants (raise on conflict)
- counter-cache class methods: `reset_counters`, `increment_counter`, `decrement_counter`
- `attr_readonly` (column-level) + record-level `readonly?` / `readonly!`

**Query interface:**
- `ids` (pluck PKs), `unscope(:where, :order, …)`, `readonly` relation, `explain` (EXPLAIN/ANALYZE)
- `joins(:association)` / `left_joins(:association)` — resolve table + FK from the association name
  (today requires an explicit ON string)
- `annotate` — inject the comment into the *executed* SQL, not just `.raw_sql` inspection
- chainable `find_each` / `find_in_batches` on `Query::Builder` (today class-method-only)

**Associations:**
- collection `<singular>_ids` reader/writer (`user.post_ids`, `user.post_ids = [...]`)
- association scopes (lambda/proc form: `has_many :posts, -> { where(...) }`)
- `dependent: :restrict_with_exception`
- `strict_loading` / `strict_loading!` (N+1 enforcement; pairs with the existing N1Detector)
- finish the eager-loading fallback for `has_many :through` / polymorphic / intermediate-base
  associations (the batch path now works; these still lazy-fall-back)

**Validations & callbacks:**
- `validates_with` (reusable validator classes / EachValidator base)
- `validate :method_name` (bare Symbol referencing an instance method that adds errors)
- `validates_comparison_of`, `validates_absence_of`, `invalid?` convenience
- `errors.details` (machine-readable type codes: `:blank`, `:too_short`, …)
- Proc/lambda `if:`/`unless:` conditions (today only Symbol form works)
- `around_validation`

**Infrastructure:**
- `store_accessor` (typed virtual accessors over a JSON/JSONB column)
- customizable optimistic-locking column (`self.locking_column = :my_col`)

### ⛔ SKIP (Ruby-ism / performance / type-system mismatch — with rationale)

- **`delegated_type`** — already removed from the plan in `REVISED_FEATURE_ANALYSIS.md`. Polymorphic
  associations + STI cover the real use cases; delegated_type's value in Rails is largely working
  around the lack of a usable type system, which Crystal gives us for free.
- **Dynamic attribute finders** (`find_by_<attr>` via `method_missing`) — pure Ruby metaprogramming.
  Grant's compile-time `find_by(attr: val)` is type-safe and faster; a `method_missing` emulation
  would defeat the type checker and add per-call overhead.
- **`ActiveSupport::Notifications` pub/sub instrumentation** — Grant intentionally uses Crystal's
  `Log` module with structured named loggers (`grant.sql`, `grant.model`, …). This is the idiomatic,
  typed, lower-overhead equivalent; we will not add a string-keyed runtime subscription bus.
- **`caller`/backtrace-based control flow** (as the prior STI draft used for type immutability) —
  capturing a stacktrace on a hot write path is a real perf footgun. STI uses an explicit mutability
  flag instead.
- **Global mutable `current_scope` / `default_scope` thread-local stacks** — AR's implicit
  scope-stack mutation is a classic source of action-at-a-distance bugs. Grant keeps scoping explicit
  on the `Query::Builder`; STI filtering is applied as a composable base scope, not global mutation.

### ⏸ DEFER (real, but beta-track or out-of-ORM)

- **Migration DSL** (`add_column`/`change_column`/`add_index`/`add_foreign_key`/`create_table`
  block) + **schema dump/load** — the single largest AR gap. Big enough to be its own effort; raw SQL
  via micrate is a workable v1 story. (Tracked: a proposed schema API already exists — see
  `proposed_schema_api.md` / `SCHEMA_API_*` docs in the amber repo root.)
- **Prepared-statement caching** — a real PG/MySQL perf win, but adapter-level work; schedule after
  parity.
- **Sharding** integration specs, `QueryRouter` hardcoded shard-key columns, `LookupResolver` DSL —
  the subsystem stays labeled experimental.
- **`DatabaseSelector` middleware** (auto route GET→replica, writes→primary) — belongs in Amber's
  pipeline, not Grant core. Provide the hook; ship the middleware in amber.
- **Fixtures / test helpers** (YAML/CSV fixture sets, `use_transactional_tests`) — useful, lower
  priority than parity correctness.
- **AES-256-GCM** — Crystal's OpenSSL bindings lack GCM tag operations; the current AES-256-CBC +
  HMAC-SHA256 (Encrypt-then-MAC) is a sound authenticated construction. Revisit if bindings gain GCM.
- **`QueryLogs` SQL-comment context tags** — minor; structured logs already carry the context.

## Single Table Inheritance — design

**Use case:** `Persona < Grant::Base` (STI root) with `AdminPersona < Persona`, `MemberPersona <
Persona`, … Each subclass is a real Crystal type, so permission logic can be methods on the subclass
and the compiler enforces which persona you hold. All rows live in one `personas` table with a `type`
discriminator.

**What Crystal gives us for free:** column metadata comes from
`@type.instance_vars.select(&.annotation(Grant::Column))`, and `@type.instance_vars` includes
*inherited* ivars — so `AdminPersona.fields` is automatically `Persona`'s columns + `AdminPersona`'s.
No separate field registry is needed; column inheritance just works.

**What we implement (in `src/grant/sti.cr`, opt-in via `include Grant::STI` on the root):**
1. **Root/subclass detection** — compile-time, via an `inherited` hook installed on the root.
   `sti_root` delegates up the superclass chain to the class that enabled STI; `sti_subclass? =
   self != sti_root`. (The prior draft stubbed this to always-root, which silently disabled all
   subclass filtering — fixed.)
2. **Type auto-set** — on create, set the inheritance column to `self.class.name` if nil.
   Default column `"type"`, customizable.
3. **`table_name` inheritance** — subclasses delegate `table_name` up to the root (Crystal annotations
   don't inherit, so this is explicit). `AdminPersona.table_name == Persona.table_name`.
4. **Query scoping** — subclass queries filter `WHERE type IN (self + registered descendants)` (AR
   semantics); root queries apply no filter. Descendant set computed at compile time from the STI
   registry. `unscoped` bypasses it. Applied as a composable base scope, not global state.
5. **Instantiation** — subclass queries already yield correct types (Grant runs `Subclass.from_rs`).
   Base-class queries (`Persona.all`) yield correctly-typed subclass instances; because Grant's
   `from_rs` reads sequentially by `SELECT Model.fields`, full base-polymorphic loads use an
   STI-aware name-keyed reader that consumes every column (no cursor desync) and dispatches via the
   registry. (Subclass queries are the must-pass; base-polymorphic fidelity level is documented in
   the implementation.)
6. **`becomes` / `becomes!`** — in-memory and DB-persisted type conversion; copies all attributes
   faithfully (incl. nil/false), preserves dirty state, flags, and PK; `becomes!` updates the type
   column via bound params.
7. **Immutable type column** — direct writes raise `Grant::STI::ImmutableTypeError`, gated by an
   explicit `@_sti_type_mutable` flag (no backtrace inspection). Change type only via `becomes!`.
8. **Serialization** — verified to compose with the abstract-base `JSON/YAML::Serializable` work
   (#41) across the multi-level hierarchy.

Public API mirrors the behavior in the prior design note (`/tmp/grant-fix6-sti-leftovers/
single_table_inheritance.md`), reimplemented clean on current `main`.

## Execution

1. **STI first** (`feature/single-table-inheritance`) — implemented + verified in isolation, then
   integrated into `main` and re-verified. STI is the most invasive change (model core, query
   scoping, serialization), so it lands before the parity batches to avoid churn on the critical path.
2. **Parity batches** (parallel worktree agents, on the STI-integrated `main`), grouped to minimize
   file overlap: persistence helpers; query interface; associations; validations & callbacks;
   `store_accessor` + optimistic-locking-column.
3. **Integrate → build → full SQLite spec (no new failures) → push → close issues.**

Status is tracked here and rolled into `GRANT_RELEASE_READINESS.md`.
