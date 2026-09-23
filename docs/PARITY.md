# Grant / ActiveRecord 8 parity

- Grant version: `0.23.4`
- Generated for commit: `b085aa30a64c43d3e8967d8b2fa91d9e31c636e2`
Baseline score source: commit `32b69d8`.

## Headline

**131 complete / 67 partial / 30 missing / 6 not applicable**

57.5% of applicable features complete (131 / 228); 234 features tracked.

## Counts by area

| Area | Complete | Partial | Missing | N/A | Applicable |
| --- | ---: | ---: | ---: | ---: | ---: |
| Adapters & connections | 6 | 10 | 1 | 0 | 17 |
| Associations | 19 | 6 | 3 | 0 | 28 |
| Core persistence & attributes | 25 | 6 | 5 | 0 | 36 |
| Infrastructure (locking, encryption, instrumentation, …) | 1 | 7 | 5 | 1 | 13 |
| Migrations & schema | 1 | 12 | 3 | 0 | 16 |
| Multiple databases & sharding | 5 | 19 | 3 | 3 | 27 |
| Query interface | 39 | 3 | 5 | 2 | 47 |
| Raw SQL | 8 | 0 | 0 | 0 | 8 |
| Validations & callbacks | 27 | 4 | 5 | 0 | 36 |
| **Total** | **131** | **67** | **30** | **6** | **228** |

## Feature status by area

### Adapters & connections

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| Adapter registration / selection | partial | `spec/grant/advanced_multi_database_spec.cr` | Adapter registry/source exists, but selection coverage is compile/config oriented rather than passing PG behavioral proof. |
| Single codebase with SQLite (local) + PostgreSQL (server) | partial | `spec/grant/advanced_multi_database_spec.cr` | No same-process mixed SQLite+PG integration spec was found. |
| Connection pooling | partial | `spec/grant/advanced_multi_database_spec.cr` | Pool code exists; pool contention and exhaustion are not exercised by the PG specs run. |
| Health monitor / reconnection | partial | `spec/grant/advanced_multi_database_spec.cr` | Source typo is fixed, but PG health-monitor/reconnect behavior lacks a passing feature-specific spec. |
| Replica load balancing (read/write splitting) | partial | `spec/grant/advanced_multi_database_spec.cr` | Current PG load-balance assertions fail; replica routing is not verified complete. |
| connected_to / multiple databases (AR 8 API) | partial | `spec/grant/prevent_writes_spec.cr` | Basic fiber-local context is fixed, but AR named-tuple connects_to/pool configuration parity is incomplete. |
| Transactions (basic, rollback, requires_new) | complete | `spec/grant/transaction_atomicity_spec.cr`, `spec/grant/transaction_spec.cr`, `spec/grant/locking/optimistic_spec.cr`, `spec/grant/locking/pessimistic_spec.cr` | — |
| Savepoints / nested transactions | complete | `spec/grant/transaction_atomicity_spec.cr`, `spec/grant/transaction_spec.cr`, `spec/grant/locking/optimistic_spec.cr`, `spec/grant/locking/pessimistic_spec.cr` | — |
| Transaction isolation levels | complete | `spec/grant/transaction_atomicity_spec.cr`, `spec/grant/transaction_spec.cr`, `spec/grant/locking/optimistic_spec.cr`, `spec/grant/locking/pessimistic_spec.cr` | — |
| Pessimistic locking (FOR UPDATE, FOR SHARE, SKIP LOCKED, NOWAIT) | complete | `spec/grant/transaction_atomicity_spec.cr`, `spec/grant/transaction_spec.cr`, `spec/grant/locking/optimistic_spec.cr`, `spec/grant/locking/pessimistic_spec.cr` | — |
| Optimistic locking (lock_version) | complete | `spec/grant/transaction_atomicity_spec.cr`, `spec/grant/transaction_spec.cr`, `spec/grant/locking/optimistic_spec.cr`, `spec/grant/locking/pessimistic_spec.cr` | — |
| Adapter feature matrix (PG vs MySQL vs SQLite differences) | partial | `spec/grant/advanced_multi_database_spec.cr` | Only the PG target was exercised; MySQL and SQLite behavior is not verified by this score. |
| Adapter-specific SQL placeholder handling | partial | `spec/grant/advanced_multi_database_spec.cr` | PG query coverage passes, but cross-adapter placeholder behavior was not exercised in this run. |
| Prepared statements / statement caching | missing |  | No per-connection prepared-statement cache exists. |
| Reconnection / connection lost handling | partial | `spec/grant/advanced_multi_database_spec.cr` | Source handles connection loss; no passing PG connection-loss recovery test was found. |
| Multiple databases / connected_to with shard: | partial | `spec/grant/advanced_multi_database_spec.cr` | Multi-DB/shard routing batch has failures and errors; subsystem remains partial. |
| Postgres transaction atomicity and same-connection writes | complete | `spec/grant/transaction_atomicity_spec.cr` | — |

