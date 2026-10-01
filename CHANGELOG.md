# Changelog

## Unreleased

### ActiveRecord parity, wave 6a

Parity moves from 320 to 370 complete features (77.7% to 89.8% of applicable).
32 features are partial and 10 are missing (the deferred list in
`docs/parity/ROADMAP.md`). This wave closes partial rows in validations,
attributes, querying, associations and connections.

- **Validations:** numericality reports `:not_a_number`, `:not_an_integer`
  or `:out_of_range` from the raw input when text is mass-assigned to a
  typed numeric column, and adds `only_numeric:`. Length and comparison
  validators add one typed error per failed bound with `count:`.
  Inclusion, exclusion, format and uniqueness errors carry `value:` in
  `errors.details`. `validates_with` keeps its options, and
  `Grant::TypedValidator(T)` is new.
- **Errors and I18n:** `Errors#details_for`; `Grant::I18n.with_locale` sets
  a fiber-local locale, and the message caches are keyed by locale.
- **Dirty tracking:** typed `<attr>_was`, `_change`, `_previously_was` and
  `_in_database` through converters (new `Converter.from_db`), plus
  `<attr>_came_from_user?`. `changed` returns names, and
  `changed_attributes` returns name => original value.
- **Attributes:** `Model.statuses` returns the enum mapping; signed ids on
  every model, including composite keys. `timestamps precision:`,
  date-granular `created_on`/`updated_on`, and a runtime
  `record_timestamps=`. `alias_attribute` works in `find_by`, `order`,
  `pluck`, `select` and `where`. `ModelName` gains `plural`, `collection`,
  `route_key`, `singular_route_key` and `human(count:)`.
- **Querying:** association scopes apply in `joins`, `left_joins`,
  `where.associated` and `where.missing`. A table reached twice is aliased
  automatically. `merge` appends ORDER BY. `unscope`, `only` and `except`
  cover every component. `reorder`, `reselect` and `regroup` accept every
  argument form. `Relation#update`/`update!` take hash, id and id-list
  forms. `Model.scoping` applies to `new`/`create` and reaches STI
  subclasses.
- **Associations:** collections are chainable SQL relations (order, limit,
  pluck, aggregates, joins, batches). They gain ordinal finders that read
  with LIMIT, plus `find_or_create_by`, `find_or_initialize_by` and
  `create_or_find_by`. The `has_one`, `has_many`, through and polymorphic
  writers persist immediately on a saved owner. `<singular>_ids` is typed.
  Built records show up in reads. Scoped `dependent:` touches only the
  scoped rows.
- **Connections and sharding:** `ConnectionRegistry.verify!` and
  `verify_all!` check `connects_to` at boot. `connected_to(database:
  {reading: ...})` accepts a role hash. Sharded models read
  `connects_to(shards:)`. Range and time-range shard pruning is new, and
  `prohibit_shard_swapping` is enforced everywhere. `database_tasks: false`
  is honored. Idle pooled connections are verified lazily
  (`verify_idle_after`, 30 s by default). `NoDatabaseError` and
  `ConnectionFailed` replace raw driver errors.
- **Tooling:** `scripts/spec-groups.sh` and the regression gate compile with
  `--incremental` (6.0 GB to 4.5 GB cold and 3.2 GB warm on
  `spec/grant/types`). `bench/lifecycle_bench.cr` compares raw crystal-db,
  `DB::Serializable`, the current Grant, origin/main and Granite v0.23.4
  across create, find, query, update and destroy.

Not met: `bench/relation_chain.cr` measures 2.98x against its 1.5x target,
so "Relation immutability" stays partial.

Behavior changes:

- `Errors#to_json` emits the ActiveRecord shape `{"attr": [messages]}`;
  the old list shape is `Errors#to_json_list`.
- `validates_length_of` adds `:too_short`, `:too_long` or `:wrong_length`
  instead of one combined message. Use the `too_short:`, `too_long:` and
  `wrong_length:` options for per-kind messages.
