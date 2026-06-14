# Compile-Target Adapters

Grant can compile the **same model classes** for different deployment targets —
a mobile app, a desktop app, and a web server — choosing a single database
adapter (and even a different *column set*) per target, entirely at compile time.

This is something an ActiveRecord-style ORM on a dynamic runtime cannot do.
Crystal's compile-time macros let Grant include exactly one adapter per binary
and compile unused columns out completely, at zero runtime cost.

The whole mechanism is **idiomatic Crystal**: plain `require`s plus, for
monorepos, the native `shard.yml` `targets:`. **There are no `-D` flags and no
DSL macro.** Single-target apps need *zero* target machinery.

## TL;DR

| You want…                                          | Do this                                                                 |
|----------------------------------------------------|-------------------------------------------------------------------------|
| One app, one database                              | `require "grant/adapter/<name>"`. Nothing else. (No target machinery.)   |
| Per-target *columns* (a column only on some builds)| `require "grant/target/<name>"` **before your models**, then `targets:` on the column. |
| One repo, several build variants (mobile/desktop/web) | `shard.yml` `targets:`, one `main:` entrypoint per variant.            |

> **Note on the require paths.** `require "grant/adapter/<name>"` and
> `require "grant/target/<name>"` resolve to `lib/grant/src/adapter/<name>.cr`
> and `lib/grant/src/target/<name>.cr` respectively (Crystal maps
> `require "grant/X"` → `lib/grant/src/X.cr`) — they are public, consumer-facing
> paths even though they don't repeat `grant/` in the on-disk layout.

## The design decision

> **A Grant model is compiled for exactly one database adapter per build target.
> The adapter is chosen by which adapter you `require`. Targets may share an
> adapter (mobile and desktop both use SQLite); the web target uses Postgres or
> MySQL. A single binary never links an adapter it doesn't use.**

Why:

- A mobile/desktop binary that ships Postgres/MySQL client code is bloated and,
  for iOS/watchOS, may not even link. `require`-only adapters keep each target
  lean.
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

## 1. Single-target apps: just require an adapter

If your app talks to exactly one database, there is **nothing to configure**.
Require the adapter you need and define your models. No flags, no target file,
no DSL:

```crystal
# src/app.cr
require "grant"
require "grant/adapter/pg" # ← adapter selection IS this require

Grant::ConnectionRegistry.establish_connection(
  database: "primary",
  adapter: Grant::Adapter::Pg,
  url: ENV["DATABASE_URL"])

class User < Grant::Base
  connection "primary"
  table users
  column id : Int64, primary: true
  column email : String
end
```

`require "grant/adapter/<name>"` maps to the adapter shards Grant ships:

| Require                        | Adapter class           |
|--------------------------------|-------------------------|
| `require "grant/adapter/sqlite"` | `Grant::Adapter::Sqlite` |
| `require "grant/adapter/pg"`     | `Grant::Adapter::Pg`     |
| `require "grant/adapter/mysql"`  | `Grant::Adapter::Mysql`  |

`Grant.compiled_adapters` reports which adapter classes were required, for
diagnostics:

```crystal
Grant.compiled_adapters # => ["pg"]   (after require "grant/adapter/pg")
```

## 2. Monorepos: one `shard.yml` target per build variant

For an app that ships several binaries from one repo — a mobile build, a desktop
build, a web build — use Crystal's **native** `shard.yml` `targets:`. Each target
is one `main:` entrypoint that requires the adapter (and, if you gate columns,
the target file) it needs:

```yaml
# shard.yml
name: my_app

targets:
  mobile:
    main: src/entrypoints/mobile.cr
  desktop:
    main: src/entrypoints/desktop.cr
  web:
    main: src/entrypoints/web.cr
```

```crystal
# src/entrypoints/mobile.cr
require "grant"
require "grant/adapter/sqlite"   # mobile → SQLite
require "grant/target/mobile"    # selects the :mobile column set (see §3)
require "../models"              # the SHARED models — expand under :mobile
require "../boot"                # establish_connection, run the app
```

```crystal
# src/entrypoints/web.cr
require "grant"
require "grant/adapter/pg"        # web → Postgres
require "grant/target/web"        # selects the :web column set
require "../models"               # the SAME shared models — expand under :web
require "../boot"
```

```crystal
# src/entrypoints/desktop.cr
require "grant"
require "grant/adapter/sqlite"    # desktop → SQLite (shares the adapter with mobile)
require "grant/target/desktop"
require "../models"
require "../boot"
```

Build a variant with the standard Crystal toolchain — no flags:

```bash
shards build mobile      # → bin/mobile
shards build web         # → bin/web
shards build desktop     # → bin/desktop
```