### Associations

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| belongs_to | complete | `spec/grant/associations/association_options_spec.cr`, `spec/grant/associations/association_regressions_spec.cr` | — |
| has_one | complete | `spec/grant/associations/has_one_spec.cr` | — |
| has_many | complete | `spec/grant/associations/association_regressions_spec.cr` | — |
| has_many :through | complete | `spec/grant/associations/association_parity_spec.cr`, `spec/grant/associations/association_regressions_spec.cr` | — |
| has_one :through | complete | `spec/grant/associations/association_parity_spec.cr`, `spec/grant/associations/association_regressions_spec.cr` | — |
| HABTM (has_and_belongs_to_many) equivalent | missing |  | Grant has no HABTM association macro. |
| polymorphic associations (belongs_to, has_many :as, has_one :as) | complete | `spec/grant/associations/association_regressions_spec.cr`, `spec/grant/associations/association_parity_spec.cr` | — |
| inverse_of | complete | `spec/grant/associations/association_regressions_spec.cr`, `spec/grant/associations/association_parity_spec.cr` | — |
| dependent: :destroy | complete | `spec/grant/associations/association_options_spec.cr` | — |
| dependent: :delete / :delete_all | partial |  | Core dependent actions exist, but destroy_async is absent and the delete key differs between has_one/has_many. |
| dependent: :nullify | complete | `spec/grant/associations/association_options_spec.cr` | — |
| dependent: :restrict / :restrict_with_exception / :restrict_with_error | partial |  | Only Grant’s error-based :restrict path exists; :restrict_with_exception is absent. |
| autosave | partial | `spec/grant/associations/association_options_spec.cr`, `spec/grant/associations/association_regressions_spec.cr` | Dirty persisted children are not fully autosaved/validated like ActiveRecord. |
| counter_cache | partial | `spec/grant/associations/association_regressions_spec.cr` | Basic counter updates pass, but reset_counters and polymorphic counter-cache parity are incomplete. |
| touch option on belongs_to | complete | `spec/grant/associations/association_options_spec.cr` | — |
| optional: true on belongs_to | complete | `spec/grant/associations/association_options_spec.cr` | — |
| eager loading — includes/preload/eager_load API | complete | `spec/grant/eager_loading/eager_loading_spec.cr` | — |
| N+1 prevention / strict_loading | complete | `spec/grant/associations/association_regressions_spec.cr` | — |
| nested attributes (accepts_nested_attributes_for) | complete | `spec/grant/nested_attributes_spec.cr` | — |
| delegated types | missing |  | No delegated_type macro or generated delegated-type helpers exist. |
| association extensions / association-level scopes | partial | `spec/grant/associations/association_parity_spec.cr` | Proc scopes are supported and tested; arbitrary association extension blocks are not. |
| collection singular IDs accessor (post_ids / user_ids=) | missing |  | No equivalent found in current src. |
| association :source option for has_many :through | complete | `spec/grant/associations/association_regressions_spec.cr`, `spec/grant/associations/association_parity_spec.cr` | — |
| AssociationCollection build / create / create! | complete | `spec/grant/associations/association_regressions_spec.cr`, `spec/grant/associations/association_parity_spec.cr` | — |
| AssociationCollection destroy_all / delete_all | complete | `spec/grant/associations/association_regressions_spec.cr`, `spec/grant/associations/association_parity_spec.cr` | — |
| association caching / loaded? / reset | complete | `spec/grant/associations/association_regressions_spec.cr`, `spec/grant/associations/association_parity_spec.cr` | — |
| Relationship annotation / association reflection | partial |  | Registration is wired, but AR reflection query methods are absent. |
| belongs_to validates the referenced record, not only foreign-key presence | complete | `spec/grant/associations/association_regressions_spec.cr` | — |