- `validates_comparison_of` adds one typed error per failed constraint
  instead of one `:comparison` error. A nil value adds `:blank`.
- `only_integer:` rejects a Float even with no fraction (`8.0`).
- Unconvertible text on a column with an unconditional numericality
  validator gives validation errors instead of `Grant::ConversionError`.
- A `validates_with` error without a type takes the validator's kind (it
  was `:invalid`). `strict:` leaves no errors behind.
- `changed_attributes` returns `Hash(String, DirtyValue)`; the old
  `Array(String)` is `changed`.
- `Model.statuses` returns `Hash(String, Enum)`; use `Status.values` for
  the list.
- Enum bang setters save new records too; `assign_<member>` assigns only.
- Array columns are always watched for in-place mutation.
- A clean save of an optimistic-locked model issues no SQL. Locked models
  write only changed columns.
- `created_on`/`updated_on` are stamped as dates.
- The generated `<attr>_previously_was`, `_in_database`,
  `_change_to_be_saved` and `saved_change_to_<attr>` methods return the
  column type.
- `assign_attributes` and `attributes=` raise `Grant::UnknownAttributeError`
  for unknown keys.
- `merge` appends the merged relation's ORDER BY instead of replacing it.
- `unscope(:joins)` drops only inner and raw joins; use `:left_joins` for
  LEFT JOINs.
- Association joins include the association's scope in the ON clause, and
  self-referential joins are aliased.
- `ShardedQueryBuilder#on_shard` and `#on_all_shards` return a copy; use
  `on_shard!` or `on_all_shards!` to pin in place.
- `Model.new` and `create` inside `Model.scoping` start from the scoping
  relation's attributes.
- `<singular>_ids` returns the typed key array, and `<singular>_ids=` saves
  each added record.
- `owner.profile = x` and `owner.posts = [...]` write immediately on a
  saved owner and apply `dependent:` to the records they displace.
- Unsaved built records appear in reads of an unloaded collection.
- `AssociationCollection#sum(Symbol | String)` is the SQL aggregate.
- Scoped `dependent:` affects only the scoped rows.
- `connects_to` owns its class's whole declaration: unnamed roles and shards
  are no longer inherited.
- Shard swaps inside `prohibit_shard_swapping` raise
  `Grant::ShardSwappingProhibited`.
- An explicit `connected_to(database:)` overrides the model's role map.
- A refused connection raises `Grant::ConnectionFailed` or
  `Grant::NoDatabaseError` instead of the driver exception.
- A failed bare `Adapter#open` reports its statement in
  `StatementInvalid#sql`.
- `RangeResolver` raises typed `Grant::Sharding` errors.
- A sharded model with no active shard uses its `:default` shard when one
  is declared.

### ActiveRecord parity, wave 5

Parity moves from 308 to 320 complete features (74.8% to 77.7% of applicable).
The 10 features still missing are the ones deliberately deferred in
`docs/parity/ROADMAP.md` (views, generated columns, hstore and range types,
pluggable encryption, custom callback chains, lazy transactions, session
variables, `disable_joins`).

- **Database tasks:** `Grant::Tasks::Database` with `create`, `drop`,
  `purge`, `migrate`, `rollback`, `status`, `seed`, `schema_dump`,
  `structure_dump`, `schema_load`, `setup`, `reset`, `prepare` and
  `truncate_all` (one multi-table `TRUNCATE` on PostgreSQL), per named
  connection, with protected-environment guards. The `amber` CLI commands
  are a thin wrapper in amber_cli.
- **Schema dump and load:** `Grant::Schema::Dumper` writes a Crystal
  `Grant::Schema.define` file (columns, keys, indexes, constraints, comments,
  PostgreSQL enums and extensions) with a fixed number of catalog queries, or
  a SQL structure file. `Grant::Schema.format` picks `:crystal` or `:sql`.
  Crystal schema and seed files are compiled into the task program, not
  interpreted.
