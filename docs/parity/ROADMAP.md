# Grant / ActiveRecord 8 parity roadmap

Audited on 2026-09-28 against commit `70ac8be` by one auditor per area, reading `src/` and `spec/` and running scratch probes on SQLite. The feature table and scores live in [PARITY.md](../PARITY.md), generated from [parity.json](parity.json). This file orders the open rows into implementation batches.

Rules for every batch:

- Acceptance specs pass on SQLite and PostgreSQL, and `crystal-regression-gate check` shows no file got worse.
- A row moves to `complete` only with a named spec that exercises the whole ActiveRecord behavior.
- Each batch keeps to its perf guardrail: no extra query per record, no hidden full hydration.
- Batches in the same wave touch different primary files, so they can run in parallel worktrees.

## Summary

Plan: 38 batches in 5 waves. Foundations (errors, relation core, dirty, transactions, roles, resolver fix, association loading) go first; later batches that share a file depend on the earlier owner (builder.cr: Q01, then A01 includes only, then Q02/Q03/Q04/P02; adapter/base.cr: G01, then C02/O01/M03).
Wave 1 (7 batches: G01 Q01 F01 T01 C01 S01 A01) takes parity from 150/228 (65.8%) to about 165 (72%) and removes the silent wrong-result hazards (preload ignoring scope, process-seeded shard hash, mutating relations).
Wave 2 (13 batches: validations plumbing, persistence guards/partial updates, create/find conveniences, bulk insert, tokens, where/select/batch families, introspection, notifications, pool/replicas, collection writers) reaches about 188 (82%), covering nearly all the high-value, low-effort rows.
Wave 3 (11 batches: locking, errors model, callbacks, enum/normalizes/store, secure password, autosave/counter caches, sharded routing, middleware/config, create-table DSL, encryption) reaches about 205 (90%); wave 4 (migration runner/DDL, JSON/array/UUID types, CTEs, delegated types, fixtures) reaches about 217 (95%).
Wave 5 (schema dump/tasks, composite keys end to end) reaches about 222 (97%); the last 6 applicable points are the 17 rows reclassified deferred, n.a., or partial. Percentages are estimates because many rows collapse into one applicable feature, and every batch must pass its specs on SQLite and PostgreSQL. Constraints: Amber V2 only, pin bcrypt by exact version and checksum, and run crystal-conventions review on all Crystal.

## Wave 1

### G01: Error taxonomy, adapter error translation, capability predicates, SQLite defaults (L)

- Depends on: nothing
- Files: `src/grant/errors.cr (new, Grant::ErrorBase tree)`, `src/grant/adapter/base.cr`, `src/grant/adapter/pg.cr`, `src/grant/adapter/mysql.cr`, `src/grant/adapter/sqlite.cr`, `src/grant/adapter/error_translator.cr (new)`, `src/grant/querying.cr (NotFound < ErrorBase only)`, `src/grant/transactions.cr (raise sites for RecordInvalid vs RecordNotSaved only)`, `docs/adapter_matrix.md`
- Acceptance specs: `spec/grant/errors/taxonomy_spec.cr (hierarchy, RecordInvalid carries record and full_messages, callback abort raises RecordNotSaved with a safe message)`, `spec/grant/errors/constraint_translation_spec.cr (unique, FK, not-null, too-long by SQLSTATE/errno on each adapter; deadlock and serialization mapped outside a transaction)`, `spec/grant/errors/statement_invalid_spec.cr (sql and redacted binds present)`, `spec/adapter/capabilities_spec.cr (each predicate per adapter, version-gated ones use cached database_version)`, `spec/adapter/sqlite_pragmas_spec.cr (defaults applied for file URLs, explicit URL params win, FK enforced)`, `spec/adapter/placeholder_rewrite_spec.cr (quoted literals, PG ::casts, ?? escape keep parameter numbering)`
- Perf guardrails: Translation runs only in the rescue path (zero cost on success). Match SQLSTATE/errno, never message regex. Cache database_version after first fetch. Replace repeated String#sub with a single-pass scanner for placeholders and benchmark it against current output. Cap or redact binds held on exceptions.
- Rows:
  - Exception taxonomy (RecordInvalid, RecordNotUnique, RecordNotFound, StatementInvalid hierarchy)
  - ActiveRecord::RecordInvalid raised by save!/create!/update!/validate!
  - Constraint-violation exception mapping (RecordNotUnique, InvalidForeignKey, NotNullViolation, ValueTooLong)
  - Statement failure wrapper carrying sql and binds (StatementInvalid)
  - Lock/timeout exception translation (Deadlocked, LockWaitTimeout, StatementTimeout, QueryCanceled, SerializationFailure)
  - Connection/pool error types (ConnectionTimeoutError, ConnectionNotEstablished, ConnectionFailed, NoDatabaseError)
  - Connection error hierarchy (ConnectionNotEstablished, ConnectionTimeoutError, ConnectionNotDefined, ReadOnlyError)
  - Adapter feature matrix (PG vs MySQL vs SQLite differences)
  - Adapter capability predicates (supports_partial_index?, supports_json?, supports_insert_returning?, supports_ddl_transactions?, ...)
  - Adapter identity and server info (adapter_name, database_version, current_database, raw_connection)
  - SQLite adapter defaults and PRAGMA configuration (foreign_keys, journal_mode, busy_timeout, synchronous)
  - Literal question-mark escaping in raw SQL fragments

### Q01: Relation core: immutability, lazy all, load memoization, terminal-method safety (L)

- Depends on: nothing
- Files: `src/grant/query/builder.cr (chain-method spawn, terminals, load state; do NOT touch includes/preload/eager_load, owned by A01)`, `src/grant/query/assembler/*.cr (implicit order only)`, `src/grant/querying.cr (Model.all)`, `src/grant/scoping.cr`, `src/grant/settings.cr (implicit_order flag)`
- Acceptance specs: `spec/grant/query/relation_immutability_spec.cr (base relation unchanged after chaining; first/any?/sole never mutate the receiver)`, `spec/grant/query/relation_load_spec.cr (empty? then each runs one query; reset and reload; size uses COUNT when unloaded)`, `spec/grant/query/lazy_all_spec.cr (Model.all.where(...) chains; legacy Model.all(clause, params) overload still returns Array)`, `spec/grant/query/ordinal_finders_spec.cr (take, last(n), second..forty_two and bang forms, composite pk ordering)`, `spec/grant/query/existence_predicates_spec.cr (many?, one?, none?, empty? issue LIMIT 1/2 SQL)`, `spec/grant/query/implicit_order_spec.cr (implicit_order_column drives first/last/find_each; default no longer forces ORDER BY DESC)`
- Perf guardrails: Use copy-on-write or lazy dup on first mutation, not deep dup per chain step; benchmark bench/relation_chain.cr must show no more than 1.2x allocations of the current mutating chain. No extra query per record. Behavior break (mutation gone, implicit DESC removed): run the full existing spec sweep and gate the implicit-order change behind Grant.settings.implicit_order for one release.
- Rows:
  - Relation immutability (each chain method returns a new relation)
  - all returns a lazy Relation (Model.all / relation.all)
  - Relation load / loaded? / reset / records memoization
  - Relation take / first / last result helpers
  - second / third / fourth / fifth / forty_two / second_to_last / third_to_last (and ! forms)
  - many? / one? / none? / empty? efficient existence-count predicates
  - only / except (relation clause filtering)
  - implicit ordering of unordered relations (implicit_order_column)
  - to_sql / cache_key / cache_version on relations

### F01: Dirty tracking family (M)

- Depends on: nothing
- Files: `src/grant/columns.cr`, `src/grant/base.cr (dirty section)`, `src/grant/dirty.cr (new, name-keyed generic methods)`
- Acceptance specs: `spec/grant/dirty/saved_changes_spec.cr (saved_change_to_<attr>? with from:/to:, tuple value, previously_was)`, `spec/grant/dirty/changes_to_save_spec.cr (changes_to_save, has_changes_to_save?, attributes_in_database)`, `spec/grant/dirty/dirty_control_spec.cr (restore_<attr>!, clear_changes_information, changes_applied, attribute_will_change!)`, `spec/grant/dirty/mutation_detection_spec.cr (opt-in detect_mutation: String <<, Array, serialized columns; scalar columns never snapshotted)`
- Perf guardrails: Prefer generic name-keyed methods plus one small macro over per-column duplicates; record compile time and binary size before/after on the largest spec model and cap growth at 10%. has_changes_to_save? must not allocate. Mutation detection is opt-in per model.
- Rows:
  - Dirty tracking (changed?, changes, attribute_was, per-attribute helpers)
  - Dirty tracking before save (changes_to_save / will_save_change_to_attribute?)
  - Saved-change per-attribute API (saved_change_to_<attr>?, saved_change_to_attribute, attribute_previously_was, <attr>_previously_changed?)
  - Dirty control (restore_<attr>!, clear_changes_information, changes_applied, attribute_will_change!, in-place mutation detection)

