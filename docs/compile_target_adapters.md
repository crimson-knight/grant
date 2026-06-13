# Compile-Target Adapters

Grant can compile the **same model classes** for different deployment targets —
a mobile app, a desktop app, and a web server — choosing a single database
adapter (and even a different *column set*) per target, entirely at compile time.

This is something an ActiveRecord-style ORM on a dynamic runtime cannot do.
Crystal's compile-time macros let Grant include exactly one adapter per binary
and compile unused columns out completely, at zero runtime cost.

## The design decision

> **A Grant model is compiled for exactly one database adapter per build target.
> The adapter is chosen at compile time by a target flag. Targets may share an
> adapter (iOS and desktop both use SQLite); the web target uses Postgres or
> MySQL. A single binary never links more than one adapter it doesn't use.**

Why:

- A mobile/desktop binary that ships Postgres/MySQL client code is bloated and,
  for iOS/watchOS, may not even link. Opt-in adapters keep each target lean.
- The *same model classes* are shared across targets in a monorepo. Only the
  adapter binding — and, optionally, the per-target column set (see below) —
  differs per target.

### Why NOT device → cloud-DB direct

Grant **deliberately does not support a device talking to a remote Postgres or
MySQL directly.** A device uses SQLite locally and **synchronizes to the server
through the API layer**; the server owns the Postgres/MySQL connection.

```
  ┌──────────┐        ┌─────────┐        ┌──────────────┐
  │  Device  │  HTTP  │   API   │  SQL   │  Postgres /  │
  │  SQLite  │ ─────▶ │  layer  │ ─────▶ │   MySQL DB   │
  └──────────┘        └─────────┘        └──────────────┘
   local cache       integrity &          server-owned
   (per-target        permission           connection
    columns)          boundary
```

"Cutting out the middleman" (device → cloud DB) is rejected **on purpose**:

- It leaks database credentials onto the device.
- It couples your database schema to every client version in the wild.
- It defeats the API as the integrity, validation, and permission boundary.

This is a feature, not a limitation. The device gets a fast local SQLite store;
the server keeps a single, trusted, schema-owning connection.

> Out of scope here: the sync *protocol* itself (conflict resolution, change
> feeds). This document makes the schema/adapter side multi-target-ready and
> defines the boundary; the sync engine is a separate effort.

## Target flags

Three semantic **target** flags, set with `crystal build -Dgrant_target_<x>`
(mutually exclusive by convention):

| Target flag            | Typical adapter |
|------------------------|-----------------|
| `grant_target_mobile`  | SQLite          |
| `grant_target_desktop` | SQLite          |
| `grant_target_web`     | Postgres/MySQL  |

Three **adapter-presence** flags gate the actual driver linkage and populate
`Grant.compiled_adapters`:

| Presence flag  | Adapter               |
|----------------|-----------------------|
| `grant_sqlite` | `Grant::Adapter::Sqlite` |
| `grant_pg`     | `Grant::Adapter::Pg`     |
| `grant_mysql`  | `Grant::Adapter::Mysql`  |

Targets → adapters is a convention your app expresses once (mobile/desktop →
sqlite, web → pg/mysql). Keeping *both* layers lets a power user override — for
example a desktop build that talks to Postgres.

### Build commands

```bash
# Mobile (SQLite)
crystal build src/app.cr -Dgrant_target_mobile -Dgrant_sqlite

# Desktop (SQLite)
crystal build src/app.cr -Dgrant_target_desktop -Dgrant_sqlite

# Web (Postgres)
crystal build src/app.cr -Dgrant_target_web -Dgrant_pg

# Web (MySQL)
crystal build src/app.cr -Dgrant_target_web -Dgrant_mysql
```

`Grant.compiled_adapters` and `Grant.active_targets` report what was compiled in,
for diagnostics:

```crystal
Grant.compiled_adapters # => ["sqlite"]  (under -Dgrant_sqlite)
Grant.active_targets    # => ["grant_target_mobile"]
Grant.target?(:mobile)  # => true
```

## The `configure_target` DSL

Call `Grant.configure_target` **once** in your boot/config file. It expands to
top-level, flag-guarded `require`s of the one adapter the active target needs,
plus the connection registration. Because `require` is top-level only, the macro
emits the `require` at the top level (not nested in a method).

```crystal
# config/database.cr — compiled per target
require "grant"

Grant.configure_target do
  mobile_or_desktop do            # emitted under grant_target_mobile OR _desktop
    use Grant::Adapter::Sqlite
    primary url_provider: -> { "sqlite3://#{Device.app_support_dir}/app.db" }
  end

  web do                          # emitted under grant_target_web
    use Grant::Adapter::Pg
    primary url: ENV["DATABASE_URL"]
    replica url: ENV["DATABASE_REPLICA_URL"]   # optional reader role
  end
end
```

Group names: `mobile`, `desktop`, `mobile_or_desktop`, `web`. Inside each group:

- `use <Adapter>` — required; picks the adapter shard to `require` and register.
- `primary` / `writer` — registers the writer/primary role on the `"primary"`
  database.
- `replica` / `reader` — registers a `:reading` role on the `"primary"` database.
- any other name (e.g. `analytics`) — registers that *named* database.

Each role takes either `url:` (eager) **or** `url_provider:` (lazy — see below).

### Hand-rolled fallback (always works, no macro)

The macro is only organizational sugar. The exact pattern it expands to is fully
supported by hand, and is the recommended fallback when you want full control:

