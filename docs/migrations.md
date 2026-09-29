# Migrations

Grant gives you two ways to manage schema:

- **`Model.migrator`** — a tiny built-in migrator that creates a table directly
  from your model's `column` declarations. Great for tests and quick prototypes
  (it is what the [Quick Start](quick_start.md) uses).
- **[micrate](#database-migrations-with-micrate)** — an external, versioned SQL
  migration tool. **For real applications, prefer micrate (or hand-written SQL
  migrations):** it gives you ordered up/down migrations, history, and full
  control over schema changes. `Model.migrator` only ever (re)creates the table
  shape implied by your current columns — it has no concept of versions, alters,
  indexes, or rollbacks.

## The built-in `Model.migrator`

Every model gains a class method `migrator` that returns a small migrator object
bound to that model. The migrator reads the model's `column` declarations
(names, types, nilability, `primary: true`, `column_type:` overrides,
`timestamps`) and emits a single `CREATE TABLE` matching them.

```crystal
class User < Grant::Base
  connection primary
  table users

  column id : Int64, primary: true
  column name : String
  column email : String?
  timestamps
end

User.migrator.drop_and_create   # DROP TABLE IF EXISTS users; then CREATE TABLE users (...)
```

### API

`Model.migrator(table_options = "")` returns a `Grant::Migrator::Migrator(Model)`.
Pass `table_options` to append a raw clause to the `CREATE TABLE` (e.g. a MySQL
engine/charset):

```crystal
User.migrator(table_options: "ENGINE=InnoDB DEFAULT CHARSET=utf8").create
```

The migrator object exposes:

| Method            | What it does                                                                 |
| ----------------- | --------------------------------------------------------------------------- |
| `drop_and_create` | Runs `drop` then `create` — drops the table if present, then recreates it.  |
| `create`          | Executes `CREATE TABLE` built from the model's columns.                     |
| `drop`            | Executes `DROP TABLE IF EXISTS <table>`.                                     |
| `create_sql`      | Returns the `CREATE TABLE` SQL **as a String** without executing it.        |
| `drop_sql`        | Returns the `DROP TABLE IF EXISTS <table>` SQL **as a String** (no exec).   |

```crystal
m = User.migrator

m.drop_and_create   # drop (if exists) + create, in one call
m.create            # just CREATE TABLE
m.drop              # just DROP TABLE IF EXISTS

# Inspect the SQL without touching the database:
puts m.create_sql   # => "CREATE TABLE users(...);"
puts m.drop_sql     # => "DROP TABLE IF EXISTS users;"
```

### How the table is generated

- The column marked `primary: true` becomes the `PRIMARY KEY`. For an
  auto-incrementing primary key the adapter's auto type is used (e.g.
  `BIGSERIAL` on Postgres); otherwise the column's own type is used.
- Each non-primary `column` maps to the adapter's SQL type for its Crystal type.
  Non-nilable columns get `NOT NULL`; nilable columns (`String?`) do not.
- Scalar literal column defaults (`String`, numeric, `Bool`, and `nil`) become
  SQL `DEFAULT` clauses. String defaults escape embedded apostrophes. Crystal
  expressions that are not literals remain record-side defaults because an
  arbitrary Crystal expression has no general SQL equivalent.
- A `column ... , column_type: "TEXT"` override is emitted verbatim as the SQL
  type.
- `created_at` / `updated_at` (from `timestamps`) get the adapter's timestamp
  type.
- An unsupported Crystal type for the active adapter raises at migrate time
  (`Migrator(...) doesn't support '<type>' yet.`).

### Limitations (why micrate for production)

`Model.migrator` deliberately does **one** thing — materialize the current
table shape. It does **not** create indexes or unique constraints, alter
existing tables, add/drop columns incrementally, or track migration versions,
and `drop_and_create` is destructive (it drops the table and all its data).
Use it for test setup and throwaway prototypes; use micrate or SQL migrations
(below) for anything whose schema evolves over time or holds data you care
about.

## Database Migrations with micrate

