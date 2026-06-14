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
