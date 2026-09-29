# Transaction nesting now follows ActiveRecord

`Model.transaction` nesting changed to match ActiveRecord 8.

| Call inside an open transaction | Before | Now |
| --- | --- | --- |
| `transaction { }` | SAVEPOINT | joins the parent (no SQL); `Rollback` is swallowed without undoing anything |
| `transaction(requires_new: true) { }` | second connection, commits on its own | SAVEPOINT, rolled back with the outer transaction |
| `transaction(independent: true) { }` | (did not exist) | the old `requires_new` behavior: second connection, commits on its own |

## What to change

- Code that relied on `requires_new: true` committing independently of the outer
  transaction (audit rows that must survive an outer rollback, for example) must
  pass `independent: true`. It holds two pool connections for its duration and can
  deadlock against rows the outer transaction holds (`database is locked` on SQLite),
  so prefer restructuring over using it.
- Code that relied on a plain nested block undoing only its own work on `Rollback`
  must pass `requires_new: true`.
- `transaction` now returns the block value (`T?`, `nil` when `Rollback` was raised)
  instead of `Nil`. A method declared `: Nil` whose last expression is a
  `transaction` block needs an explicit `nil`.
- `Model.current_transaction` returns a `Grant::Transaction::Handle` (a null handle
  when nothing is open) instead of `TransactionState?`.
- `isolation:` on a nested (joined or savepoint) transaction raises
  `Grant::TransactionIsolationError` instead of being ignored.
- The transaction always opens on the writer connection.
- Savepoint names are `sp_1`, `sp_2`, ... per transaction (no random suffix).