`src/models.cr` (the shared models) is identical across every entrypoint. The
only thing that differs per build is which adapter and which `grant/target/*`
file the entrypoint requires **before** it.

## 3. Per-target columns

A `column` can be restricted to one or more build targets with `targets:`. On a
build whose target is **not** in the list, the column — its ivar, getter/setter,
dirty tracking, (de)serialization, and inclusion in `fields` / `INSERT` /
`UPDATE` / `SELECT *` — is **compiled out entirely**. It does not exist on that
target, at zero runtime cost.

```crystal
class User < Grant::Base
  column id : Int64, primary: true                  # all targets (shared)
  column email : String                             # all targets (shared)
  column password_digest : String?, targets: [:web]       # server-only
  column push_token : String?, targets: [:mobile]         # device-only
  column avatar_cache : Bytes?, targets: [:mobile, :desktop]
end
```

### How a target is selected

The active target is a single top-level constant, `GRANT_COMPILE_TARGET`. Grant
ships three one-line files that set it:

| Require                        | Sets                            |
|--------------------------------|---------------------------------|
| `require "grant/target/mobile"`  | `GRANT_COMPILE_TARGET = :mobile`  |
| `require "grant/target/desktop"` | `GRANT_COMPILE_TARGET = :desktop` |
| `require "grant/target/web"`     | `GRANT_COMPILE_TARGET = :web`     |

**Require the target file before your models** so the constant is defined when
the `column` macro expands:

```crystal
require "grant"
require "grant/adapter/sqlite"
require "grant/target/mobile"   # ← sets GRANT_COMPILE_TARGET = :mobile
require "./models"              # ← models expand AFTER the target is set
```

The `column` macro reads the constant via Crystal's `@top_level` macro namespace
(`@top_level.has_constant?("GRANT_COMPILE_TARGET")` /
`@top_level.constant(...)`), nil-safe, and emits a gated column iff **no target
is set** *or* **the active target is in `targets:`**.

### Custom targets

You are not limited to mobile/desktop/web. To define your own target, set
`GRANT_COMPILE_TARGET` yourself — to any symbol — before requiring your models,
instead of requiring one of the shipped files:

```crystal
require "grant"
require "grant/adapter/sqlite"
GRANT_COMPILE_TARGET = :kiosk    # ← your own target
require "./models"

class Terminal < Grant::Base
  column id : Int64, primary: true
  column kiosk_pin : String?, targets: [:kiosk]   # only on the :kiosk build
end
```

### Rules

- **No `targets:` ⇒ present on every target.** These are the **shared sync
  columns** — the columns that participate in automatic row sync.
- **No target set at all ⇒ every gated column is present.** The default build
  (e.g. `crystal spec`, or a single-target app that never requires a target
  file) keeps all columns. `Grant.compile_target` is then `nil`.
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

### Diagnostics

```crystal
Grant.compile_target    # => :mobile  (or nil if no target set)
Grant.active_targets    # => ["grant_target_mobile"]  (or [] if none)
Grant.target?(:mobile)  # => true
Grant.compiled_adapters # => ["sqlite"]
```

### Worked mobile ↔ web sync example

```crystal
# src/models.cr — the SHARED models, identical across every entrypoint
class User < Grant::Base
  connection "primary"
  table users
  column id : Int64, primary: true                  # shared — the sync key
  column email : String                             # shared — auto-syncs
  column display_name : String?                     # shared — auto-syncs
  column password_digest : String?, targets: [:web]  # server-only
  column push_token : String?, targets: [:mobile]    # device-only
end
```

Compiled for **web** (`require "grant/target/web"` + `require
"grant/adapter/pg"`), the model has:
`id, email, display_name, password_digest`. No `push_token` — it does not exist.

Compiled for **mobile** (`require "grant/target/mobile"` + `require
"grant/adapter/sqlite"`), the model has:
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

## The guard rail: `AdapterNotAvailableError`

If a model resolves an adapter for a connection that was never established — for
example a build that defines models but forgot to `require` the adapter or call
`establish_connection` — Grant raises `Grant::AdapterNotAvailableError` with a
message that names the connection, the active build target, the adapters that
*were* required, and the registered connections:

```
No database adapter is available for connection 'primary' (role: primary, key: primary:primary).
  Active build target(s): grant_target_mobile
  Adapters compiled in:   sqlite
  Registered connections: none
Fix: ensure this build entrypoint establishes the 'primary' connection with
Grant::ConnectionRegistry.establish_connection, and that the matching adapter is
compiled in (require "grant/adapter/<name>").
```

How to fix it:

1. Make sure this entrypoint calls
   `Grant::ConnectionRegistry.establish_connection` for the connection the model
   uses (e.g. `"primary"`).
2. Make sure the matching adapter is required: `require "grant/adapter/<name>"`.
```
