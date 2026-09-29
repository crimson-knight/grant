# Adapter matrix

What differs between Grant's PostgreSQL, MySQL and SQLite adapters, and how
Grant reports database failures. Ask the adapter instead of branching on its
class:

```crystal
Post.adapter.supports_partial_index? # => true on PostgreSQL and SQLite
Post.adapter.database_version        # => Grant::ServerVersion, cached after first use
```

## Capability predicates

The table below is generated from the predicates by
`spec/adapter/adapter_matrix_doc_spec.cr`, which fails when it drifts. To
refresh it after changing a predicate, run
`GRANT_WRITE_ADAPTER_MATRIX=1 crystal-alpha spec spec/adapter/adapter_matrix_doc_spec.cr`.

Columns show the answer at the reference version in the header. A predicate
that depends on the server release reads the adapter's cached
`database_version` (one query on first use, none afterwards); the last column
lists the gates.

<!-- capabilities:start -->
| Predicate | PostgreSQL 17 | MySQL 8.0.35 | SQLite 3.45 | Version gates |
| --- | --- | --- | --- | --- |
| `supports_insert_returning?` | yes | no | yes | SQLite 3.35; MariaDB 10.5 |
| `supports_insert_on_duplicate_skip?` | yes | yes | yes |  |
| `supports_insert_on_duplicate_update?` | yes | yes | yes |  |
| `supports_ddl_transactions?` | yes | no | yes |  |
| `supports_partial_index?` | yes | no | yes |  |
| `supports_expression_index?` | yes | yes | yes | MySQL 8.0.13 |
| `supports_check_constraints?` | yes | yes | yes | MySQL 8.0.16; MariaDB 10.2.1 |
| `supports_foreign_keys?` | yes | yes | yes |  |
| `supports_views?` | yes | yes | yes |  |
| `supports_datetime_with_precision?` | yes | yes | yes | MySQL 5.6.4; MariaDB 5.3 |
| `supports_json?` | yes | yes | yes | MySQL 5.7.8; MariaDB 10.2.7; SQLite 3.38 |
| `supports_common_table_expressions?` | yes | yes | yes | MySQL 8.0.1; MariaDB 10.2.1 |
| `supports_virtual_columns?` | yes | yes | yes | PostgreSQL 12; MySQL 5.7.6; MariaDB 10.2; SQLite 3.31 |
| `supports_comments?` | yes | yes | no |  |
| `supports_explain?` | yes | yes | yes |  |
| `supports_optimizer_hints?` | no | yes | no | MySQL 5.7.7 |
| `supports_advisory_locks?` | yes | yes | no |  |
| `supports_bulk_alter?` | yes | yes | no |  |
| `supports_concurrent_connections?` | yes | yes | yes | SQLite: file databases only |
| `supports_restart_db_transaction?` | yes | yes | no |  |
| `supports_disable_referential_integrity?` | yes | yes | yes |  |
| `supports_nulls_not_distinct?` | yes | no | no | PostgreSQL 15 |
<!-- capabilities:end -->

`supports_lock_mode?` and `supports_isolation_level?` take an argument, and
`supports_savepoints?` and `supports_index_hints?` predate this table, so they
are not listed. On PostgreSQL every lock mode and isolation level is
available, MySQL lacks `SHARE NOWAIT` and `SHARE SKIP LOCKED`, and SQLite has
neither row locks nor isolation levels.

### MariaDB

The MySQL adapter detects MariaDB from the version banner (`mariadb?`) and
uses MariaDB's own version line for the gates (for example CTEs from 10.2.1,
`RETURNING` from 10.5). MariaDB has no expression indexes and no optimizer
hint comments.

## Identity and server info

| Method | PostgreSQL | MySQL | SQLite |
| --- | --- | --- | --- |
| `adapter_name` | `PostgreSQL` | `MySQL` | `SQLite` |
| `database_version` | `SHOW server_version_num` | `SELECT VERSION()` | the linked library's version, no query |
| `current_database` | `current_database()` | `DATABASE()` | the database file, or `:memory:` |