### T01: Transaction semantics and API (L)

- Depends on: nothing
- Files: `src/grant/transaction.cr`, `src/grant/transactions.cr (transaction/execute_transaction region only)`, `src/grant/commit_callbacks.cr`, `src/grant/connection_manager.cr (Grant.transaction facade)`
- Acceptance specs: `spec/grant/transaction/requires_new_savepoint_spec.cr (requires_new opens a SAVEPOINT rolled back with the outer transaction; independent: true keeps the old separate-connection mode)`, `spec/grant/transaction/joinable_spec.cr (plain nested block joins parent, Rollback swallowed without undo)`, `spec/grant/transaction/return_value_spec.cr (block value returned, typed T)`, `spec/grant/transaction/isolation_sql_spec.cr (BEGIN/SET TRANSACTION SQL recorded per adapter; nested isolation raises TransactionIsolationError)`, `spec/grant/transaction/handle_spec.cr (after_commit/after_rollback, open?, isolation, runs immediately when none open)`, `spec/grant/transaction/after_all_commit_spec.cr (runs after outermost commit, dropped on rollback, fiber-owned)`, `spec/grant/transaction/savepoint_failure_spec.cr (non-Rollback exception through savepoint, PG aborted state, callback pruning)`
- Perf guardrails: Savepoint names from a per-transaction counter, not Random::Secure. Nested joins save a SAVEPOINT round trip. State stays fiber-local. Do not hold two pool connections per request by default; independent: true documents the cost. Always resolve the writer connection when opening a transaction. Behavior break for requires_new: ship a migration note.
- Rows:
  - Transactions (basic, rollback, requires_new)
  - Savepoints / nested transactions
  - Transaction isolation levels
  - Transaction returns the block value
  - Nested transaction joinable / join-parent semantics
  - TransactionIsolationError for nested isolation mismatch
  - Current transaction object and per-transaction callbacks (Rails 7.2)
  - Model-independent / connection-level transaction
  - Manual transaction control (begin/commit/rollback, savepoint API)
  - after_all_transactions_commit

### C01: Connection context, roles, connects_to and abstract-class inheritance (M)

- Depends on: nothing
- Files: `src/grant/connection_context.cr`, `src/grant/connection_handling.cr`, `src/grant/base.cr (inherited macro, abstract_class)`, `src/grant/settings.cr (reading_role/writing_role)`
- Acceptance specs: `spec/grant/connection/connects_to_hash_spec.cr (database: {writing:, reading:}, shards: NamedTuple, eager verify at boot)`, `spec/grant/connection/reading_role_prevents_writes_spec.cr (create! in a reading block raises ReadOnlyError; :primary aliases :writing)`, `spec/grant/connection/connected_to_predicates_spec.cr (connected_to?, connected_to_many, connecting_to)`, `spec/grant/connection/prohibit_shard_swapping_spec.cr`, `spec/grant/connection/abstract_inheritance_spec.cr (later connects_to on parent propagates through lazy lookup)`, `spec/grant/connection/routing_two_files_spec.cr (two SQLite files prove the adapter actually chosen for reading vs writing)`
- Perf guardrails: Replace the global Mutex taken on every query (connection_context, current_role, current_shard) with a fiber-local slot; benchmark queries per second with 100 fibers and require no regression. Validate connection names at declaration, not at first query.
- Rows:
  - connects_to (database: / shards: DSL on models)
  - connected_to (role/shard/database block switching)
  - Reading/writing roles (role: :reading, role: :writing)
  - connected_to / multiple databases (AR 8 API)
  - connected_to? predicate
  - connected_to_many / connecting_to / connected_to?
  - connected_to_many / connecting_to
  - prohibit_shard_swapping
  - connected_to(role: :reading) implies prevent_writes
  - Abstract base class connection inheritance (primary_abstract_class / abstract connects_to)

### S01: Sharding resolver correctness (stable hash, lookup, time range) (S)

- Depends on: nothing
- Files: `src/grant/sharding/resolvers/hash_resolver.cr`, `src/grant/sharding/resolvers/time_range_resolver.cr`, `src/grant/sharding/resolvers/lookup_resolver.cr`, `src/grant/sharding/shard_manager.cr (all_shards uniq only)`
- Acceptance specs: `spec/grant/sharding/stable_hash_spec.cr (golden key-to-shard values, identical across three separate process runs)`, `spec/grant/sharding/shard_count_spec.cr (any count via macro table)`, `spec/grant/sharding/time_range_spec.cr (Time-typed keys, range pruning)`, `spec/grant/sharding/lookup_resolver_spec.cr (strategy: :lookup, default_shard not duplicated in all_shards)`
- Perf guardrails: Use FNV-1a or CRC32 over the key bytes; hash Int64 directly with no string join for single-column keys. Priority fix: current String#hash is process-seeded and misroutes persisted data after restart. Document that changing the hash needs a data migration for anyone already sharded.
- Rows:
  - Horizontal sharding — hash-based (shards_by :col, strategy: :hash)
  - Horizontal sharding — range-based (strategy: :range / :time_range)
  - LookupResolver for custom shard mappings

### A01: Association metadata, reflection and correct eager loading (L)

- Depends on: nothing
- Files: `src/grant/associations.cr`, `src/grant/association_registry.cr`, `src/grant/association_loader.cr`, `src/grant/associations/*.cr`, `src/grant/query/builder.cr (includes/preload/eager_load methods and the Includes alias only)`, `src/grant/reflection.cr (new)`
- Acceptance specs: `spec/grant/associations/preload_scope_spec.cr (scope lambda honored by includes; matches lazy result)`, `spec/grant/associations/has_one_through_preload_spec.cr`, `spec/grant/associations/polymorphic_preload_spec.cr (has_many/has_one as:, UUID and String keys, polymorphic_name STI base)`, `spec/grant/associations/nested_includes_spec.cr (recursive Includes alias, AssociationNotFoundError, includes upgraded to eager_load)`, `spec/grant/associations/reflection_spec.cr (reflect_on_association, reflect_on_all_associations, polymorphic registered)`, `spec/grant/associations/reset_reload_spec.cr (reload_<name>, reset_<name>, Base#reload clears cache)`, `spec/grant/associations/strict_loading_spec.cr (association option, by_default, n_plus_one_only, raise vs log; no responds_to? guards)`, `spec/grant/associations/inverse_detection_spec.cr`, `spec/grant/associations/preloader_spec.cr (skips already loaded, chunks IN lists)`
- Perf guardrails: One IN query per association level, chunk IN lists below adapter bind limits (SQLite 32766). Make the registry read-only after boot (no global Mutex on hot paths). Assert query counts with the query recorder: N owners preload costs constant queries. Ignoring scope on preload is a memory blowup, fix first.
- Rows:
  - Relationship annotation / association reflection
  - polymorphic associations (belongs_to, has_many :as, has_one :as)
  - eager loading — includes/preload/eager_load API
  - has_one :through
  - N+1 prevention / strict_loading
  - association caching / loaded? / reset
  - association extensions / association-level scopes
  - automatic inverse detection (without inverse_of)
  - association(:name) proxy object and association_cached?
  - manual Preloader on already-loaded records

## Wave 2

### V01: Validation macro plumbing, contexts and unified validates (L)

- Depends on: G01
- Files: `src/grant/validators.cr`, `src/grant/validation.cr`, `src/grant/callbacks.cr (shared if/unless/on prologue macro only)`, `src/grant/validators/blank.cr (new)`
- Acceptance specs: `spec/grant/validations/presence_blank_spec.cr (false and empty Hash are blank, allow_blank, on: arrays)`, `spec/grant/validations/validates_macro_spec.cr (NamedTuple expansion, custom validator lookup, compile error on unknown key)`, `spec/grant/validations/contexts_spec.cr (default context new=:create persisted=:update, on: :publish, save(context:), positional valid?(:custom))`, `spec/grant/validations/validate_bang_spec.cr`, `spec/grant/validations/strict_spec.cr`, `spec/grant/validations/multi_attribute_spec.cr (every validates_*_of accepts *fields)`, `spec/grant/validations/validates_each_block_spec.cr`, `spec/grant/validations/condition_arrays_spec.cr`
- Perf guardrails: Pure compile-time expansion; measure macro expansion time on a model with 30 validators and cap at 1.2x today. EachValidator reads through a generated typed reader, not record.to_h per attribute. Default-context change is a behavior change, gate it with a release note.
- Rows:
  - validates_presence_of
  - Unified validates macro (AR style: validates :field, presence: true, length: {min:2})
  - validates_with (custom validator class)
  - Validation contexts (on: :create, :update, :save)
  - Valid? with custom context (valid?(:custom))
  - strict: option on validators (raises instead of adding to errors)
  - validate! (raises RecordInvalid, accepts context)
  - save/save!/create with context: (validation_context accessor)
  - on: array of contexts and on: for before_validation/after_validation callbacks
  - Multi-attribute form for every validates_*_of macro
  - validates_each block form (validates_each :a, :b do |record, attr, value|)
  - Callback conditions as arrays and combined if:+unless: lists

