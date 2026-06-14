# Monorepo cross-device guide (SQLite mobile + Postgres web)

This is the complete worked example: **one set of shared model classes** in a
single repository, compiled into

- a **mobile/desktop target** backed by **SQLite** (a local, on-device store), and
- a **web target** backed by **Postgres** (the server, the system of record),

with per-target columns, identical query/association/validation code on both
sides, multi-tenancy, and a clear **device → API → DB** sync boundary.

It is the practical companion to
[`compile_target_adapters.md`](compile_target_adapters.md) (the mechanism) and
[`large_tables.md`](large_tables.md) (the tenancy/scale toolkit). If you have
read neither, this guide stands on its own; read those for the deeper rationale.

> **Everything here is idiomatic Crystal: plain `require`s plus the native
> `shard.yml` `targets:`. There are no `-D` flags and no configuration DSL.**
> The adapter is chosen by which adapter you `require`; the per-target column set
> is chosen by which `grant/target/<name>` file you `require` before your models.

---

## The shape of the repo

```
my_app/
├── shard.yml                     # declares the build targets
└── src/
    ├── models.cr                 # the SHARED models — identical for every target
    ├── boot.cr                   # establish_connection + run the app (per target)
    └── entrypoints/
        ├── mobile.cr             # mobile build entrypoint  (SQLite)
        ├── desktop.cr            # desktop build entrypoint  (SQLite)
        └── web.cr                # web build entrypoint       (Postgres)
```

The single source of truth is `src/models.cr`. The three entrypoints differ
**only** in which adapter and which `grant/target/*` file they `require` before
loading the shared models.

---

## 1. `shard.yml` — one target per build variant

Crystal's native `targets:` declares each build variant as a `main:` entrypoint.
No Grant-specific machinery is involved:

```yaml
# shard.yml
name: my_app
version: 0.1.0

dependencies:
  grant:
    github: amberframework/grant
  # adapters — each build pulls in only the one it requires
  sqlite3:
    github: crystal-lang/crystal-sqlite3
  pg:
    github: will/crystal-pg

targets:
  mobile:
    main: src/entrypoints/mobile.cr
  desktop:
    main: src/entrypoints/desktop.cr
  web:
    main: src/entrypoints/web.cr
```

Build any variant with the standard toolchain — **no flags**:

```bash
shards build mobile      # → bin/mobile   (links SQLite only)
shards build desktop     # → bin/desktop  (links SQLite only)
shards build web         # → bin/web      (links Postgres only)
```

A mobile/desktop binary never links the Postgres client; the web binary never
links SQLite. Each binary is lean and, for iOS/watchOS, actually links.

---

## 2. The shared models — `src/models.cr`

These classes are **identical** across every target. They use shared columns
(present everywhere) and a few **per-target** columns (`targets:`). They are
multi-tenant. The exact same file expands under SQLite/`:mobile`, SQLite/
`:desktop`, and Postgres/`:web`.

```crystal
# src/models.cr — the SINGLE source of truth, identical for every entrypoint

class User < Grant::Base
  connection "primary"
  table users

  # ── shared columns: present on EVERY target → these participate in row sync ──
  column id : Int64, primary: true             # the sync key — MUST be shared
  column tenant_id : Int64                      # tenant discriminator (shared)
  column email : String
  column display_name : String?
  timestamps                                    # created_at / updated_at (shared)

  # ── per-target columns: compiled out where the target isn't listed ──
  column password_digest : String?, targets: [:web]      # SERVER-only (never on device)
  column push_token : String?, targets: [:mobile]        # DEVICE-only (never on server)
  column avatar_cache : Bytes?, targets: [:mobile, :desktop]  # local cache, no server copy

  # multi-tenancy: every query is auto-scoped to the current tenant, and a
  # forgotten tenant filter RAISES instead of scanning the whole table.
  multitenant :tenant_id

  has_many :todos
end

class Todo < Grant::Base
  connection "primary"
  table todos

  column id : Int64, primary: true             # shared sync key
  column tenant_id : Int64                      # shared
  column user_id : Int64                        # shared FK
  column title : String                         # shared — auto-syncs
  column done : Bool = false                    # shared — auto-syncs
  timestamps

  multitenant :tenant_id

  belongs_to :user

  validates_presence_of :title
end
```

What the gating does, per build:

| Column                | mobile (SQLite) | desktop (SQLite) | web (Postgres) |
| --------------------- | :-------------: | :--------------: | :------------: |
| `id`, `tenant_id`, `email`, `display_name`, timestamps | ✅ | ✅ | ✅ |
| `password_digest` (`targets: [:web]`)     | — | — | ✅ |
| `push_token` (`targets: [:mobile]`)       | ✅ | — | — |
| `avatar_cache` (`targets: [:mobile, :desktop]`) | ✅ | ✅ | — |