### Core persistence & attributes

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| save / save! (create + update path) | complete | `spec/grant/transactions/save_spec.cr`, `spec/grant/transactions/create_spec.cr`, `spec/grant/transactions/update_spec.cr`, `spec/grant/transactions/destroy_spec.cr` | — |
| create / create! (class-level convenience) | complete | `spec/grant/transactions/save_spec.cr`, `spec/grant/transactions/create_spec.cr`, `spec/grant/transactions/update_spec.cr`, `spec/grant/transactions/destroy_spec.cr` | — |
| update / update! (instance-level, sets attributes then saves) | complete | `spec/grant/transactions/save_spec.cr`, `spec/grant/transactions/create_spec.cr`, `spec/grant/transactions/update_spec.cr`, `spec/grant/transactions/destroy_spec.cr` | — |
| destroy / destroy! (with callbacks) | complete | `spec/grant/transactions/save_spec.cr`, `spec/grant/transactions/create_spec.cr`, `spec/grant/transactions/update_spec.cr`, `spec/grant/transactions/destroy_spec.cr` | — |
| new_record? / persisted? / destroyed? | complete | `spec/grant/transactions/save_spec.cr`, `spec/grant/transactions/create_spec.cr`, `spec/grant/transactions/update_spec.cr`, `spec/grant/transactions/destroy_spec.cr` | — |
| find_or_create_by / find_or_initialize_by | complete | `spec/grant/integrators/find_or_spec.cr` | — |
| touch (instance-level, updates updated_at + optional fields) | complete | `spec/grant/transactions/touch_spec.cr` | — |
| touch_all (class-level bulk timestamp update) | complete | `spec/grant/convenience_methods_spec.cr` | — |
| import (bulk INSERT with batch_size, update_on_duplicate, ignore_on_duplicate) | complete | `spec/grant/transactions/import_spec.cr` | — |
| insert_all / insert_all! (AR8 bulk insert without callbacks) | partial | `spec/grant/convenience_methods_spec.cr`, `spec/grant/persistence/delete_spec.cr` | insert_all runs on PG; insert_all! bang API is absent. |
| upsert_all / upsert_all! (AR8 bulk upsert) | partial | `spec/grant/convenience_methods_spec.cr`, `spec/grant/persistence/delete_spec.cr` | upsert_all runs on PG; upsert_all! and single-row upsert are absent. |
| update_all (bulk UPDATE via query builder) | complete | `spec/grant/query/query_parity_spec.cr` | — |
| delete_all (bulk DELETE, skips callbacks) | complete | `spec/grant/convenience_methods_spec.cr`, `spec/grant/persistence/delete_spec.cr` | — |
| destroy_by / delete_by (conditional bulk destroy/delete) | complete | `spec/grant/convenience_methods_spec.cr`, `spec/grant/persistence/delete_spec.cr` | — |
| Dirty tracking (changed?, changes, attribute_was, per-attribute helpers) | complete | `spec/grant/dirty/dirty_tracking_spec.cr` | — |
| Attribute API (virtual attributes, default values, converters) | complete | `spec/grant/attribute_api_spec.cr` | — |
| Enum attributes (enum_attribute macro) | complete | `spec/grant/enum_attributes_spec.cr` | — |
| Normalization (normalizes macro, before_validation hook) | complete | `spec/grant/normalization_spec.cr` | — |
| Serialization / serialized_column (JSON/YAML serialized columns) | complete | `spec/grant/serialized_column_spec.cr`, `spec/grant/serialization_multimodel_spec.cr` | — |
| Store accessors (store_accessor for JSON column sub-keys) | missing |  | No store/store_accessor macro or per-key JSON accessors in current src. |
| Secure tokens (has_secure_token) | partial | `spec/grant/secure_token_spec.cr` | PG spec failures: generated token remains nil and the alphabet assertion fails. |
| Token for (generates_token_for / find_by_token_for — AR8 data-invalidating tokens) | complete | `spec/grant/token_for_spec.cr` | — |
| Signed IDs (signed_id / find_signed) | partial | `spec/grant/signed_id_spec.cr` | PG lookup by valid signed ID returns nil; find_signed! is absent. |
| Readonly attributes / readonly records (attr_readonly, readonly?) | complete | `spec/grant/persistence_helpers_spec.cr`, `spec/grant/persistence/direct_persistence_spec.cr` | — |
| Counter caches (counter_cache: on belongs_to) | partial | `spec/grant/associations/association_regressions_spec.cr` | Association counter updates pass, but reset_counters/increment_counter/decrement_counter are absent. |
| update_counters (class-level atomic counter increment/decrement) | complete | `spec/grant/convenience_methods_spec.cr` | — |
| update_attribute / update_columns (skip-validation targeted update) | complete | `spec/grant/persistence_helpers_spec.cr`, `spec/grant/persistence/direct_persistence_spec.cr` | — |
| increment! / decrement! / toggle! (in-place mutators that persist) | complete | `spec/grant/persistence_helpers_spec.cr`, `spec/grant/persistence/direct_persistence_spec.cr` | — |
| Class-level find / find! by primary key | complete | `spec/grant/querying/find_spec.cr` | — |
| reload persisted record from the database | complete | `spec/grant/querying/reload_spec.cr` | — |
| create_or_find_by (unique-constraint race-safe create) | missing |  | No equivalent class method exists. |
| create_with relation defaults | missing |  | No relation #create_with implementation exists. |
| Non-bang increment / decrement / toggle (in-memory only) | partial |  | Non-bang behavior has no passing PG spec in this audit. |
| Dirty tracking before save (changes_to_save / will_save_change_to_attribute?) | missing | `spec/grant/dirty/dirty_tracking_spec.cr` | ActiveRecord pre-save dirty-state helper names are absent. |
| Single-table inheritance (STI) | complete | `spec/grant/sti/sti_behavior_spec.cr`, `spec/grant/sti/sti_personas_spec.cr`, `spec/grant/sti/sti_validation_callback_inheritance_spec.cr` | — |
| attribute_before_type_cast | missing |  | No raw-before-cast attribute reader exists. |