### P01: Persistence guards, partial updates, identity and touch options (L)

- Depends on: F01, T01, G01
- Files: `src/grant/transactions.cr (save/update/destroy/touch region)`, `src/grant/base.cr (==, hash, dup)`, `src/grant/timestamps.cr`, `src/grant/readonly.cr`, `src/grant/counters.cr`
- Acceptance specs: `spec/grant/persistence/partial_updates_spec.cr (stale sibling column not overwritten, clean save issues no SQL and does not bump updated_at, serialized columns still written)`, `spec/grant/persistence/destroyed_guard_spec.cr`, `spec/grant/persistence/equality_spec.cr (PK identity, new records unequal, STI base class, Set and uniq)`, `spec/grant/persistence/dup_clone_spec.cr`, `spec/grant/persistence/readonly_attribute_spec.cr`, `spec/grant/persistence/touch_options_spec.cr (time:, touch: folded into one UPDATE)`, `spec/grant/persistence/update_counters_spec.cr (two columns, id array in one statement)`, `spec/grant/persistence/no_touching_spec.cr (fiber-local)`, `spec/grant/persistence/timestamps_spec.cr (record_timestamps toggle, *_on columns, one clock)`
- Perf guardrails: Partial updates cut write volume; ship together with mutation detection and keep partial_updates false as opt-out. Fold touch into the same UPDATE. Array update_counters is one WHERE pk IN statement. Audit AssociationLoader identity maps before defining ==. Fiber-local storage for no_touching, never a class variable.
- Rows:
  - Partial updates (UPDATE only changed columns; no-op save when clean)
  - Destroyed-record guard (frozen after destroy; save/update/touch raise)
  - Record equality and hashing (==, eql?, hash by class and primary key)
  - dup / clone semantics for records
  - Readonly attributes / readonly records (attr_readonly, readonly?)
  - update_column (singular)
  - touch: and time: options on touch, increment!, decrement!, toggle!, update_counters
  - update_counters (class-level atomic counter increment/decrement)
  - Automatic timestamps (created_at/updated_at, created_on/updated_on, record_timestamps)
  - no_touching / suppress blocks

### P02: Class-level and relation-level create/find conveniences (M)

- Depends on: Q01, G01
- Files: `src/grant/convenience/integrators.cr`, `src/grant/querying.cr`, `src/grant/query/builder.cr (finder and scope-attribute methods only)`, `src/grant/base.cr (initialize with block)`
- Acceptance specs: `spec/grant/convenience/create_block_array_spec.cr (block initializer, array form in one transaction)`, `spec/grant/convenience/find_or_create_by_spec.cr (bang, block, relation form inheriting where equality attributes)`, `spec/grant/convenience/create_or_find_by_spec.cr (uses savepoint, races resolved via RecordNotUnique on PG and SQLite)`, `spec/grant/convenience/find_by_ids_spec.cr (one IN query, input order, NotFound names missing ids)`, `spec/grant/convenience/relation_finders_spec.cr (find_by, find_by!, find_sole_by on relations and scopes, LIMIT 2 for sole)`, `spec/grant/convenience/create_with_spec.cr (builder dup copies defaults hash)`, `spec/grant/convenience/class_destroy_update_spec.cr`
- Perf guardrails: find(ids) is one IN query reordered in memory, never a loop. Relation defaults come from literal equality predicates only. create_or_find_by must use requires_new savepoint, not find-then-create. Array create wraps one transaction. Class-level array destroy is one SELECT IN then per-record destroy.
- Rows:
  - create / create! (class-level convenience)
  - find_or_create_by / find_or_initialize_by
  - Class-level find / find! by primary key
  - create_or_find_by (unique-constraint race-safe create)
  - create_with relation defaults
  - Class-level destroy(id/ids), delete(id/ids), update(id/ids, attrs)
  - Relation new / build / create / create! inheriting where-hash attributes
  - first_or_create / first_or_create! / first_or_initialize
  - new / build with initializer block
  - Relation-level finders (find with ids/array, find_by, find_by!, find_sole_by, find_or_create_by, find_or_initialize_by, create_or_find_by)
  - Relation build / create / create! / new with scope attributes, create_with, scope_attributes
  - find_by / find_by!
  - sole / find_sole_by

### P03: Bulk insert and upsert (M)

- Depends on: G01
- Files: `src/grant/bulk_operations.cr (insert_all/upsert_all, existing import path)`, `src/grant/adapter/base.cr, pg.cr, mysql.cr, sqlite.cr (insert clause builders only)`, `src/grant/sql/fragment.cr (new)`
- Acceptance specs: `spec/grant/bulk/insert_all_spec.cr (insert_all!, skip-duplicates default, homogeneous key check raises ArgumentError, converters applied)`, `spec/grant/bulk/insert_all_returning_spec.cr (PG RETURNING, SQLite 3.35+ RETURNING, MySQL raises clearly)`, `spec/grant/bulk/upsert_spec.cr (unique_by columns or index name, update_only, on_duplicate as Sql::Fragment, single-row upsert)`, `spec/grant/bulk/chunking_spec.cr (rows above bind cap split into chunks)`, `spec/grant/bulk/insert_single_spec.cr`
- Perf guardrails: One multi-row VALUES statement per chunk, chunk under bind cap (SQLite 32766, PG 65535). bench/insert_all.cr must show at least 10x over per-row save at 10,000 rows. No per-row round trips; on_duplicate accepts only Fragment types so it cannot come from user input. Rename note: the bang belongs to insert_all!, not upsert_all.
- Rows:
  - insert_all / insert_all! (AR8 bulk insert without callbacks)
  - upsert_all / upsert_all! (AR8 bulk upsert)
  - insert / insert! (single-row AR8)

### P04: Tokens and signed ids (S)

- Depends on: G01
- Files: `src/grant/secure_token.cr`, `src/grant/token_for.cr`, `src/grant/signed_id.cr`
- Acceptance specs: `spec/grant/tokens/secure_token_spec.cr (regenerate_<name> persists, regenerate_<name>!, assign_new_<name> in memory, on: :initialize)`, `spec/grant/tokens/token_for_spec.cr (find_by_token_for! raises Grant::InvalidToken, configurable secret via Grant::TokenFor.configure)`, `spec/grant/tokens/signed_id_spec.cr (find_signed!, default purpose table_name, expires_at:, integer id restore on PG, tampered and wrong secret)`
- Perf guardrails: Constant-time signature compare. Rescue only decode/verify errors, not every exception. Secret read once at app boundary, not per call. No extra query beyond the lookup.
- Rows:
  - Secure tokens (has_secure_token)
  - Token for (generates_token_for / find_by_token_for — AR8 data-invalidating tokens)
  - Signed IDs (signed_id / find_signed)

### Q02: Where-clause family and relation composition (L)

- Depends on: Q01, A01
- Files: `src/grant/query/builder.cr (where/merge/unscope region)`, `src/grant/query/where_chain.cr`, `src/grant/sanitization.cr`, `src/grant/query/assembler/where.cr`
- Acceptance specs: `spec/grant/query/where_range_spec.cr (beginless, endless, Time, Float, String ranges)`, `spec/grant/query/merge_spec.cr (same-column equality replaced, proc form)`, `spec/grant/query/unscope_where_column_spec.cr`, `spec/grant/query/rewhere_reorder_spec.cr (rewhere keeps other columns, reorder(nil), reverse_order on unordered)`, `spec/grant/query/where_associated_missing_spec.cr (EXISTS/NOT EXISTS, through, polymorphic)`, `spec/grant/query/where_nested_hash_spec.cr (joined table hash, association: record, arrays of records, polymorphic type column)`, `spec/grant/query/named_binds_spec.cr (skips ::casts and quoted strings)`, `spec/grant/query/where_not_or_and_spec.cr (NAND, NULL, ranges, relation or/and, ArgumentError on incompatible)`, `spec/grant/query/excluding_invert_spec.cr`
- Perf guardrails: Use EXISTS/NOT EXISTS for associated/missing to avoid duplicate parent rows and DISTINCT cost. Keep the identifier injection guard; validate join targets against the registry at build time. Index where clauses by column in a small Hash during merge. Bind ordering asserted for numbered PG params.
- Rows:
  - where (Range translates to >= AND <=)
  - merge (combining query relations)
  - unscope (remove specific query clauses)
  - reorder / reverse_order / rewhere / reselect / regroup
  - where.missing / where.has (association-based JOIN conditions)
  - where.associated
  - where with nested table hash / joined-table columns / record values
  - where with named bind placeholders
  - where.not with hash / multi-condition (NAND) and non-scalar values
  - or / and with a relation argument and structural-compatibility check
  - excluding / without (exclude given records)
  - invert_where
  - where(association: record) association-aware predicates