- **Seeds:** `Grant::Seeds.define`, `run`, and idempotent `load_once`.
- **Generator API:** `Grant::Schema::Generator` parses `AddXToY`,
  `RemoveXFromY`, `CreateXs` and `CreateJoinTableXY` plus `name:type:index`
  attributes and renders the migration class.
- **Composite keys:** composite primary keys now create, update, destroy,
  reload and touch through the whole key; `find` by tuple and arrays of
  tuples with row-value `IN`; `query_constraints` so every write carries the
  extra predicates (optimistic locking included); and tuple foreign keys on
  `belongs_to`, `has_one` and `has_many` with batched preloading.
- **Associations:** `build_<assoc>`, `create_<assoc>` and `create_<assoc>!`
  for `belongs_to` and `has_one`; nested `has_many :through` (read-only);
  `source_type:` over a polymorphic source; and association options
  checked at compile time.

Behavior changes:

- An unknown association option (a typo, or an unsupported option such as
  `required:`, `order:` or `readonly:`) is now a compile error listing the
  valid options; before, it was silently ignored. `source_type:` without
  `through:` is a compile error too.
- Composite-key models now insert on `save`; before, `save` inserted nothing.
- An explicit `auto:` on a primary key column is now honored; before, the
  column macro silently replaced it with `false`.
- `reload_<assoc>` on a `:through` association also resets the through
  association, so it no longer returns stale join rows.
- Models now define `build_<assoc>`, `create_<assoc>` and `create_<assoc>!`
  for each non-polymorphic `belongs_to` and `has_one`; a method of the same
  name defined later in the class still overrides them.

### ActiveRecord parity, wave 4

Parity moves from 283 to 308 complete features (68.7% to 74.8% of applicable).

- **Schema DDL:** `add_index`/`remove_index`/`rename_index` and a model-level
  `index` declaration (unique, partial `where:`, `using:`, order, opclass,
  `include:`, expression, `concurrently` with `disable_ddl_transaction`);
  foreign key, check, unique and exclusion constraints with `validate: false`
  then `validate_*` on PostgreSQL; `add_column`, `remove_column`,
  `change_column`, `change_column_null` with backfill, and
  `change_table(bulk: true)`; `rename_table` (the PostgreSQL sequence and key
  index follow) and `rename_column` (default-named indexes follow);
  `create_join_table`, `add_reference` (polymorphic), table and column
  comments, and PostgreSQL enums and extensions. SQLite changes it cannot
  `ALTER` in place go through a table rebuild (`Grant::Schema::TableRebuild`).
- **Migrations:** `Grant::Schema::Migration` (`up`/`down`/`change`,
  `reversible`, `revert`, automatic inverses and `IrreversibleMigration`),
  `MigrationContext` (migrate to a version, rollback, redo, status, pending
  checks, `maintain_test_schema!`), a `schema_migrations` table read in one
  query, environment protection via `ar_internal_metadata`, and migrations
  held under an advisory lock (`Grant.with_advisory_lock`). Existing Micrate
  `.sql` files and the `micrate_db_version` table keep working.
  `MultiDatabaseMigrator` migrates named connections, shards and schema
  tenants with bounded parallelism and a skew report.
- **Types:** PostgreSQL array predicates (`array_contains`, `array_overlaps`,
  `array_contained_by`, `any`) that bind one array parameter; `JSON::Any`
  columns (jsonb on PostgreSQL, JSON text on SQLite) with `json_contains`,
  `json_path` and `json_has_key`; and time-ordered keys via
  `uuid_version: :v7`.
- **Queries:** `from` (a subquery, raw SQL or CTE name as the source) and
  `with` / `with_recursive` common table expressions, with bind order
  preserved and a depth guard on recursive CTEs.
- **Associations:** `delegated_type` with predicates and readers that never
  query, and preloading with one query per stored type.
- **Testing and logging:** `Grant::TestFixtures` (YAML fixtures, label-hashed
  ids, one bulk `INSERT` per table), `Grant::QueryLogs` (trailing SQL comment
  tags, sqlcommenter format), and verbose query logs with the calling source
  line in debug builds.