### Infrastructure (locking, encryption, instrumentation, …)

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| Encrypted attributes (encrypts macro) | partial | `spec/grant/encryption_database_spec.cr`, `spec/grant/encryption_key_rotation_spec.cr` | PG scratch round-trip and deterministic lookup pass; checked-in key-rotation specs are SQLite-bound. Cipher is AES-256-CBC + HMAC, not AR AES-GCM. |
| Instrumentation / logging (Crystal Log module) | partial |  | Source is present, but no passing PG logging/instrumentation spec was executed in this audit. |
| N+1 detection and QueryStats (development/testing aid) | partial | `spec/grant/associations/association_regressions_spec.cr` | Source is present, but no passing PG detector/statistics spec was executed in this audit. |
| Composite primary keys | partial |  | Scratch PG repro: save! returned without a matching row being readable; the composite-primary-key transaction implementation is explicitly TODO in current src. |
| Database-specific types: PostgreSQL arrays (Array(T)) | partial | `spec/grant/converters/json_spec.cr`, `spec/grant/converters/pg_numeric_spec.cr` | Array storage/conversion exists, but no passing PG array-column query/operator spec was found. |
| Database-specific types: JSON/JSONB | partial | `spec/grant/converters/json_spec.cr`, `spec/grant/converters/pg_numeric_spec.cr` | JSON serialization passes; JSONB schema/query operators and store accessors are absent. |
| Database-specific types: UUID | complete | `spec/grant/columns/uuid_spec.cr`, `spec/grant/converters/converters_spec.cr` | — |
| Connection-level retries (retry_attempts, retry_delay) | partial |  | Connection configuration is delegated to crystal-db; no PG retry behavior spec was found. |
| Fixtures / test helpers (ActiveRecord::FixtureSet equivalent) | missing |  | No fixture loader or transactional test helper equivalent exists. |
| Advisory locks (PostgreSQL pg_advisory_lock / MySQL GET_LOCK) | n.a. |  | Database advisory-lock helpers are not part of ActiveRecord 8 core parity. |
| QueryLogs with context tags (SQL comment injection) | missing |  | Query annotate works; request-context QueryLogs tags are absent. |
| Configurable optimistic-locking column (locking_column) | missing |  | Grant does not expose ActiveRecord locking_column customization. |
| query_constraints composite model keys | missing |  | No query_constraints model API exists. |
| Schema cache / schema introspection API | missing |  | No ActiveRecord schema-cache equivalent is exposed. |

### Migrations & schema

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| Grant::Migrator — compile-time CREATE TABLE DSL | partial | `spec/grant/migrator/migrator_spec.cr` | Create/drop and defaults work; ALTER TABLE, index, foreign-key, and check-constraint DSLs are absent. |
| Micrate integration — versioned SQL migration files (Up/Down) | partial |  | Versioning is delegated to external Micrate; Grant has no integrated migration context. |
| Reversible migrations | partial |  | Raw SQL up/down can be hand-authored; there is no reversible-operation DSL. |
| Migration CLI (amber database migrate/rollback/status/seed/create/drop) | partial |  | CLI is external to Grant and no passing Grant PG CLI spec was found. |
| Schema type mapping per adapter | partial | `spec/grant/migrator/migrator_spec.cr` | Implementation is present, but this audit found no named passing PostgreSQL spec for the complete ActiveRecord behavior. |
| Schema dump / schema.rb equivalent | missing |  | No schema dump/load format or schema cache artifact exists. |
| Indexes — creation in migrations | partial |  | No Grant migration index DSL or index introspection; raw SQL is the workaround. |
| Foreign keys — DDL support | partial |  | No Grant migration foreign-key DDL DSL; raw SQL is the workaround. |
| Check constraints | partial |  | No Grant migration check-constraint DSL; raw SQL is the workaround. |
| Column defaults in CREATE TABLE | complete | `spec/grant/migrator/migrator_spec.cr` | — |
| Seeds | partial |  | A Crystal seed-script convention exists, but no Grant seed API or PG seed spec was found. |
| Migration versioning / schema_migrations table tracking | partial |  | Version tracking is external; Grant has no schema_migrations/context API. |
| Encryption migration helpers (data migration for encrypted columns) | partial |  | Source helpers exist, but this audit found no passing PG migration-helper spec. |
| Amber CLI generate migration scaffold | partial |  | Scaffolding is in a separate CLI project and was not PG-verified from this checkout. |
| alter_table / change_column / add_column at runtime via Grant DSL | missing |  | No ALTER TABLE migration DSL exists. |
| rename_table DSL | missing |  | No rename_table migration DSL exists. |