### Q03: Select, order, group, joins and aggregates (L)

- Depends on: Q01
- Files: `src/grant/query/builder.cr (select/order/group/joins region)`, `src/grant/query/aggregations.cr`, `src/grant/query/pluck.cr`, `src/grant/query/assembler/*.cr`, `src/grant/scale/index_hints.cr`
- Acceptance specs: `spec/grant/query/group_alias_spec.cr`, `spec/grant/query/joins_nested_raw_spec.cr (joins(posts: :comments), raw fragment, self-join alias, dedupe)`, `spec/grant/query/left_outer_joins_spec.cr`, `spec/grant/query/aggregations_typed_spec.cr (count(:col), distinct, sum typed Int64/BigDecimal, BIGINT above 2^53)`, `spec/grant/query/grouped_aggregates_spec.cr (Hash result, or ArgumentError, never a wrong scalar)`, `spec/grant/query/pluck_typed_spec.cr`, `spec/grant/query/select_order_expressions_spec.cr (NULLS FIRST/LAST, MySQL ISNULL emulation)`, `spec/grant/query/in_order_of_spec.cr`, `spec/grant/query/readonly_relation_spec.cr`, `spec/grant/query/optimizer_hints_spec.cr (terminator stripped)`
- Perf guardrails: Grouped aggregates run one GROUP BY query. Typed pluck reads directly with rs.read(T), no Columns::Type boxing. COUNT(DISTINCT col), not subquery over rows. Nested joins pair with distinct or EXISTS; resolve via registry at build time. Cap in_order_of list size or chunk.
- Rows:
  - group / group_by
  - joins (INNER JOIN)
  - left_outer_joins (LEFT JOIN)
  - aggregations (count / sum / avg / min / max; Model.count returns Int64)
  - calculate (generic aggregation method)
  - grouped aggregations returning Hash (group.sum/average/minimum/maximum)
  - pluck / pick typed results and SQL expressions
  - select with raw SQL expressions, aliases and block form
  - order with raw SQL / expressions / NULLS FIRST-LAST
  - in_order_of (order by explicit value list)
  - extract_associated
  - readonly relations (prevent persistence on fetched records)
  - optimizer hints (e.g. FORCE INDEX for MySQL)

### Q04: Batching and per-record relation writes (M)

- Depends on: Q01
- Files: `src/grant/query/batches.cr`, `src/grant/querying.cr (Model.find_each delegation)`, `src/grant/query/builder.cr (destroy_all/update only)`
- Acceptance specs: `spec/grant/query/find_each_spec.cr (cursor:, start/finish, order, error_on_ignore, iterator form, Model.find_each delegates to builder)`, `spec/grant/query/in_batches_relation_spec.cr (yields a relation; batch.update_all and delete_all run in SQL; load: true memoizes)`, `spec/grant/query/destroy_all_callbacks_spec.cr (before/after_destroy order, dependent: children, restrict aborts)`, `spec/grant/query/relation_update_spec.cr`
- Perf guardrails: Keyset cursor for every path, never OFFSET (fixes O(n^2) in Model.find_each). Non-loading in_batches plucks only PKs per batch. destroy_all iterates in batches, one transaction per batch. Iterator form must not preload all batches.
- Rows:
  - find_each (batch iteration)
  - find_in_batches
  - in_batches (relation-based cursor batching)
  - Relation destroy_all (callback-aware relation deletion)
  - Relation update / update! (per-record with callbacks)

### M01: Schema introspection (L)

- Depends on: G01
- Files: `src/grant/schema/introspection.cr (new)`, `src/grant/schema/column_info.cr (new)`, `src/grant/adapter/pg.cr`, `src/grant/adapter/mysql.cr`, `src/grant/adapter/sqlite.cr (catalog queries only)`
- Acceptance specs: `spec/grant/schema/introspection_spec.cr (tables, columns, indexes, primary_key, foreign_keys on SQLite PRAGMA and PG catalogs)`, `spec/grant/schema/schema_cache_spec.cr (cache per connection, reset on DDL, dump and load file)`, `spec/grant/schema/verify_model_spec.cr (declared vs actual drift check)`
- Perf guardrails: Batch catalog queries: one for all columns, one for all indexes. Cache per connection/table with explicit reset. Never introspect per request; load dumped cache at boot.
- Rows:
  - Introspection: table_exists?, column_exists?, columns, tables, primary_key, indexes, foreign_keys
  - Schema cache / schema introspection API

### F02: Attribute introspection, reflection, cache keys and safe inspect (M)

- Depends on: F01, Q01
- Files: `src/grant/base.cr (introspection and inspect)`, `src/grant/columns.cr (ColumnInfo, alias table)`, `src/grant/attributes.cr (new)`, `src/grant/integration.cr (new, cache keys)`, `src/grant/settings.cr (filter_attributes)`
- Acceptance specs: `spec/grant/attributes/introspection_spec.cr`, `spec/grant/attributes/assign_attributes_spec.cr`, `spec/grant/attributes/before_type_cast_spec.cr (captured only when converted value differs, never on from_rs)`, `spec/grant/attributes/alias_attribute_spec.cr (also resolved in where(**args))`, `spec/grant/attributes/reflection_spec.cr`, `spec/grant/attributes/cache_key_spec.cr (in-memory updated_at, collection_cache_key one aggregate query)`, `spec/grant/attributes/inspect_filter_spec.cr (encrypted columns and filtered names show [FILTERED])`
- Perf guardrails: cache_version reads memory only. Raw-input capture never on load path (would double memory). collection_cache_key is one COUNT/MAX query. ColumnInfo array is a compile-time constant. attributes allocates, document typed getters for hot paths.
- Rows:
  - Attribute introspection (attributes, attribute_names, has_attribute?, attribute_present?, slice, values_at, [] / []=, column_names)
  - assign_attributes / attributes= (mass assignment by name)
  - attribute_before_type_cast
  - alias_attribute
  - Model reflection (columns_hash, type_for_attribute, attribute_types, primary_key, reset_column_information)
  - to_param / to_key / cache_key / cache_version / cache_key_with_version
  - inspect with filter_attributes (redacted, readable inspect)
  - Integration cache keys and to_param (cache_key, cache_version, collection_cache_key)

### O01: Instrumentation notifications and query test helpers (M)

- Depends on: G01, T01
- Files: `src/grant/notifications.cr (new, typed event structs)`, `src/grant/log.cr`, `src/grant/spec_support/*.cr (new)`, `src/grant/adapter/base.cr (open hook, truncate helpers)`
- Acceptance specs: `spec/grant/notifications/subscribe_spec.cr (sql payload with binds, duration, cached, async)`, `spec/grant/notifications/transaction_events_spec.cr (commit/rollback outcome)`, `spec/grant/spec_support/assert_queries_spec.cr (per-fiber counting, failure prints captured SQL)`, `spec/grant/spec_support/transactional_wrapper_spec.cr (joinable: false wrapper, rollback across registered connections)`, `spec/adapter/test_helpers_spec.cr (TRUNCATE RESTART IDENTITY on PG, sequence reset)`
- Perf guardrails: Zero allocation when no subscriber (check a subscriber count, dispatch synchronously). Recording only inside the block and per fiber. Transactional wrapper must be cheaper than DELETE-per-table; benchmark suite time.
- Rows:
  - Instrumentation notifications (sql / transaction / instantiation / strict_loading_violation events with payload)
  - Transaction instrumentation events (transaction.active_record, start_transaction.active_record)
  - Test assertions for queries (assert_queries_count, assert_no_queries, assert_queries_match)
  - Transactional test wrapper (use_transactional_tests equivalent)
  - Test-support helpers (disable_referential_integrity, truncate_tables, reset_pk_sequence!)

### C02: Pool, health, replicas, failover and reconnection (XL)