Behavior changes:

- A column typed `JSON::Any` now gets `Grant::Converters::JsonDocument` by
  default; before, such a column did not compile.
- `Model.find(String)` casts to the key type for UUID primary keys, so
  invalid UUID text returns `nil` without querying the database.
- `only(...)` now drops a `from` source and CTEs unless they are named, as in
  ActiveRecord.

### ActiveRecord parity, wave 3

Parity moves from 227 to 283 complete features (55.1% to 68.7% of applicable).

- **Locking:** `with_lock` returning the block's value, lock clauses
  (`FOR SHARE`, `NOWAIT`, `SKIP LOCKED`), `locking_column`,
  `lock_optimistically`, and version-checked `destroy` and `touch`.
- **Errors and validations:** an ActiveRecord-shaped `Errors` object
  (`of_type?`, `where`, `details` with options, humanized `full_messages`),
  message generation with I18n hooks (`human_attribute_name`), uniqueness
  `conditions:`, and one numericality error per failed constraint.
- **Callbacks:** `run_callbacks`, `after_save_commit`, `on:` for commit
  callbacks, `prepend:`, and one commit dispatch per record per transaction.
- **Queries:** a fiber-local query cache with an Amber V2 pipe, bounded async
  queries (`async_pluck`, `async_exists?`, ...), and scoping blocks.
- **Attributes:** enum prefixes, suffixes and `not_` scopes, `normalizes` on
  any type with query coercion, and typed `store_accessor`.
- **Passwords:** `has_secure_password` (optional `require
  "grant/secure_password"`, stdlib bcrypt, no new dependency).
- **Associations:** autosave with validation, `mark_for_destruction`, nested
  attributes for `belongs_to`, `dependent:` checks at compile time,
  `restrict_with_error`, counter caches with `reset_counters`, and touch on
  foreign-key change and destroy.
- **Sharding:** routed queries inside `with_shard`, merged ordered
  pagination, correct scatter aggregates (average from sum and count),
  instance routing, and shard-key immutability.
- **Configuration:** request middleware for reader/writer and shard
  selection, and declarative database configurations with per-name
  `*_DATABASE_URL` overrides.
- **Schema:** a create-table DSL, full type mapping (Int8/16, BigDecimal
  precision and scale, Bytes, Date, JSON), `default_sql`, and column options.
- **Encryption:** previous schemes for key rotation, `ignore_case`,
  compression, transparent same-name columns with deterministic `where`,
  fiber-local encryption context, and keyset-batched migration helpers.
- **Tooling:** `make spec` runs the suite in small groups
  (`scripts/spec-groups.sh`); a whole-suite `crystal spec` needs about 20 GB.

**Breaking changes (migration notes):**

- Primary keys default to `auto: true` only for integer and UUID types; a
  String key is a natural key.
- `lock!` and `with_lock` raise `UnsavedChangesLockError` on a dirty record
  (pass `force: true`), and `lock!` outside a transaction raises on PG and
  MySQL. Stale optimistic `destroy` and `touch` raise `StaleObjectError`.
- `full_messages` humanize attribute names ("First name"); numericality adds
  one error per constraint; `Errors#details` entries carry their options.
- Commit callbacks run once per record per transaction.
- `normalizes` runs in the setter, not before validation. Enum bang setters
  (`published!`) save persisted records.
- `has_many` validates new children on owner save; built children and new
  `belongs_to` parents are saved with the owner. Nested attributes raise
  `RecordNotFound` for ids outside the association.
- Queries inside `with_shard` target only that shard. Changing a persisted
  record's shard key raises `ShardKeyChangedError` (use `move_to_shard`);
  cross-shard joins raise `CrossShardJoinError`.
- Encryption migration helpers return counts and batch by key.

### ActiveRecord parity, wave 2

Parity moves from 137 to 227 complete features (33.3% to 55.1% of applicable).