A gated-out column does **not exist** on that target — no ivar, getter, setter,
dirty tracking, (de)serialization, or `SELECT *`/`INSERT`/`UPDATE` membership.
It is compiled out at zero runtime cost. Referencing `user.push_token` in code
compiled for `:web` is a **compile error**, which is exactly the safety you want:
device-only fields can't leak into server code, and vice-versa.

> **The primary key (and any sync-key column) must be shared.** Gating a
> `primary: true` column with `targets:` is a **compile error** — sync needs a
> stable key on every side.

---

## 3. The entrypoints — adapter + target, then the shared models

Each entrypoint is a few `require`s. The order matters: **require the
`grant/target/<name>` file before the models** so `GRANT_COMPILE_TARGET` is set
when the `column` macro expands.

```crystal
# src/entrypoints/mobile.cr
require "grant"
require "grant/adapter/sqlite"   # mobile → SQLite   (adapter selection IS this require)
require "grant/target/mobile"    # selects the :mobile column set
require "../models"              # the SHARED models — expand under :mobile
require "../boot"                # establish_connection + run
```

```crystal
# src/entrypoints/desktop.cr
require "grant"
require "grant/adapter/sqlite"   # desktop → SQLite (shares the adapter with mobile)
require "grant/target/desktop"   # selects the :desktop column set
require "../models"
require "../boot"
```

```crystal
# src/entrypoints/web.cr
require "grant"
require "grant/adapter/pg"        # web → Postgres
require "grant/target/web"        # selects the :web column set
require "../models"               # the SAME shared models — expand under :web
require "../boot"
```

The `require "grant/target/<name>"` files are one-liners Grant ships; each sets
the top-level constant:

| Require                         | Sets                              |
| ------------------------------- | --------------------------------- |
| `require "grant/target/mobile"`  | `GRANT_COMPILE_TARGET = :mobile`  |
| `require "grant/target/desktop"` | `GRANT_COMPILE_TARGET = :desktop` |
| `require "grant/target/web"`     | `GRANT_COMPILE_TARGET = :web`     |

(Need a custom target? Set `GRANT_COMPILE_TARGET = :your_symbol` yourself before
requiring your models, instead of requiring one of these files.)

---

## 4. `src/boot.cr` — establish the connection per target

Each target establishes the **same connection name** (`"primary"`, matching the
`connection "primary"` in the models) but with its own adapter and URL. The
device targets typically don't know their DB path until the app has booted, so
they use the **lazy `url_provider`** form:

```crystal
# src/boot.cr (device build — SQLite)
#
# On a device the DB path is only known after the app boots (an OS-provided
# app-support directory), so pass a LAZY url_provider instead of an eager url.
# The provider runs once, on first connection checkout, and is memoized.
Grant::ConnectionRegistry.establish_connection(
  database: "primary",
  adapter: Grant::Adapter::Sqlite,
  url_provider: -> { "sqlite3://#{App.app_support_dir}/app.db" })
```

```crystal
# On the web build (Postgres), the URL is known at boot from the environment:
Grant::ConnectionRegistry.establish_connection(
  database: "primary",
  adapter: Grant::Adapter::Pg,
  url:      ENV["DATABASE_URL"])
```

(In a real repo you'd put the SQLite establish in the device entrypoints' boot
path and the Postgres establish in the web one — shown together here for
contrast. The lazy `url_provider` runs exactly once, on first connection
checkout, and is memoized.)