- Depends on: C01, G01
- Files: `src/grant/connection_registry.cr`, `src/grant/health_monitor.cr`, `src/grant/load_balancer.cr`, `src/grant/connection_spec.cr`, `src/grant/adapter/base.cr (open_pool_connection, disconnect!)`
- Acceptance specs: `spec/grant/connection/pool_exhaustion_spec.cr (pool_size 1 plus two fibers raises ConnectionTimeoutError; :memory: forced to pool 1)`, `spec/grant/connection/pool_stats_spec.cr (stat backed by DB::Database pool stats, idle reuse via max_idle_pool_size)`, `spec/grant/connection/health_recovery_spec.cr (MockAdapter fails then recovers; buffered probe channel, no leaked fiber)`, `spec/grant/connection/replica_routing_spec.cr (two SQLite files prove reads hit the reader, writes stay on the writer; idempotent replica registration; least-connections release)`, `spec/grant/connection/failover_spec.cr (reading falls back to writer for every role)`, `spec/grant/connection/disconnect_spec.cr (replace and clear_all close the old pool)`, `spec/grant/connection/reconnect_spec.cr (reads retried once outside a transaction, writes never)`, `spec/grant/connection/prepared_statements_spec.cr (prepared_statements: false, statement_limit)`, `spec/grant/connection/with_connection_spec.cr`
- Perf guardrails: Default max_idle_pool_size to pool_size for server adapters (removes connection churn). Registry keeps replica list immutable and swaps on change; least-connections pick must not allocate per call. Stat must not take the registry lock. Close pools outside the registry lock. Retry only idempotent reads or pre-send connect failures with capped exponential backoff. Reaper sweeps on a slow timer without holding pool mutex during I/O. Adapter session variables are deferred.
- Rows:
  - Connection pooling (pool_size, checkout_timeout, etc.)
  - Connection pooling
  - Connection health monitoring
  - Health monitor / reconnection
  - Read replica load balancing (multiple replicas, strategies)
  - Replica load balancing (read/write splitting)
  - Connection failover (unhealthy primary/replica fallback)
  - Prepared statements / statement caching
  - Reconnection / connection lost handling
  - Connection-level retries (retry_attempts, retry_delay)
  - Explicit connection API (establish_connection / remove_connection / connected? / connection_pool / retrieve_connection_pool)
  - Model.establish_connection / remove_connection / connected? / connection_pool
  - with_connection / lease_connection / release_connection
  - Checked-out connection block (with_connection / lease_connection / permanent lease)
  - Connection pool introspection and lifecycle (stat, size, idle/busy, reaping, max_age, min_connections)
  - Pool statistics (connection_pool.stat)
  - Pool disconnect and teardown (disconnect!, clear_all_connections!, remove_connection)
  - Pool idle/reaper settings (idle_timeout, reaping_frequency, min_connections, keepalive)
  - Connection liveness API (active?, verify!, reconnect!, connected?)

### A02: Collection writers, through writers and HABTM (L)

- Depends on: A01, T01
- Files: `src/grant/association_collection.cr`, `src/grant/associations.cr (has_many, through, habtm macros)`, `src/grant/associations/through.cr (new)`, `src/grant/associations/habtm.cr (new)`
- Acceptance specs: `spec/grant/associations/through_writers_spec.cr (<<, delete, build, create insert join rows in one transaction, <tag>_ids=)`, `spec/grant/associations/habtm_spec.cr (hidden join model, table name in lexical order, options, both sides)`, `spec/grant/associations/collection_ids_spec.cr (pluck reader, writer validates ids in one IN, raises RecordNotFound, diff applies set-based)`, `spec/grant/associations/collection_build_create_spec.cr (sets inverse, block form, Hash and Array, unsaved owner raises RecordNotSaved)`, `spec/grant/associations/collection_delete_strategy_spec.cr (nullify, delete_all, destroy per dependent)`, `spec/grant/associations/association_callbacks_spec.cr (symbol and proc, before_ abort)`
- Perf guardrails: Join inserts are one INSERT ... VALUES in a transaction. ids= writer is two set-based statements, not N+1. Nullify strategy is one UPDATE. Callbacks add per-record cost only when declared. Through disable_joins and cross-database association loading are deferred.
- Rows:
  - has_many :through
  - HABTM (has_and_belongs_to_many) equivalent
  - collection singular IDs accessor (post_ids / user_ids=)
  - AssociationCollection build / create / create!
  - AssociationCollection destroy_all / delete_all
  - association callbacks (before_add / after_add / before_remove / after_remove)

## Wave 3

### L01: Pessimistic and optimistic locking (M)

- Depends on: G01, T01, P01
- Files: `src/grant/locking/pessimistic.cr`, `src/grant/locking/optimistic.cr`, `src/grant/query/builder.cr (lock method only)`
- Acceptance specs: `spec/grant/locking/with_lock_spec.cr (generic return T, nil block value allowed, requires_new, isolation)`, `spec/grant/locking/unsaved_changes_lock_spec.cr (UnsavedChangesLockError, force: true)`, `spec/grant/locking/lock_wait_spec.cr (PG two-connection NOWAIT and SKIP LOCKED; SQLite asserts SQL and no-op)`, `spec/grant/locking/optimistic_destroy_touch_spec.cr (stale destroy raises via affected rows)`, `spec/grant/locking/locking_column_spec.cr (locking_column :revision, lock_optimistically toggle)`, `spec/grant/locking/lock_clause_spec.cr (literal-only String, unlock)`
- Perf guardrails: Version predicate rides the PK UPDATE/DELETE, no pre-read. with_lock is one SELECT FOR UPDATE round trip and requires an open transaction. Custom lock strings accepted only as constants.
- Rows:
  - Pessimistic locking (FOR UPDATE, FOR SHARE, SKIP LOCKED, NOWAIT)
  - Optimistic locking (lock_version)
  - Configurable optimistic-locking column (locking_column)
  - Optimistic locking on destroy/touch, locking_enabled?, and stale-record refresh
  - Pessimistic lock! raises on unsaved changes
  - Row-lock unsaved-changes guard (lock! / with_lock on a dirty record)
  - Relation#lock with a custom SQL clause or false

### V02: Errors object model, messages and remaining validators (L)

- Depends on: V01
- Files: `src/grant/errors_collection.cr`, `src/grant/error.cr`, `src/grant/validators/uniqueness.cr`, `src/grant/validators/numericality.cr`, `src/grant/i18n.cr (new)`, `src/grant/validator_info.cr (new)`
- Acceptance specs: `spec/grant/validations/uniqueness_options_spec.cr (conditions: typed builder proc, quoted identifiers, allow_blank, scope association)`, `spec/grant/validations/numericality_constraints_spec.cr (one error per constraint, Symbol and Proc operands, equal_to, other_than, in:)`, `spec/grant/validations/errors_api_spec.cr (of_type by type, where with type/options, to_hash(full_messages:), AR-shaped as_json)`, `spec/grant/validations/errors_details_options_spec.cr`, `spec/grant/validations/message_generation_spec.cr (errors.add(:name, :too_short, count: 3), Proc messages, lazy formatting)`, `spec/grant/validations/error_object_spec.cr (humanized full_message, match?)`, `spec/grant/validations/i18n_spec.cr (human_attribute_name, pluggable translator)`, `spec/grant/validations/validators_on_spec.cr`
- Perf guardrails: Format messages lazily so bulk-import failures do not format strings per row. Uniqueness stays a single SELECT EXISTS backed by a unique index; document functional index or citext for case-insensitive. Cache translation lookups per (class, attribute, type). Index errors by attribute lazily.
- Rows:
  - validates_uniqueness_of (with scope, case_sensitive, allow_nil, allow_blank)
  - validates_numericality_of
  - Errors API (add, [], full_messages, where, of_type, include?, attribute_names, group_by_attribute, merge!, to_hash, to_json)
  - errors.details (AR8 structured type+options per error)
  - Error message generation from type symbol, message: as Symbol/Proc, errors.add(attr, :type, **options)
  - Errors extras (delete, added?, of_type by type, messages_for, full_message, import/copy!, objects, uniq!, count by attribute)
  - ActiveModel::Error object API (attribute, type, options, raw_type, message, detail, full_message, strict_match?)
  - Localized error messages and human_attribute_name (I18n)
  - Human-readable names and i18n (human_attribute_name, model_name)
  - Validator reflection (validators, validators_on, validate callbacks introspection)

### CB01: Callback additions (M)

- Depends on: V01, T01
- Files: `src/grant/callbacks.cr`, `src/grant/commit_callbacks.cr`
- Acceptance specs: `spec/grant/callbacks/run_callbacks_spec.cr (block between before and after chains, halting, symbol dispatch)`, `spec/grant/callbacks/after_save_commit_spec.cr (fires once with after_create_commit also registered)`, `spec/grant/callbacks/commit_on_option_spec.cr (on: arrays, dedupe of repeated saves in one transaction)`, `spec/grant/callbacks/prepend_spec.cr`
- Perf guardrails: Compile-time expansion only, no runtime chain mutation. Runtime symbol dispatch is a case statement with no allocation. Commit dispatch keeps a static array.
- Rows:
  - run_callbacks (manual callback execution)
  - after_save_commit
  - after_commit/after_rollback on: option (on: [:create, :update, :destroy])
  - Callback prepend: true option