### Multiple databases & sharding

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| connects_to (database: / shards: DSL on models) | partial | `spec/grant/advanced_multi_database_spec.cr` | DSL metadata exists, but connections must be registered separately; PG config tests fail in the mixed multi-DB batch. |
| connected_to (role/shard/database block switching) | complete | `spec/grant/prevent_writes_spec.cr` | — |
| Reading/writing roles (role: :reading, role: :writing) | partial | `spec/grant/advanced_multi_database_spec.cr` | Manual role context exists; replica lag/load-balancer PG assertions fail in multidb-sharding-pg.log. |
| while_preventing_writes / prevent_writes flag | complete | `spec/grant/prevent_writes_spec.cr` | — |
| per-model connections (connection macro / database_name) | partial | `spec/grant/advanced_multi_database_spec.cr` | Connection macro exists, but no isolated passing PG proof of separate named model connections was found. |
| ConnectionRegistry (central registry) | partial | `spec/grant/advanced_multi_database_spec.cr` | Registry exists; multi-database PG batch includes config errors, so full routing behavior remains partial. |
| Connection pooling (pool_size, checkout_timeout, etc.) | partial | `spec/grant/advanced_multi_database_spec.cr` | Pool setup exists, but no passing PG contention/exhaustion proof was found. |
| Connection health monitoring | partial | `spec/grant/advanced_multi_database_spec.cr` | Health monitor source exists; no passing PG health/reconnect spec was found in the focused run. |
| Read replica load balancing (multiple replicas, strategies) | partial | `spec/grant/advanced_multi_database_spec.cr` | PG round-robin and least-connections expectations fail in multidb-sharding-pg.log. |
| Replica lag tracking (stick_to_primary, wait period) | partial | `spec/grant/advanced_multi_database_spec.cr` | PG replica lag timestamp assertions fail in multidb-sharding-pg.log. |
| Connection failover (unhealthy primary/replica fallback) | partial | `spec/grant/advanced_multi_database_spec.cr` | Source exists, but no passing PG failover spec was found. |
| Horizontal sharding — hash-based (shards_by :col, strategy: :hash) | partial | `spec/grant/advanced_multi_database_spec.cr` | The PG routing batch fails single-shard/custom-key routing cases; limits remain experimental. |
| Horizontal sharding — range-based (strategy: :range / :time_range) | partial | `spec/grant/advanced_multi_database_spec.cr` | PG range validation fails; routing still falls back to scatter-gather in unsupported predicates. |
| Horizontal sharding — geo/region-based (strategy: :geo) | partial | `spec/grant/advanced_multi_database_spec.cr` | PG region validation fails in the focused multi-DB/sharding batch. |
| ShardManager (fiber-local shard context) | partial | `spec/grant/advanced_multi_database_spec.cr` | Context object exists, but no dedicated passing PG shard-routing integration proof was found. |
| ShardedQueryBuilder + Query routing (single/scatter-gather/multi-shard) | partial | `spec/grant/advanced_multi_database_spec.cr` | PG single-shard and custom-key routing cases fail; several shard contexts are missing. |
| Sharding integration specs (cross-strategy, error handling, transactions, concurrent) | partial | `spec/grant/advanced_multi_database_spec.cr` | Integration batch has routing errors and pending cases; coverage is incomplete. |
| Distributed transactions across shards | n.a. |  | ActiveRecord 8 does not provide atomic distributed transactions across independent databases. |
| Shard key immutability enforcement | missing |  | Saving a changed shard key is not guarded. |
| Cross-shard join detection | missing |  | No cross-shard join guard exists. |
| Automatic role-switching middleware (DatabaseSelector equivalent) | missing |  | Grant has no Amber request middleware that automatically routes reads and writes. |
| LookupResolver for custom shard mappings | partial | `spec/grant/advanced_multi_database_spec.cr` | Resolver exists, but the shards_by DSL does not expose strategy: :lookup and no PG spec proves it. |
| Fiber-local connection context isolation (concurrency safety) | complete | `spec/grant/fiber_connection_context_spec.cr` | — |
| Elastic sharding / resharding / consistent hashing | n.a. |  | ActiveRecord 8 does not provide automatic elastic resharding or consistent-hash migration. |
| Shard-aware migrations | n.a. |  | ActiveRecord 8 does not automatically coordinate schema migrations across every shard. |
| Per-shard connection with read replica (shards: {shard_one: {writing:, reading:}}) | partial | `spec/grant/advanced_multi_database_spec.cr` | Per-shard context exists, but replica routing tests fail in the PG batch. |
| find_each across all shards | partial | `spec/grant/query/query_regressions_spec.cr` | No passing PG shard-wide iteration spec; current iteration is serial and option coverage is incomplete. |
| Async / parallel shard execution (ShardedExecutor) | partial | `spec/grant/advanced_multi_database_spec.cr` | Executor exists, but no passing PG cross-shard async behavior spec was found. |
| Row-level multi-tenancy / current tenant scoping | complete | `spec/grant/scale/multitenant_scoping_spec.cr` | — |
| Postgres schema-per-tenant switching | complete | `spec/grant/scale/schema_tenant_spec.cr` | — |

