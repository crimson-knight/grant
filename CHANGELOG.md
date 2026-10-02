# Changelog

## Unreleased

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
