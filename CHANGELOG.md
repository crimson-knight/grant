# Changelog

## 0.28.1 (2026-11-25)

Grant builds on Windows again. Grant's SQLite driver compiles its own
engine alongside the C library, and the engine's operating-system files use
POSIX locks, mmap(2) and localtime_r, so an app on
`require "grant/adapter/sqlite"` (the C library, the default) did not
compile for Windows on 0.27.0 and 0.28.0. On Windows those files are left
out: opening a database file through Grant's engine raises
`Grant::SQLiteEngine::UnsupportedPlatform`, naming the C library, and the C
library runs as before. Nothing changes on macOS or Linux. A CI job now
type-checks Grant for x86_64-windows-msvc.

Minimum Crystal: 1.19.0

## 0.28.0 (2026-11-25)

Grant 0.28.0 connects to PostgreSQL over Beryl TLS 1.3 and runs its tests
against MySQL through crimson-knight/crystal-mysql on Beryl, so an app on
Grant links no OpenSSL with no flag and no setting. It ships in the Amber
stack's Beryl-adoption release with Amber 2.0.0-beta.16 and Amber CLI
2.0.17, and carries Beryl 0.2.1 (certificates without an authority key
identifier, as private database CAs make them, now verify).

### Beryl 0.2.1

- The vendored Beryl moves from ed5f21e7 to 0.2.1: a leaf or intermediate
  without an authority key identifier is matched to its issuer by name and
  signature, as Go and OpenSSL do.
- Without `sslrootcert`, the PostgreSQL driver checks the server against the
  system roots; on macOS that is now /etc/ssl/cert.pem joined with Beryl's
  pinned Mozilla roots, since macOS 27.2.1's file lacks roots the keychain
  trusts (SSL.com TLS ECC Root CA 2022, AAA Certificate Services).
- The MySQL development dependency (crimson-knight/crystal-mysql) moves to
  0.18.1 (ce9cbfab), which pins the same Beryl 0.2.1.

### pg_dump and psql check the server as the app does

- `structure_dump` and `schema_load` pass the database URL's `sslmode`,
  `sslrootcert`, `sslcert` and `sslkey` to `pg_dump` and `psql` (as
  `PGSSLMODE`, `PGSSLROOTCERT`, `PGSSLCERT`, `PGSSLKEY`), with
  `PGSSLMINPROTOCOLVERSION=TLSv1.3`. With `verify-ca` or `verify-full` and
  no `sslrootcert` (or `sslrootcert=system`), libpq gets the bundle the
  driver reads: the file `SSL_CERT_FILE` names, else the operating system's.
  A URL without `sslmode` gets the driver's default (`disable` on this
  machine, `prefer` elsewhere), and these values replace the caller's own
  `PGSSL*` variables. Before, the tools connected with libpq's defaults
  and did not verify the server.

### PostgreSQL TLS runs on Beryl TLS 1.3; no OpenSSL by default

- The PostgreSQL driver connects over Beryl TLS 1.3, written in Crystal, so
  an app on the PostgreSQL adapter links neither libssl nor libcrypto with no
  flag and no setting. `sslmode` `require`, `verify-ca` and `verify-full`
  work as before; `verify-ca` checks the chain only and `verify-full` the
  chain and the host name. Without `sslrootcert` (or with
  `sslrootcert=system`) the chain is checked against the system roots: the
  file `SSL_CERT_FILE` names, else the operating system bundle.
- SCRAM-SHA-256-PLUS binds to the server certificate (tls-server-end-point)
  through Beryl.
- **TLS 1.3 only.** A server that offers only TLS 1.2 is refused with an
  error that names the requirement (set `ssl_min_protocol_version =
  'TLSv1.3'`, PostgreSQL 12 or later). Tested on PostgreSQL 17.12 and 19.0.
- `-Duse_openssl` keeps the OpenSSL path for one release, for servers that
  stop at TLS 1.2 and for client certificates (`sslcert`, `sslkey`), which
  the Beryl path refuses with an error that names the flag.
  `-Dwithout_openssl` is no longer needed and changes nothing.
- The driver no longer requires `http` (it needed only `URI::Params`), which
  had pulled OpenSSL in through `HTTP::Client`.
- `amber db create` and `drop` keep the TLS parameters of the database URL
  (`sslmode`, `sslrootcert`, `ssl-mode`, `ssl-ca` and the rest) on their
  connection to the maintenance database.