### Query interface

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| where (hash/keyword args) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| where (string/raw SQL with placeholder) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| where (Range translates to >= AND <=) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| where (subquery / IN subquery) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| or / and (flat API on builder) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| or (block form — grouped OR clause) | complete | `spec/grant/querying/or_not_block_params_spec.cr` | — |
| not (block form — grouped NOT clause) | complete | `spec/grant/querying/or_not_block_params_spec.cr` | — |
| merge (combining query relations) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| named scopes | complete | `spec/grant/scoping/named_scope_chaining_spec.cr` | — |
| default_scope | complete | `spec/grant/scoping/named_scope_chaining_spec.cr` | — |
| unscoped | complete | `spec/grant/query/query_parity_spec.cr` | — |
| unscope (remove specific query clauses) | complete | `spec/grant/query/query_parity_spec.cr` | — |
| extending (adding methods to a relation at runtime) | n.a. |  | Ruby adds arbitrary modules to relation instances at runtime; Crystal uses static types and compile-time extensions. |
| find_by / find_by! | complete | `spec/grant/querying/find_by_spec.cr` | — |
| find_each (batch iteration) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| find_in_batches | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| in_batches (relation-based cursor batching) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| pluck (single column) | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| pluck (multiple columns) | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| pick (single/multi column first row) | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| ids (pluck all primary keys efficiently) | complete | `spec/grant/query/query_parity_spec.cr` | — |
| select / custom column projection (SELECT id, name FROM ...) | complete | `spec/grant/query/query_parity_spec.cr` | — |
| distinct | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| group / group_by | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| having | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| order (single/multi-field, asc/desc) | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| reorder / reverse_order / rewhere / reselect / regroup | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| joins (INNER JOIN) | complete | `spec/grant/query/query_parity_spec.cr` | — |
| left_outer_joins (LEFT JOIN) | complete | `spec/grant/query/query_parity_spec.cr` | — |
| where.missing / where.has (association-based JOIN conditions) | partial |  | Grant requires explicit table and foreign_key arguments; Rails accepts association names. |
| aggregations (count / sum / avg / min / max) | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| calculate (generic aggregation method) | missing |  | Named aggregate methods exist; the AR calculate API is absent. |
| tally_by (group count via Enumerable) | n.a. |  | tally_by is not an ActiveRecord 8 public API. |
| none (null relation) | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| readonly relations (prevent persistence on fetched records) | missing |  | No equivalent found in current src. |
| explain (EXPLAIN query plan) | complete | `spec/grant/query/query_parity_spec.cr` | — |
| annotate (SQL comment injection) | complete | `spec/grant/query/query_parity_spec.cr` | — |
| optimizer hints (e.g. FORCE INDEX for MySQL) | missing |  | No ActiveRecord-style optimizer_hints relation API exists. |
| async queries (fiber/channel-based) | partial | `spec/grant/async_spec.cr` | PG async aggregation tests return zero results and async metrics stay empty. |
| exists? | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| sole / find_sole_by | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| WhereChain (LIKE, NOT LIKE, IS NULL, IS NOT NULL, NOT IN, BETWEEN, comparison ops, EXISTS/NOT EXISTS) | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| scope chaining (scope.scope) | complete | `spec/grant/scoping/named_scope_chaining_spec.cr` | — |
| query cache (within-request result memoization) | missing |  | No Model.cache/uncached or request query-cache implementation exists. |
| from (custom FROM clause / subquery as table) | missing |  | No relation #from implementation exists. |
| dup (query builder copy) | complete | `spec/grant/query/query_parity_spec.cr`, `spec/grant/querying/relation_calculations_spec.cr`, `spec/grant/query/modifiers_spec.cr` | — |
| Relation limit / offset | complete | `spec/grant/query/query_regressions_spec.cr` | — |
| Relation take / first / last result helpers | complete | `spec/grant/querying/first_spec.cr`, `spec/grant/query/query_parity_spec.cr` | — |
| Relation destroy_all (callback-aware relation deletion) | partial | `spec/grant/persistence/delete_spec.cr` | The builder exposes destroy_all; PG callback semantics are not proven by a focused spec. |