- **Validations:** a unified `validates :a, presence: true, length: {min: 2}`
  macro, validation contexts (`on: :publish`, `valid?(:custom)`,
  `save(context:)`), `strict:`, `validate!`, multi-attribute macros,
  `validates_each` blocks, and condition arrays.
- **Persistence:** partial updates (a clean `save` issues no SQL),
  primary-key `==`/`hash`, `dup`, `attr_readonly`, destroyed-record guards,
  `touch(time:)`, `no_touching`, `record_timestamps`, and set-based
  `update_counters`.
- **Finders and creators:** `find(ids)` in one query, `find_or_create_by!`,
  `create_or_find_by` on a savepoint, relation-level `find_by`/`find_sole_by`,
  `create_with`, and block and array `create`.
- **Bulk writes:** `insert_all`/`insert_all!`/`upsert_all` with `unique_by`,
  `update_only`, `returning`, and chunking under each adapter's bind limit.
- **Queries:** endless and beginless ranges, `merge` replacement, `rewhere`,
  `unscope`, `where.associated`/`where.missing`, nested hash conditions,
  relation `or`/`and`, typed and grouped aggregates, `count(:col)`, typed
  `pluck`, nested and raw joins, `left_outer_joins`, NULLS FIRST/LAST,
  `in_order_of`, readonly relations, and keyset batching (`find_each` with
  `cursor:`, `in_batches` yielding relations).
- **Schema and attributes:** schema introspection with a schema cache,
  `verify_schema`, attribute introspection (`attributes`, `[]`, `slice`,
  `alias_attribute`, `*_before_type_cast`), cache keys, and a filtered
  `inspect`.
- **Instrumentation:** typed notifications for SQL, transactions and
  instantiation, plus spec helpers (`assert_queries`, a transactional wrapper,
  truncation helpers).
- **Connections:** pool stats, pool exhaustion errors, health recovery,
  replica routing and failover, read-only reconnection retries, and
  `with_connection` pinning.
- **Associations:** has_many :through writers, `has_and_belongs_to_many`,
  `<name>_ids`/`<name>_ids=`, collection `build`/`create` with inverses, and
  dependent-aware `delete`/`delete_all`.

**Breaking changes (migration notes):**

- Bare `valid?` uses the `:create` context for new records and `:update` for
  persisted ones. `valid?(context: :save)` runs every validator.
- `save` writes only changed columns; opt out with `partial_updates false`.
  `update_counters` no longer bumps `updated_at` unless `touch: true`.
- `dup` returns a new, unsaved record. Assigning an `attr_readonly` column on
  a persisted record raises `ReadonlyAttributeError`.
- `insert_all` skips duplicates by default and returns records with primary
  keys (RETURNING) where supported. Rows with mismatched keys raise
  `ArgumentError`.
- `sum`, `avg`, `min` and `max` return typed results (Int64 for integer
  columns) and a Hash for grouped relations instead of a wrong scalar.
- `in_batches` yields a relation. `find_each` pages by keyset (default batch
  size 1000) and never by OFFSET.
- `rewhere` keeps conditions on other columns; `merge` replaces conflicting
  equality conditions; `reverse_order` on an unordered relation sorts by
  primary key descending.
- Collection `delete_all` follows the association's `dependent:` strategy
  (nullify by default). `destroy_all` returns the destroyed records.
  `<name>_ids=` raises `RecordNotFound` for unknown ids. `create` on an unsaved
  owner raises `OwnerNotSaved`.
- `regenerate_<token>` persists the new token; `assign_new_<token>` keeps the
  old in-memory behavior. A missing signing secret raises
  `MissingSigningSecret` instead of returning nil.
- `Model#inspect` prints only column values and filters encrypted and
  configured attributes.
- Connection pools keep idle connections up to `pool_size`, and lost
  connections during writes raise instead of silently retrying.

### ActiveRecord parity, wave 1

Parity moves from 98 to 137 complete features (23.8% to 33.3% of applicable).
See `docs/PARITY.md` and `docs/parity/ROADMAP.md`.