`with_connection { |conn| ... }` yields the raw driver connection for the
current context (the open transaction's connection when there is one).

## Error translation

Driver failures are translated in the `rescue` path only, so a statement that
succeeds pays nothing. Every translated error is a `Grant::StatementInvalid`
(or `Grant::ReadOnlyError`) carrying `sql`, redacted `binds` and the driver
exception as `cause`. Codes are matched, not message text, with the exception
noted for MySQL and SQLite below.

| Grant error | PostgreSQL SQLSTATE | MySQL errno | SQLite |
| --- | --- | --- | --- |
| `Grant::RecordNotUnique` | `23505` | 1062, 1586 | `UNIQUE constraint failed` (19), extended 2067, 1555 |
| `Grant::InvalidForeignKey` | `23503` | 1451, 1452 | `FOREIGN KEY constraint failed` (19), extended 787 |
| `Grant::NotNullViolation` | `23502` | 1048, 1364 | `NOT NULL constraint failed` (19), extended 1299 |
| `Grant::ValueTooLong` | `22001` | 1406 | `SQLITE_TOOBIG` (18) |
| `Grant::Deadlocked` | `40P01` | 1213 | none |
| `Grant::SerializationFailure` | `40001` | none | none |
| `Grant::LockWaitTimeout` | `55P03` | 1205, 3572 | `SQLITE_BUSY` (5), `SQLITE_LOCKED` (6) |
| `Grant::StatementTimeout` | `57014` with a statement timeout message | 3024 | none |
| `Grant::QueryCanceled` | `57014` | 1317 | `SQLITE_INTERRUPT` (9) |
| `Grant::ReadOnlyError` | `25006` | 1290, 1792 | `SQLITE_READONLY` (8) |
| `Grant::NoDatabaseError` | `3D000` | 1049 | `SQLITE_CANTOPEN` (14) |

`Grant::Deadlocked` and `Grant::SerializationFailure` are
`Grant::TransactionRollbackError`s. PostgreSQL uses `57014` for both a user
cancel and `statement_timeout`; the server's message is the only difference,
so it is checked for that one code.

crystal-mysql raises server errors as a `PacketError` that keeps the message
but drops the error number, and SQLite's driver reports only the primary result
code. Grant recovers the MySQL errno from the server's fixed English message
prefix and the SQLite constraint type from SQLite's message prefix. This is
the one place text is matched; it moves to the numeric code once the drivers
expose it. A server running with a non-English `lc_messages` will fall through
to a plain `Grant::StatementInvalid`.

Errors raised by crystal-db itself are translated for every adapter:

| Driver failure | Grant error |
| --- | --- |
| `DB::PoolTimeout` | `Grant::ConnectionTimeoutError` |
| `DB::ConnectionRefused`, `DB::ConnectionLost`, `DB::PoolRetryAttemptsExceeded` | `Grant::ConnectionFailed` |

`Grant::ConnectionTimeoutError`, `Grant::ConnectionFailed` and
`Grant::AdapterNotAvailableError` are all `Grant::ConnectionNotEstablished`.

Passing the statement makes the error report it. The adapters do this for
their own statements; to get it for your own raw SQL:

```crystal
adapter.open("SELECT * FROM users WHERE id = ?", [id]) do |db|
  db.query("SELECT * FROM users WHERE id = ?", id) { |rs| ... }
end
```

`binds` never holds the raw values. They are `[FILTERED]` unless
`Grant::StatementInvalid.capture_bind_values = true`, and a captured value is
cut to 64 characters with at most 20 kept, so an exception cannot pin a large
payload in memory.

## SQLite defaults

Connections apply these PRAGMAs unless the URL says otherwise:

| PRAGMA | Default | Applies to |
| --- | --- | --- |
| `foreign_keys` | `1` | every database (SQLite leaves foreign keys off) |
| `journal_mode` | `wal` | file databases |
| `busy_timeout` | `5000` | file databases |
| `synchronous` | `normal` | file databases |

An explicit URL parameter wins (`sqlite3:./app.db?foreign_keys=0`), and
`Grant::Adapter::Sqlite.new(name, url, pragmas: {journal_mode: "delete"})`
overrides the defaults for one connection. The driver also accepts
`cache_size` and `wal_autocheckpoint`.

WAL needs a local filesystem with shared memory, so not a network mount, and it
creates `-wal` and `-shm` files next to the database that backups must
include. With `synchronous=normal` a power loss can roll back the last
transactions but never corrupts the file.

## Placeholders in raw SQL

Raw fragments use `?`. PostgreSQL rewrites each one to `$n`. A `?` inside a
quoted string, quoted identifier, dollar-quoted body or comment is data and is
left alone, and `??` is a literal `?`, which is how you write PostgreSQL's
JSONB operators:

```crystal
Doc.where("tags ?? 'urgent' AND owner_id = ?", owner_id) # tags ? 'urgent' AND owner_id = $1
```

MySQL and SQLite keep `?` as is and collapse `??` the same way. A fragment is
rewritten once; do not pass an already rewritten fragment through a second time
if it contains `??`.