### Raw SQL

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| Model.find_by_sql(sql, binds) hydrates model instances | complete | `spec/grant/raw_sql_spec.cr` | — |
| Model.count_by_sql(sql, binds) returns Int64 | complete | `spec/grant/raw_sql_spec.cr` | — |
| Raw connection execute/exec_query and Grant::Result | complete | `spec/grant/raw_sql_spec.cr` | — |
| Raw connection select_all/select_one/select_value/select_values/select_rows | complete | `spec/grant/raw_sql_spec.cr` | — |
| Bound Model.exec and Model.scalar overloads | complete | `spec/grant/raw_sql_spec.cr` | — |
| ActiveRecord-shaped sanitize_sql_array and sanitize_sql class methods | complete | `spec/grant/raw_sql_spec.cr` | — |
| Explicit raw scope and tenancy boundaries for model and connection SQL | complete | `spec/grant/raw_sql_spec.cr` | — |
| Grant.connection(name) exposes named connections without model scoping | complete | `spec/grant/raw_sql_spec.cr` | — |

### Validations & callbacks

| Feature | Status | Evidence specs | Gap or N/A reason |
| --- | --- | --- | --- |
| validates_presence_of | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_uniqueness_of (with scope, case_sensitive, allow_nil, allow_blank) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_numericality_of | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_format_of (with:, without:) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_length_of / validates_size_of | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_inclusion_of | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_exclusion_of | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_confirmation_of | partial | `spec/grant/validators/built_in_spec.cr` | Its spec remains pending due a Crystal macro limitation; no passing PG behavior proof. |
| validates_acceptance_of | partial | `spec/grant/validators/built_in_spec.cr` | Its spec remains pending due a Crystal macro limitation; no passing PG behavior proof. |
| validates_associated | partial | `spec/grant/validators/built_in_spec.cr` | Its spec remains pending due a Crystal macro limitation; no passing PG behavior proof. |
| Custom validators via validate block/proc | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validate :method_name (AR-style method reference validator) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| Unified validates macro (AR style: validates :field, presence: true, length: {min:2}) | missing |  | No single unified validates macro; separate validator macros are required. |
| validates_comparison_of (AR 7.1+) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_absence_of (AR opposite of presence) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| validates_with (custom validator class) | partial | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | Grant has a validates_with macro form, but it does not implement the ActiveRecord EachValidator class protocol. |
| Validation contexts (on: :create, :update, :save) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| Conditional validations (if:, unless: as Symbol method references) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| Conditional validations (if:/unless: as lambda/proc) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| Errors API (add, [], full_messages, where, of_type, include?, attribute_names, group_by_attribute, merge!, to_hash, to_json) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| errors.details (AR8 structured type+options per error) | missing |  | Errors expose messages but no structured AR details/type/options API. |
| invalid? method | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| strict: option on validators (raises instead of adding to errors) | missing |  | No strict validation option that raises on validation failure. |
| Full lifecycle callbacks (before/after save, create, update, destroy, after_initialize, after_find, before/after_validation, after_touch) | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| around_save, around_create, around_update, around_destroy | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| around_validation callback | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| Callback halting via abort! (equivalent to AR throw :abort) | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| Conditional callbacks (if:, unless: on lifecycle callbacks) | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| after_commit, after_rollback, after_create_commit, after_update_commit, after_destroy_commit | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| after_rollback fires on explicit transaction rollback | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| Callback ordering (multiple callbacks on same event) | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| run_callbacks (manual callback execution) | missing |  | No public run_callbacks(:event) API exists. |
| Normalization (normalizes macro, runs before validation) | complete | `spec/grant/normalization_spec.cr` | — |
| skip_validation option on save (validate: false) | complete | `spec/grant/callbacks/lifecycle_callbacks_spec.cr`, `spec/grant/callbacks/after_commit_timing_spec.cr`, `spec/grant/callbacks/around_validation_spec.cr` | — |
| Valid? with custom context (valid?(:custom)) | complete | `spec/grant/validators/parity_spec.cr`, `spec/grant/validators/contexts_spec.cr`, `spec/grant/errors/errors_api_spec.cr` | — |
| after_all_transactions_commit | missing |  | No global outermost-commit callback API exists. |