- **Errors:** a `Grant::ErrorBase` taxonomy matching ActiveRecord
  (`RecordInvalid`, `RecordNotUnique`, `InvalidForeignKey`, `NotNullViolation`,
  `ValueTooLong`, `StatementInvalid` with redacted binds, `Deadlocked`,
  `LockWaitTimeout`, `SerializationFailure`, connection errors). Driver errors
  are translated by SQLSTATE/errno in the rescue path only.
- **Adapters:** capability predicates (`supports_json?`, ...), `adapter_name`,
  cached `database_version`, an adapter matrix doc, and a single-pass
  placeholder rewriter (2 to 11 times faster) with `??` as a literal `?`.
- **Relations:** chain methods return copies (bang forms mutate), `Model.all`
  is a lazy relation, loaded records are memoized, `take`/`last(n)`/ordinal
  finders, and `many?`/`one?`/`none?`/`empty?` use LIMIT probes.
- **Dirty tracking:** `saved_change_to_<attr>?(from:, to:)`, `changes_to_save`,
  `attributes_in_database`, `restore_<attr>!`, `clear_changes_information`,
  `attribute_will_change!`, and opt-in mutation detection.
- **Transactions:** joinable nesting, `requires_new` savepoints, typed return
  values, `Transaction::Handle` with `after_commit`/`after_rollback`,
  `after_all_transactions_commit`, and isolation errors on nested blocks.
- **Connections:** `connects_to(database: {writing:, reading:})`, a reading role
  that prevents writes, `connected_to?`, `connected_to_many`,
  `prohibit_shard_swapping`, abstract-class inheritance, and fiber-local
  context without a global mutex.
- **Sharding:** stable FNV-1a hash routing, any shard count up to 256, typed
  resolver errors, and Time-keyed range routing.
- **Associations:** preload honors association scopes and default scopes,
  has_one :through and polymorphic `as:` preloading, nested `includes`,
  reflection (`reflect_on_association`), `reload_<name>`/`reset_<name>`,
  strict loading modes, automatic inverses, and chunked IN lists.

**Breaking changes (migration notes):**

- Chain methods no longer mutate the receiver: assign the result, or use the
  bang form (`where!`, `order!`, ...). `Model.all` returns `Builder(Model)`;
  call `to_a` for an Array.
- Unordered SELECTs no longer add `ORDER BY <pk> DESC`. Set
  `Grant.settings.implicit_order = true` to keep it for one release.
- `transaction(requires_new: true)` opens a SAVEPOINT. The old
  separate-connection mode is `transaction(independent: true)`. A plain nested
  block joins the parent. Transactions return the block value (`T?`).
- `save!`/`create!`/`update!` raise `Grant::RecordInvalid` with
  "Validation failed: ..." messages. Driver errors surface as
  `Grant::StatementInvalid` subclasses instead of raw driver exceptions.
- SQLite connections enforce foreign keys and default file databases to WAL,
  `busy_timeout=5000`, and `synchronous=normal`. URL parameters override.
- Hash-sharded data placed by the old process-seeded hash must be re-homed:
  resolve each row's shard with the new resolver and move it.
- `connected_to(role: :reading)` raises `ReadOnlyError` on writes, and
  `:primary` aliases the writing role.
- `includes`/`preload`/`eager_load` raise `AssociationNotFoundError` for unknown
  names; loaded associations respect scopes; `reload` clears loaded
  associations.

- Re-audit the ActiveRecord 8 parity tracker against the code. It now tracks
  424 features (was 234); 54 rows previously marked complete had gaps and are
  now partial. The headline is 98 complete of 412 applicable (23.8%).
  `docs/parity/ROADMAP.md` orders the open rows into implementation waves.
- **Breaking:** `Model.count`, relation counts, and association `count`/`size`
  return `Int64`. Comparisons with integer literals continue to work; callers
  that annotate these results as `Int32` must update.
- Keep the deprecated `connection_config(**options)` method available as a
  forwarding alias for `configure_connection(**options)`.
