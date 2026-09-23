# PostgreSQL Schema-per-tenant

Grant supports PostgreSQL schema-per-tenant applications that need to keep
their existing Apartment-style data layout. Each request runs against one
tenant schema, with `public` available for global tables.

## Quick start

Declare ordinary models as usual. Mark models that always live in `public`
with `schema_tenant_excluded`:

```crystal
class Invoice < Grant::Base
  connection "primary"
  table invoices

  column id : Int64, primary: true
  column number : String
end

class Country < Grant::Base
  connection "primary"
  table countries

  column id : Int64, primary: true
  column code : String
  column display_name : String

  schema_tenant_excluded
end
```

Create each tenant schema and its model tables, then scope request work with a
block:

```crystal
Grant::SchemaTenant.create_schema("acme")
Grant::SchemaTenant.create_tables("acme", Invoice)

Grant::SchemaTenant.with("acme") do
  Invoice.create!(number: "INV-100")
  Country.where(code: "US").first
end
```

`create_tables` calls each model's current `migrator.create`. Create excluded
models' `public` tables once with their migrator, outside the per-tenant list.
Schema names must be 1-63 ASCII identifier characters, cannot be `public`, and
cannot begin with PostgreSQL's reserved `pg_` prefix. They are quoted as SQL
identifiers before use.

If an application has multiple database connections, pass the tenant adapter
explicitly:

```crystal
Grant::SchemaTenant.with("acme", adapter: Invoice.adapter) do
  Invoice.all.each { |invoice| deliver(invoice) }
end
```

One schema block is pinned to one adapter. Grant raises
`SchemaTenantConnectionMismatchError` if a model resolves to a different
connection during that block. PostgreSQL is the only supported adapter for
schema tenancy; other adapters raise `UnsupportedSchemaTenantAdapterError`.

## How connection pinning works