## Prioritized missing features

1. **create_or_find_by (unique-constraint race-safe create)** (Core persistence & attributes) — No equivalent class method exists.
2. **create_with relation defaults** (Core persistence & attributes) — No relation #create_with implementation exists.
3. **Store accessors (store_accessor for JSON column sub-keys)** (Core persistence & attributes) — No store/store_accessor macro or per-key JSON accessors in current src.
4. **Dirty tracking before save (changes_to_save / will_save_change_to_attribute?)** (Core persistence & attributes) — ActiveRecord pre-save dirty-state helper names are absent.
5. **attribute_before_type_cast** (Core persistence & attributes) — No raw-before-cast attribute reader exists.
6. **collection singular IDs accessor (post_ids / user_ids=)** (Associations) — No equivalent found in current src.
7. **HABTM (has_and_belongs_to_many) equivalent** (Associations) — Grant has no HABTM association macro.
8. **delegated types** (Associations) — No delegated_type macro or generated delegated-type helpers exist.
9. **Unified validates macro (AR style: validates :field, presence: true, length: {min:2})** (Validations & callbacks) — No single unified validates macro; separate validator macros are required.
10. **errors.details (AR8 structured type+options per error)** (Validations & callbacks) — Errors expose messages but no structured AR details/type/options API.
11. **strict: option on validators (raises instead of adding to errors)** (Validations & callbacks) — No strict validation option that raises on validation failure.
12. **run_callbacks (manual callback execution)** (Validations & callbacks) — No public run_callbacks(:event) API exists.
13. **after_all_transactions_commit** (Validations & callbacks) — No global outermost-commit callback API exists.
14. **query cache (within-request result memoization)** (Query interface) — No Model.cache/uncached or request query-cache implementation exists.
15. **from (custom FROM clause / subquery as table)** (Query interface) — No relation #from implementation exists.
16. **readonly relations (prevent persistence on fetched records)** (Query interface) — No equivalent found in current src.
17. **calculate (generic aggregation method)** (Query interface) — Named aggregate methods exist; the AR calculate API is absent.
18. **optimizer hints (e.g. FORCE INDEX for MySQL)** (Query interface) — No ActiveRecord-style optimizer_hints relation API exists.
19. **Prepared statements / statement caching** (Adapters & connections) — No per-connection prepared-statement cache exists.
20. **Fixtures / test helpers (ActiveRecord::FixtureSet equivalent)** (Infrastructure (locking, encryption, instrumentation, …)) — No fixture loader or transactional test helper equivalent exists.
21. **Schema dump / schema.rb equivalent** (Migrations & schema) — No schema dump/load format or schema cache artifact exists.
22. **alter_table / change_column / add_column at runtime via Grant DSL** (Migrations & schema) — No ALTER TABLE migration DSL exists.
23. **rename_table DSL** (Migrations & schema) — No rename_table migration DSL exists.
24. **Shard key immutability enforcement** (Multiple databases & sharding) — Saving a changed shard key is not guarded.
25. **Cross-shard join detection** (Multiple databases & sharding) — No cross-shard join guard exists.
26. **Automatic role-switching middleware (DatabaseSelector equivalent)** (Multiple databases & sharding) — Grant has no Amber request middleware that automatically routes reads and writes.
27. **Configurable optimistic-locking column (locking_column)** (Infrastructure (locking, encryption, instrumentation, …)) — Grant does not expose ActiveRecord locking_column customization.
28. **query_constraints composite model keys** (Infrastructure (locking, encryption, instrumentation, …)) — No query_constraints model API exists.
29. **Schema cache / schema introspection API** (Infrastructure (locking, encryption, instrumentation, …)) — No ActiveRecord schema-cache equivalent is exposed.
30. **QueryLogs with context tags (SQL comment injection)** (Infrastructure (locking, encryption, instrumentation, …)) — Query annotate works; request-context QueryLogs tags are absent.