## 0.27.0 - 2026-11-24

Grant 0.27.0 ships its own SQLite engine, written in Crystal
(`Grant::SQLiteEngine`), as an opt-in. An app that requires
`grant/adapter/sqlite/grant_engine` instead of `grant/adapter/sqlite` runs
every statement on the engine and links no C SQLite library, with no build
flag. Its database files are ordinary SQLite files: they open in the
`sqlite3` tool and pass `PRAGMA integrity_check`, and files the C library
wrote open in Grant. Apps that keep `require "grant/adapter/sqlite"` are
unchanged: the C library stays the default, and
`Grant.settings.sqlite_engine = :grant` moves them onto the engine.

Minimum Crystal: 1.19.0

### Grant's SQLite engine

Added:

- `Grant::SQLiteEngine`: the SQLite file format (reader, b-tree writer,
  rollback journal, WAL with C SQLite's `-shm` layout and locks, so engine
  and C processes can share a database), a parser for the SQL Grant, micrate
  and the Amber CLI emit, a planner and executor with SQLite 3.51.0's
  results, column names, error messages and result codes. Grant's whole
  SQLite suite passes on it.
- `require "grant/adapter/sqlite/grant_engine"`: the SQLite adapter on the
  engine alone. The program links no libsqlite3 and
  `Grant.settings.sqlite_engine` starts at `:grant`; `:libsqlite3` is refused
  with a message naming the require to add. `require
  "grant/adapter/sqlite/libsqlite3"` is the two-engine adapter under an
  explicit name. `-Dgrant_without_libsqlite3` still works.
- `Grant.settings.sqlite_engine` (`:libsqlite3` or `:grant`).
- SQL the engine now runs as C SQLite 3.51.0 does, each checked by a
  seeded random comparison with C: VIRTUAL generated columns (read, written,
  indexed, altered; 3,000 random tables, 0 differences); the date and time
  functions (`date`, `time`, `datetime`, `julianday`, `unixepoch`,
  `strftime`, `timediff`, every modifier; 500,000 calls, 0 differences); the
  JSON builders, editors and aggregates (`json_array`, `json_object`,
  `json_set`/`insert`/`replace`/`remove`, `json_patch`, `json_group_array`,
  `json_group_object`, the `jsonb_` forms; 150,000 statements, 0
  differences); `ANALYZE`, `sqlite_stat1`, `PRAGMA analysis_limit` and
  `PRAGMA optimize`; the backup API (`Connection#dump`) between any pair of
  engines and `VACUUM INTO`; `PRAGMA foreign_key_check`, `auto_vacuum`,
  `incremental_vacuum` and the `pragma_*` table-valued forms;
  `PRAGMA fullfsync` and `checkpoint_fullfsync` (F_FULLFSYNC on macOS).
- `scripts/check_sqlite3_linkage.rb` builds the default app workload on
  `grant_engine` with no flags and with the flag, and a control that must link
  libsqlite3.
- `scripts/sqlite_engine_durability_soak.cr`: a resumable multi-day soak
  (engine and C processes, kills, checkpoints, every acknowledged commit
  verified, `integrity_check` in `/usr/bin/sqlite3`).

Left out (each raises `Grant::SQLiteEngine::UnsupportedSQL` naming it):
window functions, RIGHT and FULL joins, `CREATE TABLE ... AS SELECT`,
triggers, virtual tables, `load_extension`.

Speed against libsqlite3 3.51.0 on the same machine: reads 1.03x to 4.5x as
fast; every query workload and WAL-mode model writes at least as fast.

Fixed (engine):

- A deferred transaction's first write waits out `busy_timeout` in WAL mode
  while another process holds the write lock, as C does; it used to fail at
  once with `database is locked`.
- Rollback-journal `synchronous` handling and journal headers with
  `journal_mode=OFF` match C.

Known differences from C SQLite (results are the same unless stated):