### Q05: Async queries, query cache and scoping (M)

- Depends on: Q01, C02, O01
- Files: `src/grant/query/async.cr`, `src/grant/query_cache.cr (new)`, `src/grant/scoping.cr`, `src/grant/middleware/query_cache.cr (new, Amber V2 pipe)`
- Acceptance specs: `spec/grant/query/async_spec.cr (async_ids, async_pick, async_exists?, bounded by Grant.settings.async_pool_size)`, `spec/grant/query/query_cache_spec.cr (hit, cleared by any write or DDL including another connection, uncached block, bounded size)`, `spec/grant/query/scoping_block_spec.cr (fiber-local, restored on exception)`
- Perf guardrails: Fiber-local cache with no lock contention, keyed on SQL plus binds per connection, bounded size. Async concurrency capped to pool size and reuses the read connection. Amber V2 only, no 1.x pipe.
- Rows:
  - async queries (fiber/channel-based)
  - query cache (within-request result memoization)
  - scoping { } block (Model.scoping / Relation#scoping)

### P05: Attribute macros: enum, normalizes, store_accessor (L)

- Depends on: F01, F02, Q02, V01
- Files: `src/grant/enum_attribute.cr`, `src/grant/normalizes.cr`, `src/grant/store_accessor.cr (new)`, `src/grant/serialized_column.cr`
- Acceptance specs: `spec/grant/attributes/enum_options_spec.cr (prefix/suffix, not_<member> scopes, scopes: false, validate:, published! persists via update!, assign_published in memory, where(status: "published"), values mapping)`, `spec/grant/attributes/normalizes_spec.cr (multiple attributes, with: proc, apply_to_nil:, applied in setter, skipped on load, normalize_value_for)`, `spec/grant/attributes/normalized_query_spec.cr (find_by(email: " A@B ") matches normalized value)`, `spec/grant/attributes/store_accessor_spec.cr (typed keys, dirty tracking, no whole-column re-deserialize)`
- Perf guardrails: Compile-time set of normalized column names so unaffected queries pay nothing; hydration uses a raw-assign path that skips normalizers. Store reads reuse the serialized_column object cache. Persisting bang setters add one round trip, document it. Duplicate normalization rows are one implementation.
- Rows:
  - Enum attributes (enum_attribute macro)
  - Normalization (normalizes macro, before_validation hook)
  - Normalization (normalizes macro, runs before validation)
  - Model.normalize_value_for and normalization on query conditions
  - Store accessors (store_accessor for JSON column sub-keys)

### P06: has_secure_password (M)

- Depends on: V01, F02
- Files: `src/grant/secure_password.cr (new, optional require grant/secure_password)`, `shard.yml (dev/optional dependency pin only)`, `shard.lock (checksum)`
- Acceptance specs: `spec/grant/secure_password_spec.cr (password=, confirmation, presence, length <= 72, authenticate, authenticate_password, reset_token)`
- Perf guardrails: bcrypt is deliberately CPU-heavy: run outside DB transactions and connection-holding blocks; constant-time compare. Pin the bcrypt shard to an exact version with a lockfile checksum and pass dep-pin-audit, per the standing rule. Keep it an optional require so the core does not depend on it.
- Rows:
  - has_secure_password (ActiveModel::SecurePassword)

### A03: Autosave, nested attributes, dependents, counter caches and touch (XL)

- Depends on: A02, V01, P01, T01
- Files: `src/grant/associations.cr (belongs_to/has_one macros)`, `src/grant/autosave.cr`, `src/grant/nested_attributes.cr`, `src/grant/counter_cache.cr`, `src/grant/dependent.cr (new)`
- Acceptance specs: `spec/grant/associations/autosave_validate_spec.cr (invalid child makes owner.save return false, keys like posts.title, index_errors)`, `spec/grant/associations/mark_for_destruction_spec.cr`, `spec/grant/associations/nested_attributes_spec.cr (belongs_to branch, proc reject_if, RecordNotFound for foreign ids, one IN query for ids)`, `spec/grant/associations/dependent_options_spec.cr (compile error on unknown value, restrict_with_error adds error, destroy_async enqueuer, destroyed_by_association)`, `spec/grant/associations/touch_spec.cr (old parent touched on FK change, on destroy, touch_all by key, no-op when nothing changed)`, `spec/grant/associations/counter_cache_spec.cr (reset_counters correlated subquery, increment_counter/decrement_counter, pluralization categories_count, active: false, size reads cached column, collection delete decrements)`, `spec/grant/associations/belongs_to_extras_spec.cr (default:, association_changed?)`
- Perf guardrails: Only validate and save new or changed children. reset_counters is one correlated UPDATE; counter changes are atomic col = col + n SQL. Touch by key without loading the parent. Nested ids loaded in one IN query. destroy_async batches by owner and is idempotent.
- Rows:
  - autosave
  - validate: option and validation of new associated records on owner save
  - mark_for_destruction / marked_for_destruction?
  - destroyed_by_association
  - index_errors option for association errors
  - nested attributes (accepts_nested_attributes_for)
  - dependent: :delete / :delete_all
  - dependent: :restrict / :restrict_with_exception / :restrict_with_error
  - belongs_to dependent (:destroy / :delete / :destroy_async)
  - touch option on belongs_to
  - counter_cache
  - Counter caches (counter_cache: on belongs_to)
  - belongs_to default: option
  - belongs_to association_changed? / association_previously_changed?

### S02: Sharded query routing, aggregates and instance routing (L)

- Depends on: C01, S01, Q03, Q04, P01
- Files: `src/grant/sharding/sharded_query_builder.cr`, `src/grant/sharding/model.cr`, `src/grant/sharding/scatter_gather.cr`, `src/grant/sharding/shard_manager.cr`, `spec/support/real_sqlite_shards.cr (new)`
- Acceptance specs: `spec/grant/sharding/real_shard_routing_spec.cr (two SQLite files: ordered limit/offset global, merged rows)`, `spec/grant/sharding/scatter_aggregates_spec.cr (sum of sums, min of mins, average from sum and count)`, `spec/grant/sharding/find_each_shards_spec.cr (no duplicates, keyset per shard)`, `spec/grant/sharding/instance_routing_spec.cr (save/update/destroy outside with_shard, record.current_shard set on load)`, `spec/grant/sharding/shard_key_immutability_spec.cr`, `spec/grant/sharding/cross_shard_join_spec.cr`, `spec/grant/sharding/shard_reader_spec.cr (connected_to(role: :reading, shard: :one) hits the shard reader)`
- Perf guardrails: Send limit+offset with no OFFSET to each shard, merge-sort, then slice; recommend keyset pagination for deep pages. Average merges (sum, count), never average-of-averages. Cache current_shard on the instance and invalidate on key change. Sharded builder derives DbType from the shard adapter.
- Rows:
  - ShardedQueryBuilder + Query routing (single/scatter-gather/multi-shard)
  - Sharding integration specs (cross-strategy, error handling, transactions, concurrent)
  - Shard key immutability enforcement
  - Cross-shard join detection
  - Per-shard connection with read replica (shards: {shard_one: {writing:, reading:}})
  - find_each across all shards
  - Automatic shard routing for instance save/update/destroy on shards_by models
  - Scatter-gather aggregates (sum/average/minimum/maximum/calculate) on sharded models
  - Scatter-gather global LIMIT/OFFSET and ordering
  - Multiple databases / connected_to with shard:

### C03: Request middleware and declarative multi-database configuration (M)

- Depends on: C01, G01, C02
- Files: `src/grant/middleware/database_selector.cr (new, Amber V2 HTTP::Handler)`, `src/grant/middleware/shard_selector.cr (new)`, `src/grant/database_configurations.cr (new)`, `src/grant/connection_registry.cr (URL overload only)`, `spec/integration/mixed_adapter_spec.cr (new)`
- Acceptance specs: `spec/grant/middleware/database_selector_spec.cr (GET/HEAD reading, writes to writing, 2s delay after write)`, `spec/grant/middleware/shard_selector_spec.cr (resolver, lock via prohibit_shard_swapping)`, `spec/grant/config/database_configurations_spec.cr (env override, per-name *_DATABASE_URL, configs_for, replica marker)`, `spec/grant/config/url_scheme_spec.cr (adapter chosen from postgres:// mysql:// sqlite3:)`, `spec/integration/mixed_adapter_spec.cr (SQLite plus PG in one process, independent transactions, no placeholder leakage)`
- Perf guardrails: Write timestamp stored only after a write request; no session serialization on read-only requests. Adapter registry populated by requires so unused adapters are not compiled in. Targets Amber V2 only.
- Rows:
  - Automatic role-switching middleware (DatabaseSelector equivalent)
  - ShardSelector middleware (shard_resolver, lock)
  - Multi-database configuration (database.yml configurations, replica: true, DATABASE_URL)
  - Database URL / DATABASE_URL configuration and adapter inference from URL scheme
  - Database configurations API (db_config, configs_for, per-environment named configs)
  - Single codebase with SQLite (local) + PostgreSQL (server)

### M02a: Create-table DSL, type mapping and column options (L)

- Depends on: G01, M01
- Files: `src/grant/migrator.cr`, `src/grant/schema/table_definition.cr (new)`, `src/grant/schema/schema_statements.cr (new)`, `src/grant/adapter/schema.cr (TYPES table)`
- Acceptance specs: `spec/grant/schema/create_table_spec.cr (free-form create_table, if_not_exists, temporary, id: false, force)`, `spec/grant/schema/type_mapping_spec.cr (Int8/16, BigDecimal precision/scale, Bytes, Date, JSON, text vs string limit) asserting SQL on SQLite and PG and a real create/insert/read round trip`, `spec/grant/schema/column_defaults_spec.cr (default_sql expression, change_column_default)`, `spec/grant/schema/composite_pk_create_spec.cr`, `spec/grant/schema/timestamps_ddl_spec.cr (precision:, null: false)`
- Perf guardrails: DDL only. Note in docs that PG 11+ constant default is metadata-only and MySQL may rewrite. Assert emitted SQL for every adapter in a recording mock, not only the active one.
- Rows:
  - Grant::Migrator — compile-time CREATE TABLE DSL
  - Schema type mapping per adapter
  - Column defaults in CREATE TABLE
  - Column options: null, limit, precision, scale, comment, collation, array
  - add_timestamps / remove_timestamps / t.timestamps
  - Composite primary keys and primary key options in table creation

### E01: Encryption completeness (L)

- Depends on: F02, Q02, Q04, O01
- Files: `src/grant/encryption/*.cr`, `src/grant/encryption/migration_helpers.cr`, `src/grant/encrypted_attribute.cr`
- Acceptance specs: `spec/grant/encryption/previous_schemes_spec.cr (read with old, write with new, newest tried first)`, `spec/grant/encryption/options_spec.cr (ignore_case with original_<attr>, downcase, compress threshold)`, `spec/grant/encryption/unencrypted_fallback_spec.cr (version byte check, generated getter honors flag)`, `spec/grant/encryption/transparent_column_spec.cr (same-name column, Int/Time/JSON, where(email:) rewritten for deterministic attributes, existing <attr>_encrypted data still readable)`, `spec/grant/encryption/context_spec.cr (fiber-local without_encryption and with_context)`, `spec/grant/encryption/filter_spec.cr (SQL log binds redacted)`, `spec/grant/encryption/migration_helpers_spec.cr (encrypt_column, decrypt_column, generate_migration; keyset batching)`
- Perf guardrails: Encryption context fiber-local, never a class variable. Deterministic lookup computes one ciphertext per call. Predicate rewriting happens at builder time, never post-filtering in Crystal. Keyset batching plus bulk update in helpers. Precompute filtered column name set per model. Do not change the existing ciphertext byte layout in this batch.
- Rows:
  - Encrypted attributes (encrypts macro)
  - Encryption: previous: schemes for key/scheme migration
  - Encryption: ignore_case: and downcase: options
  - Encryption: compress: option
  - Encryption: support_unencrypted_data and per-attribute plaintext fallback
  - Encryption: transparent same-name column and non-String attribute types
  - Encryption context and record helpers (encrypted_attribute?, ciphertext_for, encrypt, decrypt, without_encryption, protecting_encrypted_data)
  - Encryption: filter_parameters and inspect masking of encrypted attributes
  - Encryption migration helpers (data migration for encrypted columns)

## Wave 4

### M02b: Alter, constraints, indexes, references (XL)

- Depends on: M02a
- Files: `src/grant/schema/schema_statements.cr`, `src/grant/schema/alter_table.cr (new)`, `src/grant/schema/index_definition.cr (new)`, `src/grant/schema/table_rebuild.cr (new, SQLite)`, `src/grant/adapter/pg.cr, mysql.cr, sqlite.cr (DDL emitters)`
- Acceptance specs: `spec/grant/schema/indexes_spec.cr (unique, partial where, using, concurrently, if_not_exists, introspection round trip)`, `spec/grant/schema/foreign_keys_spec.cr (on_delete, validate: false then validate, SQLite table rebuild)`, `spec/grant/schema/check_unique_constraints_spec.cr`, `spec/grant/schema/alter_table_spec.cr (add/remove/change column, change_column_null with default, bulk: true)`, `spec/grant/schema/rename_spec.cr (table renames PG sequence and index; column renames default-named indexes)`, `spec/grant/schema/references_join_table_spec.cr`, `spec/grant/schema/comments_spec.cr (PG and MySQL emit, SQLite skipped with reason)`, `spec/grant/schema/pg_enum_extension_spec.cr (PG only)`
- Perf guardrails: Concurrent index builds cannot run in a transaction; expose disable_ddl_transaction. Provide NOT VALID then validate for FK and check on PG. Combine bulk ALTERs into one statement. Document lock and table-rewrite costs. Views, generated columns and exotic PG types are deferred.
- Rows:
  - Indexes — creation in migrations
  - Foreign keys — DDL support
  - Check constraints
  - Unique constraints and exclusion constraints
  - alter_table / change_column / add_column at runtime via Grant DSL
  - rename_table DSL
  - rename_column / rename_index DSL
  - create_join_table / drop_join_table
  - references / belongs_to columns in migrations (add_reference, remove_reference, polymorphic)
  - Table and column comments
  - PostgreSQL enum types, extensions, and custom column types (create_enum, enable_extension, hstore, citext, jsonb, inet, ltree, money)

### M03: Migration runner, tracking, locks and multi-database migration (XL)

- Depends on: M02a, M02b, T01, C01, C02, C03, S01
- Files: `src/grant/schema/migration.cr (new)`, `src/grant/schema/migration_context.cr (new)`, `src/grant/schema/command_recorder.cr (new)`, `src/grant/schema/schema_migration.cr (new)`, `src/grant/schema/internal_metadata.cr (new)`, `src/grant/advisory_lock.cr (new)`, `src/grant/adapter/base.cr (advisory lock methods)`
- Acceptance specs: `spec/grant/schema/migration_context_spec.cr (migrate to version, rollback, redo, up, down, forward, status)`, `spec/grant/schema/reversible_spec.cr (inverse recorded, IrreversibleMigration)`, `spec/grant/schema/micrate_sql_files_spec.cr (-- +micrate Up/Down parsed and tracking table compatible with existing Micrate installs)`, `spec/grant/schema/ddl_transaction_spec.cr`, `spec/grant/schema/pending_check_spec.cr`, `spec/grant/schema/environment_protection_spec.cr`, `spec/grant/schema/advisory_lock_spec.cr (PG two-connection serialization, released on connection death; SQLite BEGIN EXCLUSIVE)`, `spec/grant/schema/multi_db_migration_spec.cr (per-connection versions, per-shard skew report)`
- Perf guardrails: One SELECT of all versions, no per-file query. Advisory lock held on the same connection that runs DDL and released in ensure. Bounded parallelism across shards with per-target lock. Existing Micrate users must keep working; this API layers on top.
- Rows:
  - Micrate integration — versioned SQL migration files (Up/Down)
  - Reversible migrations
  - Migration versioning / schema_migrations table tracking
  - Migration class: up/down/change with versioned class ([8.0] compat)
  - MigrationContext operations: migrate to version, rollback(step), redo, up/down(version), forward, status
  - DDL transactions and disable_ddl_transaction!
  - Migration output and helpers: say, say_with_time, announce, suppress_messages
  - Pending-migration check and maintain_test_schema
  - ar_internal_metadata environment protection
  - execute (raw DDL inside a migration) and schema-qualified table names
  - Multi-database migrations (per-connection migrations_paths, db:migrate:primary, connection-specific tasks)
  - Shard-aware migrations
  - Concurrency safety: migration advisory locks
  - Migrator advisory lock (concurrent migrate protection)
  - Advisory locks (PostgreSQL pg_advisory_lock / MySQL GET_LOCK)

### D01: Database-specific types: arrays, JSON/JSONB, UUID (L)

- Depends on: Q02, M02a
- Files: `src/grant/type.cr`, `src/grant/serializers/jsonb.cr`, `src/grant/query/where_chain.cr (array and json operators)`, `src/grant/adapter/pg.cr (type table)`
- Acceptance specs: `spec/grant/types/pg_array_spec.cr (round trip, any/contains/overlaps with one bound array parameter; SQLite arm asserts clear unsupported error)`, `spec/grant/types/jsonb_spec.cr (native jsonb on PG, JSON text on SQLite, containment and path predicates, DB round trip)`, `spec/grant/types/uuid_spec.cr (round trip, find by string, invalid string casting, native uuid on PG, uuid_v7 option)`
- Perf guardrails: Bind a single array parameter, not per-element placeholders. Filter with ->> and @> so GIN indexes apply, never in Crystal. Offer time-ordered v7 UUID to avoid B-tree fragmentation.
- Rows:
  - Database-specific types: PostgreSQL arrays (Array(T))
  - Database-specific types: JSON/JSONB
  - Database-specific types: UUID

### Q06: from and common table expressions (L)

- Depends on: Q03
- Files: `src/grant/query/builder.cr (from/with region)`, `src/grant/query/assembler/*.cr (FROM and WITH rendering)`
- Acceptance specs: `spec/grant/query/from_subquery_spec.cr (bind order, unscope(:from))`, `spec/grant/query/cte_spec.cr (with, with_recursive, MySQL below 8 raises, recursive depth guard)`
- Perf guardrails: Preserve numbered PG parameter order across nested SELECTs and CTEs; the wrapped subquery is never executed separately.
- Rows:
  - from (custom FROM clause / subquery as table)
  - with / with_recursive (common table expressions)

### A04: Delegated types (M)

- Depends on: A01, P05
- Files: `src/grant/delegated_type.cr (new)`, `src/grant/associations.cr (macro hook only)`
- Acceptance specs: `spec/grant/associations/delegated_type_spec.cr (predicates, readers, build_entryable, exhaustive case, preload grouped by type)`
- Perf guardrails: Predicates and readers must not hit the DB; preload groups by type with one IN query per type.
- Rows:
  - delegated types

### O02: Fixtures and query log context (L)

- Depends on: O01, T01
- Files: `src/grant/test_fixtures.cr (new)`, `src/grant/query_logs.cr (new)`, `src/grant/log.cr`
- Acceptance specs: `spec/grant/test_fixtures_spec.cr (label-hashed ids, one bulk INSERT per table, accessors, rollback via wrapper)`, `spec/grant/query_logs_spec.cr (trailing comment, */ escaped, sqlcommenter format, fiber-local context)`, `spec/grant/verbose_logs_spec.cr (debug-only source location)`
- Perf guardrails: Bulk INSERT per fixture table. Append comments at the end of SQL so prepared-statement caches and pg_stat_statements grouping survive. Backtrace capture only in development at debug level.
- Rows:
  - Fixtures / test helpers (ActiveRecord::FixtureSet equivalent)
  - QueryLogs with context tags (SQL comment injection)
  - Verbose query logs (source location of SQL) and log tags with binds

## Wave 5

### M04: Database tasks, schema dump/load, seeds and generator API (XL)

- Depends on: M03, M01
- Files: `src/grant/tasks/database.cr (new)`, `src/grant/schema/dumper.cr (new)`, `src/grant/schema/loader.cr (new)`, `src/grant/seeds.cr (new)`, `src/grant/schema/generator.cr (new)`
- Acceptance specs: `spec/grant/tasks/database_tasks_spec.cr (create, drop, purge, setup, reset, prepare; production drop guarded)`, `spec/grant/schema/dumper_spec.cr (dump then load reproduces schema on SQLite and PG)`, `spec/grant/tasks/seeds_spec.cr (load_once idempotent)`, `spec/grant/schema/generator_spec.cr (AddEmailToUsers parsed to add_column plus index)`, `spec/grant/tasks/truncate_all_spec.cr`
- Perf guardrails: Dumper batches catalog queries per all tables. truncate_all is one multi-table TRUNCATE on PG. Grant exposes only the Tasks and Generator API; the CLI commands stay a thin wrapper in amber_cli main (V2 only, nothing for 1.x).
- Rows:
  - Migration CLI (amber database migrate/rollback/status/seed/create/drop)
  - Schema dump / schema.rb equivalent
  - Seeds
  - Amber CLI generate migration scaffold
  - Database tasks: create/drop database, purge, structure dump (structure.sql), setup/reset/prepare, truncate_all
  - Schema format configuration (:ruby vs :sql) and db:schema:load for fresh environments
  - Migration file generator naming conventions (AddXToY, CreateXs parse, timestamped versions)
  - Database tasks (create/drop/purge/migrate/schema load, DatabaseTasks)

### I02: Composite keys end to end (XL)

- Depends on: P01, A03, Q02, S02
- Files: `src/grant/composite_primary_key.cr`, `src/grant/composite_primary_key/transactions.cr`, `src/grant/associations.cr (foreign_key tuple)`, `src/grant/query/builder.cr (tuple IN)`
- Acceptance specs: `spec/grant/composite/persistence_spec.cr (create, update, destroy, reload round trip)`, `spec/grant/composite/find_where_spec.cr (find with tuples, row-value IN, OR expansion on SQLite where needed)`, `spec/grant/composite/associations_spec.cr (has_many/belongs_to with tuple foreign_key, preload batched on tuples)`, `spec/grant/composite/query_constraints_spec.cr (tenant_id predicate on find, update, destroy, reload, touch)`
- Perf guardrails: Use row-value IN on PG and MySQL; OR-expansion on SQLite only when required, with a size cap. Preload batches on tuples, never per parent. Every persistence statement (reload and touch too) must carry the extra predicates, checked by a query-recorder spec.
- Rows:
  - Composite primary keys
  - query_constraints composite model keys
  - composite foreign keys on associations (query_constraints)

## Reclassified or deferred

| Feature | Decision | Reason |
| --- | --- | --- |
| Lazy transactions (deferred BEGIN) | deferred | Low value, effort L, and lazy checkout mid-block risks starving the pool. Revisit after T01 lands and benchmarks show empty-transaction cost. |
| Serialization options (serializable_hash / as_json only:, except:, methods:) | n.a. | Under the JSON perimeter rule, an explicit JSON::Serializable projection struct is the idiomatic answer. Close as a documented pattern in docs/. |
| skip_callback / set_callback / define_callbacks / reset_callbacks (custom callback chains) | deferred | Effort L, low value, and compile-time chains make Ruby-style runtime mutation a poor fit. Revisit after CB01. |
| Callback objects (before_save MyCallback.new / class with before_save(record)) | deferred | Low value. A method Symbol or block already covers the use; the callback-object protocol adds compile-time surface for little benefit. |
| Views (create_view/drop_view) and materialized views | deferred | Low value, and needs PG-specific refresh semantics. Raw execute covers it until the DDL DSL (M02b) is stable. |
| Generated (virtual/stored) columns | deferred | Low value and overlaps the Infrastructure virtual-column row. Verbatim column_type: works as a workaround. Do both together later. |
| Virtual (generated) columns and column-level defaults functions | deferred | Duplicate of Generated (virtual/stored) columns and low value. Needs write-list exclusion and post-insert reload. Schedule after D01. |
| Database-specific types: PostgreSQL hstore | deferred | Low value, PG only, and JSONB covers the main use. |
| Database-specific types: PostgreSQL ranges, network (inet/cidr/macaddr), interval, native enum, citext | deferred | Effort L, low value, and range bound normalization makes dirty tracking risky. Take individual types on demand. |
| Encryption: pluggable key_provider, encryptor, message_serializer, AES-GCM cipher | deferred | Changing the cipher or payload layout breaks existing ciphertext. Needs a versioned payload design and a rotation plan first. Rails-compatible messages are a separate decision. |
| Adapter session variables (PostgreSQL statement_timeout/lock_timeout/search_path/application_name, MySQL variables/sql_mode) | deferred | crystal-db has no on-connect hook, so this needs an upstream or wrapped-connection factory. A SET on every checkout would double round trips. |
| has_many :through disable_joins | deferred | Low value and effort M. Merge with Cross-database associations (has_many / has_one through with disable_joins: true), which is a duplicate. Revisit after A02. |
| Cross-database associations (has_many / has_one through with disable_joins: true) | deferred | Duplicate of has_many :through disable_joins. Needs batched IN loading across connections. Do once after A02 and S02. |
| Arel-style typed column predicates (arel_table) | deferred | Effort L. Its value depends on stable relation immutability (Q01) and where composition (Q02). Consider a typed-column design in a later release, not this program. |
| upsert_all / upsert_all! (AR8 bulk upsert) | partial | Keep the row but drop the upsert_all! name: the bang belongs to insert_all!, so upsert_all! is not an AR method. |
| Migration class: up/down/change with versioned class ([8.0] compat) | partial | Implement up/down/change only. The per-version compatibility layer is Rails-history specific and n.a. |
| Amber CLI generate migration scaffold | partial | The CLI lives in amber_cli main (V2). Grant supplies only Generator.render and Generator.parse in M04. CLI work is tracked there, not in this repo. |