If you're using Grant to query your data, you likely want to manage your database schema as well. Migrations are a great way to do that, so let's take a look at [micrate](https://github.com/juanedi/micrate), a project to manage migrations. We'll use it as a dependency instead of a pre-build binary.

### Install

Add micrate your shards.yml

```yaml
dependencies:
  micrate:
    github: juanedi/micrate
```

Update shards

```sh
$ shards update
```

Create an executable to run the `Micrate::Cli`. For this example, we'll create `bin/micrate` in the root of our project where we're using Grant ORM. This assumes you're exporting the `DATABASE_URL` for your project and an environment variable instead of using a `database.yml`.

```crystal
#! /usr/bin/env crystal
#
# To build a standalone command line client, require the
# driver you wish to use and use `Micrate::Cli`.
#

require "micrate"
require "pg"

Micrate::DB.connection_url = ENV["DATABASE_URL"]
Micrate::Cli.run
```

Make it executable:

```sh
$ chmod +x bin/micrate
```

We should now be able to run micrate commands.

`$ bin/micrate help` => should output help commands.

### Creating a migration

Let's create a `posts` table in our database.

```sh
$ bin/micrate scaffold create_posts
```

This will create a file under `db/migrations`. Let's open it and define our posts schema.

```sql
-- +micrate Up
-- SQL in section 'Up' is executed when this migration is applied
CREATE TABLE posts(
  id BIGSERIAL PRIMARY KEY,
  title VARCHAR NOT NULL,
  body TEXT NOT NULL,
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

-- +micrate Down
-- SQL section 'Down' is executed when this migration is rolled back
DROP TABLE posts;
```

And now let's run the migration

```sh
$ bin/micrate up
```

You should now have a `posts` table in your database ready to query.

## Create-table DSL and column options

`Grant::Schema::SchemaStatements` builds DDL for tables that do not come from a
model. Each operation has a `*_statements` form that returns the SQL and a plain
form that runs it. `AdapterStatements` runs on a real adapter;
`RecordingStatements` records the SQL for any `Grant::Schema::Dialect` without a
database, which is how the specs assert the SQL of all three adapters.

```crystal
statements = Grant::Schema::AdapterStatements.new(User.adapter)

statements.create_table(:users, comment: "People", if_not_exists: true) do |t|
  t.string :name, null: false, limit: 100, collation: "C"
  t.decimal :balance, precision: 12, scale: 2, default: 0
  t.datetime :seen_at, default_sql: "CURRENT_TIMESTAMP"
  t.timestamps precision: 6 # created_at, updated_at, NOT NULL
end

# join table, composite key
statements.create_table(:memberships, id: false, primary_key: [:user_id, :group_id]) do |t|
  t.bigint :user_id
  t.bigint :group_id
end

statements.add_timestamps(:posts, null: true)
statements.remove_timestamps(:posts)
statements.change_column_default(:users, :role, from: nil, to: "member")
```

`create_table` options: `id:` (`true`/`:bigint`, `:integer`, `:smallint`,
`:uuid`, `:string`, `false`), `primary_key:` (auto column name, or an array of
declared columns), `if_not_exists:`, `temporary:`, `force:` (`true` or
`:cascade`, cascade on PostgreSQL only), `comment:` (PostgreSQL and MySQL) and
`options:` (raw trailing SQL).

Column kinds: `string`, `text`, `integer`, `smallint`, `tinyint`, `bigint`,
`boolean`, `float` (4 byte), `double` (8 byte), `decimal`, `datetime`,
`timestamp`, `time`, `date`, `binary`, `json`, `jsonb` (PostgreSQL only), `uuid`,
or `column :x, "raw type"`. Options: `null:`, `default:`, `default_sql:`,
`limit:`, `precision:`, `scale:`, `comment:`, `collation:`, `array:` (PostgreSQL
only), `primary_key:`. SQL expression defaults are emitted verbatim on
PostgreSQL and parenthesized on MySQL and SQLite where those databases need it.

Model `column` declarations take the same `null:`, `limit:`, `precision:`,
`scale:`, `comment:`, `collation:` and `default_sql:` options, and several
`primary: true` columns produce `PRIMARY KEY (a, b)`:

```crystal
column price : BigDecimal, precision: 12, scale: 2
Invoice.migrator.create(if_not_exists: true, comment: "Invoices")
```

Known limits: `change_column_default` and a `NOT NULL` `add_timestamps` without
a default raise `UnsupportedOperation` on SQLite (they need a table rebuild);
column comments are skipped on SQLite; Grant models cannot yet hold `Int8`,
`Int16`, `BigDecimal`, `JSON::Any` or `Bytes` values, so those types are mapped
for the DSL and the type catalog but not exercised through model persistence.

### Cost

These are DDL statements; none does per-row work. Adding a column with a
constant default is metadata-only on PostgreSQL 11+ and can rewrite the table on
MySQL. Changing a default is metadata-only on PostgreSQL and MySQL 8+, and may
rewrite on older MySQL.