If a build defines models but forgets to establish the connection or require the
adapter, the first query raises `Grant::AdapterNotAvailableError` with a message
naming the connection, the active target, and the compiled-in adapters — see
[`compile_target_adapters.md`](compile_target_adapters.md#the-guard-rail-adapternotavailableerror).

---

## 5. The same code runs on every target

This is the payoff: **queries, associations, and validations are written once and
behave identically on SQLite/mobile and Postgres/web.** Grant's query builder,
association traversal, dirty tracking, and validators are adapter-agnostic — each
adapter's assembler emits the right SQL dialect underneath.

```crystal
# Identical on mobile (SQLite) and web (Postgres):

Grant::Tenant.with(current_tenant_id) do
  # create
  user = User.create!(tenant_id: current_tenant_id,
                      email: "ada@example.com",
                      display_name: "Ada")

  todo = Todo.create!(tenant_id: current_tenant_id,
                     user_id: user.id,
                     title: "Ship the app")

  # query (lazy, chainable, Enumerable) — auto-scoped to the tenant
  User.find_by(email: "ada@example.com")          # => User?
  Todo.where(done: false).order(created_at: :desc).limit(20).to_a

  # association traversal
  user.todos.where(done: false).count             # => Int
  todo.user!.display_name                          # => "Ada"

  # validation
  bad = Todo.new(tenant_id: current_tenant_id, user_id: user.id, title: "")
  bad.valid?            # => false  (validates_presence_of :title)
  bad.errors.full_messages  # => ["Title can't be blank"]
end
```

The only difference between targets is which adapter executes that SQL and which
per-target columns exist. Code that touches only shared columns is portable
verbatim. Code that touches a per-target column (`user.push_token`,
`user.password_digest`) compiles **only** on the target that owns it — by design.

### Multi-tenancy across targets

`multitenant :tenant_id` installs a `default_scope` that filters every query by
`Grant::Tenant.current!`. On a billion-row server table this prevents accidental
cross-tenant full scans (a forgotten filter **raises** `Grant::NoTenantError`
rather than scanning). On the device, where the local store holds a single
user's data, the same scope is a harmless, consistent guard — the code is
identical.

```crystal
Grant::Tenant.with(tenant_id) { Todo.where(done: false).find_each { |t| ... } }
# => WHERE tenant_id = ? AND done = ?   (on both SQLite and Postgres)

Todo.unscoped.count   # deliberate cross-tenant access — bypasses the scope
```

See [`large_tables.md`](large_tables.md) for the full tenancy + scale playbook
(keyset batching, index hints, `IN`-chunking, streaming) — all of which is the
same code on either adapter.

---

## 6. The device → API → DB boundary (read this)

**Grant deliberately does NOT let a device talk to the cloud Postgres directly.**
A device uses its local SQLite store and synchronizes **through the API layer**;
the server owns the Postgres connection. This is a feature, not a limitation.

```
  ┌──────────┐        ┌─────────┐        ┌──────────────┐
  │  Device  │  HTTP  │   API   │  SQL   │   Postgres   │
  │  SQLite  │ ─────▶ │  layer  │ ─────▶ │  (web target)│
  └──────────┘        └─────────┘        └──────────────┘
   per-target         integrity,          server-owned
   local store        validation,         connection
   (:mobile cols)     permissions
```

Why not device → cloud-DB direct:

- It would leak database credentials onto every device.
- It would couple your DB schema to every client version in the wild.
- It would defeat the API as the integrity, validation, and permission boundary.

### What syncs, and what doesn't

The rule is simple and falls straight out of the per-target columns:

> **Only shared columns participate in automatic row sync. Per-target
> (server-only / device-only) columns are handled by explicit API endpoints —
> never blanket-synced.**

For the `User` model above:

| Column            | Where it lives        | How it crosses the boundary                              |
| ----------------- | --------------------- | -------------------------------------------------------- |
| `id`, `tenant_id`, `email`, `display_name`, timestamps | **shared** | flow both directions in the normal row-sync payload; the sync layer maps only the shared set |
| `password_digest` | **web only** (`[:web]`) | **never** travels to the device — it isn't in the device's model at all, so it cannot leak. Set via a dedicated "set password" API endpoint. |
| `push_token`      | **mobile only** (`[:mobile]`) | **not** blanket-synced up with the row; the device pushes it explicitly via e.g. `PUT /me/push_token`. The server stores it however it likes, decoupled from the device schema. |
| `avatar_cache`    | **mobile/desktop only** | a purely local cache; it has no server representation and is never sent. |

Because a gated-out column does not exist on the other side's model, the sync
layer **physically cannot** map it — the type system enforces the boundary. The
shared-column set is the contract; the API endpoints handle everything else.

This keeps the device store lean, keeps secrets server-side, and keeps the
**API — not the database — as the contract** between client and server.

> Out of scope here: the sync **protocol** itself (change feeds, conflict
> resolution). This guide makes the schema/adapter side multi-target-ready and
> defines the boundary; the sync engine is a separate effort. See
> [`compile_target_adapters.md`](compile_target_adapters.md) for the same
> boundary stated from the mechanism's side.

---

## 7. Diagnostics

At runtime, introspect what was compiled in:

```crystal
Grant.compile_target     # => :mobile   (or :web / :desktop, or nil if no target set)
Grant.target?(:mobile)   # => true
Grant.compiled_adapters  # => ["sqlite"]  (or ["pg"] on the web build)
```

`Grant.compile_target` is `nil` on a build that requires no target file (e.g.
`crystal spec`, or a single-target app) — in which case **every** gated column is
present, so tests see the full schema.

---

## Checklist for a fresh app

1. `shard.yml`: declare `targets:` — one `main:` per build variant.
2. `src/models.cr`: the shared models. Mark the primary key and `tenant_id`
   shared; gate server-only / device-only columns with `targets:`.
3. Each entrypoint: `require "grant"`, the adapter, the `grant/target/<name>`
   file (**before** the models), then `require "../models"` and your boot.
4. `boot`: `establish_connection` the `"primary"` connection — eager `url:` for
   the server, lazy `url_provider:` for devices.
5. Write queries/associations/validations once; they run on both adapters.
6. Sync only shared columns through the API; handle per-target columns with
   explicit endpoints. Never device → cloud-DB direct.