```crystal
{% if flag?(:grant_target_mobile) || flag?(:grant_target_desktop) %}
  require "grant/adapter/sqlite"
  Grant::ConnectionRegistry.establish_connection(
    database: "primary",
    adapter: Grant::Adapter::Sqlite,
    url_provider: -> { "sqlite3://#{Device.app_support_dir}/app.db" })
{% elsif flag?(:grant_target_web) %}
  require "grant/adapter/pg"
  Grant::ConnectionRegistry.establish_connection(
    database: "primary",
    adapter: Grant::Adapter::Pg,
    url: ENV["DATABASE_URL"])
{% end %}
```

## Lazy URL providers

Device targets often don't know their database path at boot — it lives in an
OS-provided directory only resolved after the app starts. Pass a
`url_provider : -> String` instead of an eager `url`:

```crystal
Grant::ConnectionRegistry.establish_connection(
  database: "primary",
  adapter: Grant::Adapter::Sqlite,
  url_provider: -> { "sqlite3://#{Device.app_support_dir}/app.db" })
```

Semantics:

- The provider is **not** invoked at registration.
- It runs **exactly once**, on the first pool build (i.e. when a query first
  checks out this connection), and the resolved URL is memoized.
- The eager `url : String` overload is unchanged and still works.

`establish_connections` also accepts lazy providers via `url_provider:`,
`writer_provider:`, and `reader_provider:` keys.

## Per-target columns

Add a `targets:` argument to `column` to restrict it to one or more build
targets. When the active `grant_target_*` flag is **not** in the list, the column
— its ivar, getter/setter, dirty tracking, (de)serialization, and inclusion in
`fields` / `INSERT` / `UPDATE` / `SELECT *` — is **compiled out entirely**. It
does not exist on that target, at zero runtime cost.

```crystal
class User < Grant::Base
  column id : Int64, primary: true                       # all targets (shared)
  column email : String                                  # all targets (shared)
  column password_digest : String, targets: [:web]       # server-only
  column push_token : String?, targets: [:mobile]        # device-only
  column avatar_cache : Bytes?, targets: [:mobile, :desktop]
end
```

Rules:

- **No `targets:` ⇒ present on every target.** These are the **shared sync
  columns** — the columns that participate in automatic row sync.
- A gated column is absent from `fields` on other targets; the assembler never
  references it, and the per-target SQL schema reflects the subset.
- **The primary key (and any sync-key columns) must be shared.** Gating a
  `primary: true` column is a **compile error** — sync requires a stable key on
  every side:

  ```
  Error: The primary key column User#id cannot be gated with `targets:`.
         Primary and sync-key columns must be present on every build target.
  ```

- Composes with `include Grant::STI`, `attr_readonly`, encryption, and the
  abstract-base JSON/YAML serialization fix (#41). A gated column on an STI
  subclass round-trips correctly on its own target and is simply absent on
  others.

### Worked mobile ↔ web sync example

```crystal
class User < Grant::Base
  column id : Int64, primary: true                  # shared — the sync key
  column email : String                             # shared — auto-syncs
  column display_name : String?                     # shared — auto-syncs
  column password_digest : String, targets: [:web]  # server-only
  column push_token : String?, targets: [:mobile]   # device-only
end
```

Compiled for **web** (`-Dgrant_target_web`), the model has:
`id, email, display_name, password_digest`. No `push_token` — it does not exist.

Compiled for **mobile** (`-Dgrant_target_mobile`), the model has:
`id, email, display_name, push_token`. No `password_digest` — it does not exist.

**The sync rule:** *only shared columns participate in automatic row sync; gated
columns are handled by explicit API endpoints.*

- `id`, `email`, `display_name` are shared → they flow both directions in the
  normal row-sync payload. The sync layer (the API boundary) tolerates each side
  having extra columns the other lacks, because it only ever maps the shared
  set.
- `password_digest` is **server-only**. It never travels to the device — it is
  not in the device's model at all, so it cannot leak. The server sets it from a
  dedicated "set password" API endpoint.
- `push_token` is **device-only**. It is *not* blanket-synced up with the row;
  the device pushes it explicitly via a `PUT /me/push_token` endpoint. The
  server stores it however it likes (a separate table, a column on its own
  `User`, etc.), decoupled from the device schema.

This keeps the device's local store lean, keeps secrets server-side, and keeps
the API — not the database — as the contract between client and server.

## The guard rail: `AdapterNotAvailableError`

If a model resolves an adapter for a connection that was never established — for
example the active target didn't register `"primary"`, or the matching adapter
shard wasn't compiled in — Grant raises `Grant::AdapterNotAvailableError` with a
message that names the connection, the active `grant_target_*` flag(s), the
adapters that *were* compiled in, and the registered connections:

```
No database adapter is available for connection 'primary' (role: primary, key: primary:primary).
  Active build target(s): grant_target_mobile
  Adapters compiled in:   sqlite
  Registered connections: none
Fix: ensure this target establishes the 'primary' connection (e.g. via
Grant.configure_target or ConnectionRegistry.establish_connection) and that the
matching adapter is compiled in (require "grant/adapter/<name>" under the correct
grant_target_* / grant_<name> flag).
```

How to fix it:

1. Make sure this target's config establishes the connection the model uses —
   either through `Grant.configure_target` or a direct
   `Grant::ConnectionRegistry.establish_connection`.
2. Make sure the matching adapter is compiled in: `require "grant/adapter/<name>"`
   (or the `use <Adapter>` line in `configure_target`) under the right
   `grant_target_*` / `grant_<name>` flags.
```