PostgreSQL stores `search_path` on the physical connection. Grant checks one
connection out when the outer `SchemaTenant.with` starts (or reuses an open
Grant transaction's connection), issues a quoted
`SET search_path TO "acme", public`, and records the connection in a
fiber-local context. Grant's adapter open path checks that context for reads,
writes, calculations, eager loads, and streaming queries, so those statements
all use the pinned connection.

Transactions start and finish on that same connection. Nested schema switches
set the inner path on it and restore the outer path when they return. A nested
`requires_new: true` transaction uses a savepoint while schema tenancy owns the
connection; a separately committed transaction on another connection would
not preserve the scoped search path.

The outer block issues `RESET search_path` in an ensure path before its
connection lease ends, including when the block or a transaction raises. If
PostgreSQL cannot reset it, Grant closes the connection so the pool cannot
reuse it with unknown session state, and raises `SchemaTenantResetError`.
Concurrent fibers have independent contexts and pinned connections.

The tenant schema is first in the path and `public` is second. Models declared
with `schema_tenant_excluded` use `public.<table>` in Grant-generated SQL,
including the model's CRUD and migrator operations. Raw SQL that names tables
directly must still qualify global tables with `public.`.

## Apartment API mapping

| Apartment (Rails) | Grant |
| --- | --- |
| `Apartment::Tenant.switch("acme") { ... }` | `Grant::SchemaTenant.with("acme") { ... }` |
| `Apartment::Tenant.switch!` | Use a request or job block with `SchemaTenant.with`; Grant intentionally scopes the connection for a bounded block. |
| `Apartment::Tenant.current` | `Grant::SchemaTenant.current_schema` inside a scoped block. |
| Subdomain elevator | An `HTTP::Handler` that resolves a validated subdomain and wraps `call_next` in `SchemaTenant.with`; example below. |
| `config.excluded_models` | Add `schema_tenant_excluded` to each global Grant model. |
| `Apartment::Tenant.create("acme")` | `Grant::SchemaTenant.create_schema("acme")`, followed by `create_tables`. |
| `Apartment::Tenant.drop("acme")` | `Grant::SchemaTenant.drop_schema("acme", cascade: true)` when tenant objects should also be removed. |
| `Apartment.tenant_names` | `Grant::SchemaTenant.list_schemas`. |
| Apartment migrations across tenants | For each tenant, call `SchemaTenant.create_tables(schema, ModelA, ModelB)` or run each model's `migrator` inside `SchemaTenant.with(schema)`. |

`SchemaTenant.with` provides scoped switching; there is no fiber-persistent
`switch!` equivalent. This keeps connection ownership visible and ensures
search_path cleanup at the end of each unit of work.

## Amber subdomain pipe example

Grant does not depend on Amber or `HTTP::Server`; keep this handler in the web
application. It uses Crystal's standard `HTTP::Handler` interface:

```crystal
require "http/server/handler"

class TenantSchemaHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    host_header = context.request.headers["Host"]?
    unless host_header
      context.response.respond_with_status(:bad_request)
      return
    end

    host = host_header.split(':', 2).first
    labels = host.split('.')
    if labels.size < 3
      context.response.respond_with_status(:bad_request)
      return
    end

    schema = labels.first
    Grant::SchemaTenant.with(schema) do
      call_next(context)
    end
  rescue Grant::InvalidSchemaNameError
    context.response.respond_with_status(:bad_request)
  end
end
```

Add the handler to the Amber pipeline covering tenant routes, before their
controllers:

```crystal
pipeline :web do
  plug TenantSchemaHandler.new
end
```

In a production app, check the host against your configured application
domains, resolve the subdomain to a known tenant, and authorize that tenant
before entering the schema. Identifier validation prevents SQL identifier
injection; it does not decide whether a hostname belongs to your application.

## Choosing schema tenancy or row tenancy

Choose schema tenancy when tenants already have identical tables in separate
PostgreSQL schemas, need schema-level backup or restore boundaries, or are
migrating from Apartment without first moving their data. It carries per-tenant
DDL and migration work, consumes a pool connection for each active scoped
fiber, and depends on PostgreSQL's `search_path` behavior.

Choose row tenancy when the application can keep all tenants' records in shared
tables with a `tenant_id` column. Grant's row mode uses `multitenant
:tenant_id` and `Grant::Tenant.with(id)`. It usually makes cross-tenant
reporting, shared indexes, and one-time schema migrations simpler, but requires
moving existing rows and enforcing tenant scoping in the application.

## Moving from schemas to row tenancy

The basic SQL pattern is to add `tenant_id` to shared tables and copy each
tenant's rows into them. Plan foreign-key and primary-key remapping before the
copy. Two tenants can both have `id = 1`, so a serial or integer key cannot be
copied unchanged into one shared table. The example below builds a per-tenant
ID map using the destination sequence, then uses that map for dependent rows:

```sql
ALTER TABLE public.accounts ADD COLUMN tenant_id text;
CREATE TEMP TABLE account_id_map (
  tenant_id text NOT NULL,
  old_id bigint NOT NULL,
  new_id bigint NOT NULL,
  PRIMARY KEY (tenant_id, old_id)
);

-- Repeat for each source schema, substituting its schema and tenant key.
INSERT INTO account_id_map (tenant_id, old_id, new_id)
SELECT 'acme', source.id, nextval('public.accounts_id_seq')
FROM acme.accounts AS source;

INSERT INTO public.accounts (id, tenant_id, email)
SELECT id_map.new_id, id_map.tenant_id, source.email
FROM acme.accounts AS source
JOIN account_id_map AS id_map
  ON id_map.tenant_id = 'acme' AND id_map.old_id = source.id;
```

For a child table with `account_id`, join its source rows to
`account_id_map` on the tenant key and old account ID, then insert
`account_id_map.new_id` as the shared foreign key. Build an equivalent map for
each table whose primary keys collide. After copying all tenants, set
`tenant_id` to `NOT NULL`, add tenant-aware unique constraints and indexes,
advance sequences if needed, and verify row counts and foreign keys before
changing application traffic. Keep a backup and a repeatable rollback plan.

An alternative is to convert colliding primary and foreign keys to UUIDs and
assign a new UUID to each old row, still recording an old-to-new map for every
referenced table. Do not preserve integer IDs across schemas unless they are
known to be globally unique.

After the copy, add the tenant column to the Grant models and declare
`multitenant :tenant_id`. Switch requests to `Grant::Tenant.with(tenant_id)`
only after the new data and constraints have been verified.

## Limits

- PostgreSQL only; MySQL and SQLite schema switching are unsupported.
- One schema-tenant block uses one adapter and holds one pool connection until
  it exits. Size the pool for active request and job concurrency.
- Nested tenant work is supported on the same database connection. Work that
  resolves to another database adapter is rejected inside the block.
- Grant's migrator creates or drops individual model tables; it is not a
  versioned migration runner like Rails. Applications must orchestrate their
  DDL across existing tenant schemas.
- Global model SQL generated by Grant is qualified with `public`. Custom SQL,
  custom `select_statement` strings, and manually written joins must qualify
  global tables themselves.
- Database permissions still matter. Give the application role access only to
  the tenant schemas it should use, and avoid allowing tenant users to create
  objects in `public`.