- Opening a read-only database file fails with code 14; C opens it read-only. (#106)
- An all-digit text literal of 1,952+ characters stays TEXT in a NUMERIC column; C stores REAL. (#106)
- Plain VACUUM inside a transaction, and `VACUUM unknown_schema`, succeed; C refuses both. (#106)
- VACUUM INTO copies pages (free pages included); C writes a compacted file. Rows, schema and integrity are equal. (#106)
- PRAGMA synchronous=... inside a transaction is accepted; C refuses. Unusual synchronous values are stored as given. (#105)
- The directory sync after creating a journal or WAL file (UNIXFILE_DIRSYNC) is not made. (#105)
- foreign_key_check row order differs from C for schemas with more than three tables (same rows). (#102)
- date(*) with a star argument is refused; C accepts it. (#103)
- The planner does not yet read sqlite_stat1, so index choice on an ANALYZEd database follows C's default estimates (results are the same; plans may differ). Follow-up packet G6_CATALOG_B2. ANALYZE sqlite_autoindex_<t>_1 of a WITHOUT ROWID table answers 'no such table'. (#107)
- JSON subtype is lost through a scalar subquery: json_array((SELECT json('[1]'))) gives ["[1]"], C gives [[1]]. Window use of JSON aggregates and jsonb_each/jsonb_tree are refused with a named error. (#109)
- `EXPLAIN QUERY PLAN` detail text differs (display only).
- A VIRTUAL column of REAL affinity reads REAL where C may read an integer after a sorter or index read (C's MEM_IntReal). (#108)

## 0.26.0 - 2026-11-22

An app on Grant 0.26.0 can be built with `-Dwithout_openssl -Dwithout_zlib`
and, on the SQLite and PostgreSQL adapters, link neither OpenSSL nor libz:
Grant's cryptography runs on Beryl and its DEFLATE and CRC-32 on Mica, both
in Crystal, and on Apple Silicon, Linux AArch64 and x86-64 Beryl's hashes and
ciphers use the processor's own instructions, at least as fast as OpenSSL.
**Encrypted attributes are now written in format version 2
(XChaCha20-Poly1305).** Values written by earlier Grant releases are still
read and are rewritten on the next save, but Grant 0.25.1 and earlier cannot
read version 2, so roll back only before new values are written.

### Grant's cryptography runs on Beryl, and `-Dwithout_openssl` links no OpenSSL

Behavior changes:

- **Encrypted attributes are written in format version 2.** `encrypts`
  now stores `header (1 byte) | nonce (24 bytes) | ciphertext | tag (16
  bytes)`: XChaCha20-Poly1305 under a key derived from the attribute key with
  HKDF-SHA256. A deterministic attribute takes its nonce from HMAC-SHA256 of
  the plaintext, so equal plaintext still gives equal ciphertext. Values
  written by Grant up to 0.25.1 (version 1, AES-256-CBC with HMAC-SHA256) are
  still read, under the current keys and every previous key, and are rewritten
  in version 2 the next time the record is saved.
- **A lookup on a deterministic attribute matches both formats.**
  `where(email: ...)`, `where_email` and `find_by_email` compare with the
  version 2 ciphertext and with the version 1 ciphertext Grant 0.25.1 and
  earlier wrote, so rows saved before the upgrade are still found. A unique
  index on a deterministic column sees a version 1 row and a version 2 row of
  the same plaintext as different values; re-save existing rows (or
  re-encrypt with `Grant::Encryption::MigrationHelpers`) before relying on
  that index for new writes.
- **Rolling back.** Grant 0.25.1 and earlier cannot read version 2 values. Roll back only
  before new values have been written, or keep the newer Grant.
- `Grant::Encryption::Cipher::VERSION` is now `2`; `VERSION_1`,
  `payload_version` and `encrypt_in_version_1` are new, and
  `MIN_PAYLOAD_SIZE` describes version 2 (`MIN_VERSION_1_PAYLOAD_SIZE` the
  earlier one). `Cipher::ALGORITHM` is removed.

Changed:

- Attribute keys (HKDF-SHA256), signed ids, `generates_token_for` tokens, the
  replica-selector cookie, advisory-lock ids, the query-cache key and
  PostgreSQL password authentication (md5 and SCRAM-SHA-256) are computed by a
  pinned copy of [Beryl](https://github.com/amberframework/beryl) under
  `src/grant/vendor` (`Grant::Beryl`, pinned by commit and per-file sha256 in
  `BERYL_VENDORED.json`). Every output is byte-identical to what OpenSSL
  produced; `spec/grant/encryption/cipher_formats_spec.cr` holds values
  captured from Grant 0.24.0.
- OpenSSL is used only for PostgreSQL TLS (and SCRAM-SHA-256-PLUS, which
  binds to the TLS certificate). An app built with `crystal build
  -Dwithout_openssl` links neither libssl nor libcrypto on the SQLite and
  PostgreSQL adapters; in such a build `sslmode=require`, `verify-ca` and
  `verify-full` raise `Grant::PQ::ConnectionError` naming the flag, and
  `sslmode=prefer` and `allow` connect without TLS.
  `scripts/check_openssl_linkage.rb` builds the probes and checks.

### Grant links no libz in an app built with `-Dwithout_zlib`

Grant's DEFLATE and CRC-32 now run on a pinned copy of
[Mica](https://github.com/amberframework/mica), in Crystal
(`src/grant/vendor`, under `Grant::Mica`, pinned by commit and per-file
sha256 in `MICA_VENDORED.json`), in place of Crystal's `Compress::Zlib` and
`Digest::CRC32`, which call libz:

- `encrypts body, compress: true` writes and reads its zlib stream
  (RFC 1950) with Mica. Rows compressed through libz by an earlier Grant read
  back unchanged, and an earlier Grant reads rows written now. The bytes of
  a newly compressed value can differ from libz's; they sit inside the
  ciphertext, which already differs on every write.
- A stored value whose compressed bytes are cut short or damaged raises
  `Grant::Encryption::Cipher::DecryptionError` (before: an error of the
  standard library's `Compress` classes).
- Constraint names (`Grant::Schema::Naming.digest`) and fixture ids
  (`Grant::TestFixtures.identify`) use Mica's CRC-32. The values are the
  same.

`scripts/check_zlib_linkage.rb` builds probe apps with `-Dwithout_zlib` and
fails if their binaries link libz; CI runs it. Without the flag, Crystal's
own HTTP code still reaches libz in any program that requires `http`.

### Also

- The vendored copy of Mica under `src/grant/vendor` (`Grant::Mica`) moves to
  amberframework/mica `37e8b019` (amberframework/mica#29, faster Inflate),
  pinned by commit and per-file sha256 in `MICA_VENDORED.json`. Only
  the decoder (`mica/deflate/inflater.cr`) changed: it inflates the same
  bytes faster.
- The vendored copy of Beryl under `src/grant/vendor` (`Grant::Beryl`) moves from
  `6eef806d` (B2, portable code) to amberframework/beryl `7d678c08`
  (F1, amberframework/beryl#3, and F2, amberframework/beryl#4), pinned by
  commit and per-file sha256 in `BERYL_VENDORED.json`. SHA-2, HMAC, AES-GCM,
  ChaCha20-Poly1305 and XChaCha20-Poly1305 run on the processor's SHA, AES,
  carry-less multiply and vector instructions on Apple Silicon, Linux AArch64
  and x86-64, and on portable code elsewhere; Beryl measures every hash, HMAC
  and AEAD at least as fast as OpenSSL 4.1.0 on an Apple M1 Max. The bytes
  each one produces are unchanged.

Minimum Crystal: 1.19.0.

## 0.25.1 - 2026-11-22

Minimum Crystal: 1.19.0

### Every regex in Grant runs on Mica

crystal-alpha 1.21.0-incremental-6 makes Mica the default `Regex` engine.
Mica runs in linear time and leaves out lookaround, backreferences, atomic
groups and possessive quantifiers. Grant 0.25.0 still had two patterns that
use them:

- **Fix: `where` with a union of arrays compiles on a Mica-default
  compiler.** `where(id: list)` where `list` is, for example,
  `Array(Int64) | Array(Range(Int64, Int64))` roots each member type in a
  macro, and the macro ran a pattern with lookbehind, a possessive
  quantifier and a nested lookahead. The compiler runs macro regexes on its
  own engine, so the build stopped with `lookbehind is not supported by the
  Mica regex engine`, and `-Duse_pcre2` did not help. The rooting is now
  three substitutions without lookaround (`Grant::Query::TypeNameRooting`);
  on PCRE2 they give the text the old pattern gave.
- **Fix: a table rebuild no longer raises on Mica.** The check for a column
  name inside a constraint, index or trigger
  (`Grant::Schema::TableRebuild::Scanner.mentions?`) built a lookaround
  pattern at run time, which raised `Regex::UnsupportedSyntaxError` on Mica.
  It now consumes the neighboring characters instead.
- The lookahead in `RAW_JOIN_TARGET` (`src/grant/query/joins.cr`) left Grant
  in 0.24.0. An app on Grant 0.23.4 or older that uses joins does not compile
  on a Mica-default compiler; upgrade to this release.
- The specs that compare Grant's hand-written text checks with the patterns
  they replaced now build each lookaround pattern at run time: on PCRE2 the
  comparison runs over the whole fuzz corpus, and on every engine the
  hand-written code is checked against fixed examples.
- CI checks every regex in `src`, `spec`, `scripts`, `bench` and `examples`
  against Mica's dialect (`scripts/check_regex_literals.cr` from
  amberframework/mica, pinned by commit), including code no spec reaches.

No API changes.

## 0.25.0 - 2026-11-22

Minimum Crystal: 1.19.0

### Grant links no GMP by default

**BigDecimal support is now opt-in.** An app with `BigDecimal` columns adds
`require "grant/big_decimal"` above `require "grant"`:

```crystal
require "grant/big_decimal"
require "grant"
```

Without that line such an app stops at compile time with a message that names
it. An app without decimal columns needs no change and no longer links libgmp.

Behavior changes:

- **Grant's default path requires `big` nowhere**, so an app without decimal
  columns links no libgmp. Before, eight source files required `big`, and
  every app linked GMP for its memory hook alone.
  `scripts/check_gmp_linkage.rb` builds probe apps and fails if their binaries
  link GMP; CI runs it.
- **BigDecimal support is opt-in with `require "grant/big_decimal"`, before
  `require "grant"`**: `BigDecimal` columns (`precision:`, `scale:`),
  `BigDecimal` and `Array(BigDecimal)` in `Grant::Columns::Type`, `BigDecimal`
  in `Grant::Schema::DefaultLiteral` and `Grant::Query::Builder::SumValue`,
  and `sum(as: BigDecimal)`. With the require, every one behaves as in 0.24.0.
  The require comes first because those types are fixed as Grant loads; an
  app that requires `big` before `grant` has the support without the file.
  `Grant::BIG_DECIMAL_SUPPORT` is true when it is compiled in.
- **To upgrade an app that has `BigDecimal` columns**, add
  `require "grant/big_decimal"` above its `require "grant"`. Without it, a
  `BigDecimal` column, `sum(as: BigDecimal)` and a late
  `require "grant/big_decimal"` stop at compile time with a message naming
  the require.
- **Without the support, the sum of an expression or joined column** is an
  `Int64` when it is a whole number in range and a `Float64` otherwise (it was
  an `Int64` or a `BigDecimal`). Sums of integer and float columns are
  unchanged, and `sum(as: Int64)` still raises for a sum with a fraction.
- `src/grant/converters/decimal.cr` is now
  `src/grant/converters/small_integer.cr` (`Grant::Converters::SmallInteger`)
  and `src/grant/big_decimal/decimal_converter.cr`
  (`Grant::Converters::Decimal`).

Fixes:

- **A `BigDecimal` column on MySQL reads every digit.** crystal-mysql decodes
  a DECIMAL as a `Float64`, so a value past about 17 significant digits came
  back rounded. Grant now reads a DECIMAL as the exact text MySQL sends.

## 0.24.0

Minimum Crystal: 1.19.0

### Grant links no PCRE2 by default

Behavior changes:

- **Grant's default path is regex-free.** Model definition, columns,
  attributes, associations, querying, saving, validating, logging, the
  migrator and the SQLite and PostgreSQL adapters use hand-written text checks
  (`Grant::TextMatching`, `Grant::CharacterClass`), so an app built on them
  links no libpcre2. Each check accepts and rejects exactly what the regular
  expression it replaces did, including Unicode `\w`/`\d`/`\s` and
  case-insensitive folds; `spec/grant/text` compares every one with its old
  pattern. `scripts/check_pcre2_linkage.rb` builds probe apps and fails if
  their binaries link PCRE2.
- **`\w`, `\d` and `\s` follow the PCRE2 10.43+ Unicode tables on every
  platform.** This is Grant's defined semantics: `\w` is a letter, a number, a
  nonspacing mark or a connector punctuation; `\d` is a decimal digit in any
  script; `\s` is Unicode white space. The tables are checked in as
  `src/grant/text/character_class_data.cr`, so the answers do not depend on
  the system's PCRE2. On a system with an older PCRE2 (10.42 on Ubuntu 24.04,
  whose `\w` leaves out combining marks such as U+0301 and connector
  punctuation such as U+203F, and whose Unicode version is older), Grant's
  checks differ from the regular expressions they replace for text holding
  those characters. `scripts/generate_character_classes.cr` regenerates the
  tables and requires PCRE2 10.43 or later; the specs compare Grant with the
  linked PCRE2 only where it is 10.43 or later and check the tables directly
  everywhere.
- **Regex features are opt-in with `require "grant/regex"`** (after
  `require "grant"`, before the models that use it): `validates_format_of`
  (and `validates ... format:`), Regex entries in `filter_attributes` and
  `Grant.settings.filter_attributes`, the SQLite `REGEXP` operator, and the
  `CommonFormats::EMAIL_REGEX`/`URL_REGEX` constants. Without the require,
  `validates_format_of` and a Regex `filter_attributes` fail at compile time
  with a message naming it, and SQLite reports `no such function: REGEXP`.
- `validates_email` and `validates_url` no longer go through
  `validates_format_of`; they call `CommonFormats.email?`/`url?` and need no
  opt-in. Their reflection options carry `format: :email`/`:url` in place of
  the `with:` pattern.
- `Grant.settings.filter_attributes` is now an
  `Array(Grant::AttributeFilter)` (`String | Grant::AttributeNamePattern`).
  With `grant/regex`, assigning an `Array(String | Regex)` still works.
- Internal pattern constants were removed: `Grant::Logs::STDLIB_FRAME`,
  `FRAME_LOCATION`, `TABLE_AFTER`; `Grant::QueryCache::LOCKING_READ`;
  `Grant::Transaction::SAVEPOINT_NAME_PATTERN`;
  `Grant::SecurePassword::DIGEST_FORMAT`; `Grant::Locking::Clause::PATTERN`;
  `Grant::Encryption::LogFilter::COMPARISON`, `IN_LIST`, `INSERT`,
  `PLACEHOLDER`; `Grant::Query::OrderSupport::RAW_DIRECTION`;
  `Grant::Query::Builder::ORDER_TERM`; `Grant::Query::JoinSupport::RAW_JOIN_TARGET`;
  `Grant::Query::SqlExpression::COLUMN_REFERENCE`, `COLUMN_FUNCTION`;
  `Grant::Schema::MYSQL_LITERAL_DEFAULT`; `Grant::SQLite3::REGEXP_FN`.

### Fixes

- `Model.all(clause, params)` with a raw clause that carries SQL after its
  condition (`ORDER BY`, `LIMIT`, `OFFSET`, `GROUP BY`, `HAVING`) runs the
  clause as written instead of wrapping it in `where` and appending a second
  `ORDER BY` (issue #43). Words inside single-quoted literals and
  double-quoted or backtick identifiers do not count, so
  `all("WHERE title = 'LIMIT'")` still filters inside the default scope.
- `Model.all`, `first` and `sole` recognize a raw `JOIN` in any case as a
  whole word outside quoted text (they matched only uppercase `"JOIN "`
  before), so `all("join children on ...")` runs as written.
- Polymorphic and STI loaders, `Grant::AssociationLoader`, and array
  conditions in `where` root the model types they generate with `::`, so an
  app model named like a Grant type (`Connection`) resolves to the app's
  class, completing the fix of #63 (PR #72).
- `Model.migrator` compiles in an app that requires only the SQLite adapter
  (the PostgreSQL table check no longer casts `DB::Any` to `Bool`).

### PostgreSQL driver fixes

- PostgreSQL `verify-ca` and `verify-full` now verify the certificate chain, with
  `verify-full` also checking the server host name. A configured
  `sslrootcert` is the trust source; otherwise the system certificate store is
  used. `require` remains encrypted without certificate verification, and
  strict TLS modes refuse servers that decline TLS.
- PostgreSQL response parsing and value decoding failures close the affected
  connection while server `ErrorResponse` frames continue to drain through
  `ReadyForQuery`.
- PostgreSQL bound statements support up to 65,535 parameters and reject larger
  counts before writing the extended-query messages. Startup and cleartext
  password message lengths count UTF-8 bytes.

### Grant owns its Postgres and SQLite drivers

Behavior changes:

- **The PostgreSQL and SQLite drivers now live inside Grant**
  (`src/grant/drivers`, from crystal-pg 0.30.0 and crystal-sqlite3 0.23.0;
  see `PROVENANCE.md` in each directory). `crystal-db` is Grant's only
  database dependency for these two; MySQL stays on its external shard.
  `require "grant/adapter/pg"` and `require "grant/adapter/sqlite"` work as
  before, and an app may still depend on the public `pg` or `sqlite3` shard.
- Apps that name the driver's types must use the new constants:
  `PG::Numeric` becomes `Grant::PG::Numeric`, `PQ::PQError` becomes
  `Grant::PQ::PQError`, `SQLite3::Exception` becomes
  `Grant::SQLite3::Exception`.
- **Postgres statements are now named.** Each statement object parses once
  per connection and later calls send only Bind, Describe, Execute and
  Sync. `prepared_statements: false`, for connection poolers, sends every
  statement unnamed as before. A statement the server rejects at Bind
  because its copy is stale (a changed column type, `DEALLOCATE ALL`)
  re-parses and retries once outside a transaction; inside a transaction
  the error reaches the caller and the statement re-parses on its next use.
  A named statement keeps the parameter types from its first parse, so a
  column changed between types with a cast Postgres applies by itself
  (`timestamp` to `timestamptz`) reinterprets values on connections that
  already hold that statement; recycle the pool after such a migration.
- **Postgres connections to this machine no longer negotiate TLS by default.**
  A Unix socket, `localhost`, or a loopback address (127.0.0.0/8, ::1) with
  no `sslmode` in the URL now uses `sslmode=disable`; any other host keeps
  `prefer`, and an explicit `sslmode` always wins.

### Minimum Crystal version

Behavior changes:

- **Grant now requires Crystal 1.19.0 or newer** (shard.yml
  `crystal: ">= 1.19.0, < 2.0.0"`, previously `>= 1.6.0`). Grant already
  failed to compile on older Crystal because it calls `Time.instant`, added
  in Crystal 1.19.0.

  Apps on Crystal 1.6 through 1.18 must upgrade Crystal or stay on an older
  Grant release. CI now builds and runs the SQLite suite on the declared
  minimum, and checks that the minor version below it does not compile
  (`docs/RELEASING.md`).

Fixes:

- Pool parameters in a connection URL are no longer replaced by Grant's
  defaults (#65). `DATABASE_URL=postgres://...?max_pool_size=4` registered
  with `Grant::Connections <<` used to open a pool of 25, because
  `ConnectionSpec#build_pool_url` always wrote the registry's values. Each
  setting now comes from, in order: the value passed to
  `establish_connection` (or assigned to the spec), the URL, then Grant's
  default. Apps that never put pool parameters in the URL see no change.
- The `run_callbacks` macro in `src/grant/callbacks.cr` no longer puts a
  macro variable right before a macro tag (`%result{% else %}`). Parsers
  before Crystal 1.21.0 (crystal-lang/crystal#16879) rejected that with
  `unexpected token: "SPACE"`, so Grant compiled only on 1.21. The expansion
  is unchanged.
- The first `save` in a generated Amber V2 app no longer crashes with
  `Invalid memory access ... at address 0x10`. Each model class had its own
  copy of the replica-lag tracker mutex, declared in `macro included`. When a
  model is first built in an instance variable initializer (`@pet = Pet.new`
  in a scaffold controller), Crystal creates the model's copy of each
  inherited class variable before it reads class variable initializers, and
  that copy is never initialized. The tracker registry, its mutex and
  `replica_lag_threshold` now live on `Grant::ConnectionManagement`, one set
  for every model, still kept per model and database/shard. The same flaw
  dropped a `default_scope` on a subclass of the declaring model and could
  zero other inherited class-level settings, so `_has_default_scope?`,
  `multitenant_column` and the association metadata are now methods, and
  `attribute_definitions`, `token_for_definitions`, `lock_optimistically`,
  the aggregation metadata and the encrypted-attribute registry start as `nil`
  and are built on first use.

### ActiveRecord parity, wave 6b: performance and schema

Parity moves from 370 to 382 complete features (89.8% to 92.7% of applicable).
Two performance batches undo most of the cost the parity work added, and
three batches close schema, type, logging and MySQL gaps.

- **Runtime:** rows hydrate by ordinal through a column plan built once per
  result set. Find by primary key reuses a kept statement. Dirty tracking is
  lazy, so a record that is never changed allocates no tracking hashes. On
  SQLite (`bench/lifecycle_bench.cr`, 2,000 records), heap per operation is
  now below the pre-parity release (origin/main):
  - find: 1.6 KB, against 5.2 KB;
  - 100-row page: 27 KB, against 60 KB;
  - load of 2,000 rows: 1.29 MB, against 3.40 MB.

  Mean time is lower too (find 4.0 µs against 5.4 µs; load 1.13 ms against
  2.46 ms).
- **Fewer statements:** a create runs BEGIN, INSERT, COMMIT. SQLite reads the
  new id from the insert result instead of running
  `SELECT LAST_INSERT_ROWID()`. A clean save runs no SQL.
- **Compile memory:** association preloading is reachable only from
  `includes`, `preload`, `eager_load` and `Grant::Preloader`. Association
  writers are per-model methods reached only from mass assignment. WHERE
  predicates render through one model-independent renderer. Inherited
  scoping no longer instantiates per pair of models. Two measurements:
  - 200 associated models with one query: 13.4 GB to 1.7 GB of semantic
    compile memory;
  - `association_regressions_spec.cr` debug build: 9.7 GB to 6.9 GB.

  `docs/compile_memory.md` has the method and the remaining targets.
- **Schema and types:** BigDecimal columns (`precision:`, `scale:`), Int8,
  Int16 and Bytes columns, and `limit:` on integer columns. Opt-in
  `constraint:` on `belongs_to` and `validates_uniqueness_of` makes
  `Model.migrator.create` emit FOREIGN KEY and UNIQUE.
  `Grant::Schema::TypeCatalog` is new.
- **PostgreSQL arrays and JSON:** `Array(Time)` columns,
  `where.array_length`, `array_append_all`/`array_remove_all` and GIN index
  helpers. `store_accessor` on JSON columns, `type: :jsonb`, and the
  `where(data: {a: 1})` containment shorthand.
- **Encryption:** `encrypts ..., lazy: true` decrypts on first read.
- **Query logs:** raw `exec`/`query`/`scalar`, counters,
  `insert_all`/`upsert_all` and the cache-version query are tagged. Verbose
  logs label writes by model.
- **Migrations:** on SQLite, `change_column_default` and NOT NULL
  `add_timestamps` rebuild the table. `ar_internal_metadata` protects
  `drop_and_create`. Schema-qualified names work across all three databases.
  MySQL catalog reads are fixed, and advisory locks, migrations and
  introspection are verified against a live MySQL 9.2 server.

Not met:
- `bench/relation_chain.cr` is 2.57x (target 1.5x).
- The compile-memory slope is 19.5 MB per queried model (target 7.7).
- The one-model debug build needs 1.8 GB (target 1.3 GB).

Behavior changes:

- Per-record write logs ("Record created", "Record updated", "Record
  destroyed", "Columns updated") are logged at debug instead of info.
- A save sends BEGIN with its first statement; a save that runs no
  statement publishes no transaction events.
- Calling `Grant::AssociationLoader.load_associations` or `batch_load`
  directly on a model never loaded through
  `includes`/`preload`/`eager_load` raises `Grant::PreloadNotEnabledError`;
  call `Grant::AssociationLoader.enable(Model)` first.
- `Grant::Columns::Type` gains BigDecimal, Int8, Int16, `Array(BigDecimal)`
  and `Array(Time)`; `DirtyValue` gains `Array(Time)`.
- Int32/Int64 columns with `limit:` read through
  `Grant::Converters::SmallInteger`. A PostgreSQL DSL `integer limit:`
  outside 1..8 raises `InvalidDefinition`.
- JSON::Any columns are always watched for in-place mutation.
- A column `type:` other than `:jsonb` on a JSON::Any column is a compile
  error.
- Raw `Model.exec`/`query`/`scalar` and `Grant.connection` calls write the
  SQL log entry at debug.
- Verbose log labels for adapter writes use the model name instead of the
  table name.
- `Schema::ColumnInfo#default` on MySQL is SQL text: string and temporal
  literals come back quoted.
- On SQLite, `change_column_default` and NOT NULL `add_timestamps` rebuild
  the table instead of raising `UnsupportedOperation`.
- `Model.migrator.drop_and_create` raises
  `Grant::Schema::ProtectedEnvironmentError` in a recorded protected
  environment unless `force: true`.
- `where(json_column: {...})` raises `ArgumentError` for a value with no
  JSON form instead of failing to compile. A custom type must include
  `JSON::Serializable` to be used there (`json_contains` still accepts any
  `to_json`).
- MySQL `change_column` keeps the current default, and
  `CURRENT_TIMESTAMP` defaults on `DATETIME(n)` render
  `CURRENT_TIMESTAMP(n)`.

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
