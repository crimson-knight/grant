# Quick Start

This is the fast path from zero to a working Grant model: the ten most common
operations, each runnable, with each step explained. It assumes you know Crystal
basics but nothing about Grant. Local development uses **SQLite**.

If you are new to how Grant turns a `column`/`belongs_to` line into methods,
read [`reading_the_generated_api.md`](reading_the_generated_api.md) alongside
this.

## Project setup — `shard.yml`

Grant depends on `db` (crystal-db) at runtime but declares the actual database
drivers (`sqlite3` / `pg` / `mysql`) only as its **development** dependencies.
That means **a consumer must add the driver shard for each adapter they use** —
Grant will not pull a driver in for you. `db` itself comes in transitively
through `grant`, so you do not list it.

Add `grant` plus the driver(s) you need to your `shard.yml`. For local SQLite
dev:

```yaml
dependencies:
  grant:
    github: amberframework/grant

  # The driver(s) you use — you MUST add these yourself:
  sqlite3:
    github: crystal-lang/crystal-sqlite3
    version: ~> 0.21.0
```

If you target Postgres and/or MySQL, add the matching driver(s) instead of (or
alongside) `sqlite3`:

```yaml
dependencies:
  grant:
    github: amberframework/grant

  pg:                              # Postgres
    github: will/crystal-pg
    version: ~> 0.29.0

  mysql:                           # MySQL
    github: crystal-lang/crystal-mysql
    version: ~> 0.16.0
```

Then `shards install`. (`db` is pulled in transitively by `grant`; you only add
the drivers.)

## Setup (once)

Require Grant and exactly one database adapter, then register a connection.
**Which adapter you `require` is how you pick your database** — there are no
flags. For local dev, SQLite:

```crystal
require "grant"
require "grant/adapter/sqlite"   # ← adapter selection IS this require

Grant::Connections << Grant::Adapter::Sqlite.new(
  name: "primary",
  url:  "sqlite3://./app.db")
```

(For Postgres use `require "grant/adapter/pg"` + `Grant::Adapter::Pg`; for MySQL,
`require "grant/adapter/mysql"` + `Grant::Adapter::Mysql`. The model code below
is identical regardless.)

---

## 1. Define a model — `column`, `timestamps`

A model is a class inheriting from `Grant::Base`. Declare which connection and
table it uses, then its columns. `timestamps` adds `created_at`/`updated_at`,
which Grant maintains automatically.

```crystal
class User < Grant::Base
  connection primary            # the connection name registered above
  table users                   # the DB table name

  column id : Int64, primary: true   # primary key
  column name : String
  column email : String
  column age : Int32?                # nilable column (note the `?`)
  timestamps                          # created_at + updated_at
end
```

Each `column` generates a getter, setter, and dirty-tracking helpers (see
[`reading_the_generated_api.md`](reading_the_generated_api.md)). The primary key
column **must** be marked `primary: true`.

---

## 2. Create the table — run (or skip) the migration

Grant ships a tiny migrator that creates a table from your model's columns —
handy for local dev and tests. `drop_and_create` drops the table if it exists
and recreates it:

```crystal
User.migrator.drop_and_create   # dev/test convenience
```

**Skip this** if you manage your schema elsewhere (e.g. real migrations, or an
existing database you are adopting). Grant does not require its migrator — it
maps to whatever table already exists. The model code is the same either way.

---

## 3. Create records — `create` / `create!`

`create` builds a record, runs validations, and `INSERT`s it, returning the
record. If validation fails it returns the (unsaved) record with errors set.
`create!` is the same but **raises** `Grant::RecordNotSaved` on failure.

```crystal
# create — returns the record (check #persisted? / #errors on failure)
user = User.create(name: "Ada", email: "ada@example.com", age: 36)
user.persisted?   # => true
user.id           # => 1 (assigned by the database)

# create! — raises on validation failure
admin = User.create!(name: "Grace", email: "grace@example.com")
```

You can also build first and save later:

```crystal
u = User.new(name: "Linus", email: "linus@example.com")
u.new_record?     # => true   (in memory, not yet saved)
u.save            # INSERTs; returns true/false
u.new_record?     # => false
```

---

## 4. Read one record — `find` / `find_by`

`find` looks up by primary key. `find_by` looks up by any column(s). The bang
forms (`find!`, `find_by!`) raise `Grant::Querying::NotFound` instead of
returning `nil`.

```crystal
User.find(1)                       # => User?  (nil if not found)
User.find!(1)                      # => User   (raises if not found)

User.find_by(email: "ada@example.com")   # => User?  by any column
User.find_by!(name: "Grace")             # => User   (raises if absent)
```

---

## 5. Query many — `where` / `order` / `limit`

`where`, `order`, and `limit` build a **lazy, chainable** query. Nothing hits
the database until a terminal step (`.to_a`, `.first`, `.count`, iteration, …).
The query object is `Enumerable`, so `map`/`select`/etc. work directly.

```crystal
# chain — no query runs yet
query = User.where(age: 36).order(name: :asc).limit(10)

query.to_a            # runs it → Array(User)
query.first           # => User?  (adds LIMIT 1)
query.count           # => Int    (runs a COUNT)

# Enumerable works directly on the chain:
User.where(age: 36).map(&.email)        # => Array(String)
User.where(age: 36).select(&.persisted?)

# operator form for ranges / comparisons:
User.where(:age, :gteq, 18).to_a        # age >= 18
```

`where` also accepts an explicit `field, operator, value` form (`:eq`, `:gteq`,
`:lt`, `:like`, etc.) for anything beyond equality.

---

## 6. Update — assign, then `save`

Change attributes with their setters, then `save` (returns `true`/`false`;
`save!` raises on failure). Grant tracks which attributes changed.

```crystal
user = User.find!(1)
user.age = 37
user.age_changed?   # => true   (dirty tracking)
user.save           # UPDATEs only the changed columns; returns true

# or update several at once and save in one call:
user.update(name: "Ada Lovelace", age: 37)   # assigns + saves
user.update!(email: "ada@new.example.com")    # raises on failure
```

---

## 7. Delete — `destroy`

`destroy` deletes the row (running destroy callbacks) and marks the in-memory
record destroyed. `destroy!` raises on failure.

```crystal
user = User.find!(1)
user.destroy        # DELETEs the row; returns true/false
user.destroyed?     # => true
user.persisted?     # => false
```

To delete in bulk without loading rows, use a query terminal:

```crystal
User.where(age: nil).delete_all   # one DELETE, no callbacks
```

---

## 8. Associations — `belongs_to` / `has_many` + traversal

Associations connect models by foreign key. Declare them on each side, then
traverse with the generated methods (see
[`relationships.md`](relationships.md) for the full guide).

```crystal
class Author < Grant::Base
  connection primary
  table authors
  column id : Int64, primary: true
  column name : String
  has_many :books              # => #books (collection), #book_ids
end

class Book < Grant::Base
  connection primary
  table books
  column id : Int64, primary: true
  column title : String
  belongs_to :author           # => #author, #author!, #author=, author_id column
end

Author.migrator.drop_and_create
Book.migrator.drop_and_create

ada  = Author.create!(name: "Ada")
book = Book.create!(title: "Notes on the Engine", author_id: ada.id)

# traverse:
book.author          # => Author?  (the owner)
book.author!.name    # => "Ada"    (bang form: raises if absent)
ada.books.to_a       # => [Book]   (the collection)
ada.books.size       # => 1        (Array-like, NOT a no-arg DB COUNT)
ada.books.each { |b| puts b.title }
```

The `has_many` collection (`ada.books`) is **Array-like / `Enumerable`**, not a
chainable query builder: it forwards unknown methods to its loaded `Array`, so
`.size`, `.each`, `.map`, `.select { }`, `.to_a`, etc. work — but
`ada.books.where(...)` and the no-arg `ada.books.count` do **not** compile. For
a *filtered DB query*, go through the class-level builder instead:

```crystal
# filter/aggregate in the database via the class-level query builder:
Book.where(author_id: ada.id).where(rating: 5).count   # => Int
Book.where(author_id: ada.id).order(title: :asc).to_a  # => Array(Book)
```

Set a `belongs_to` by assigning the parent (sets the FK in memory; `save` to
persist):

```crystal
book.author = another_author
book.save
```

---

## 9. Validations — declare, then `valid?` / `errors`

Add validation macros to a model. `valid?` runs them and returns a `Bool`;
failures populate `errors`. `save`/`create` run validations automatically and
fail (return `false` / raise on the bang form) if invalid.

```crystal
class Signup < Grant::Base
  connection primary
  table signups
  column id : Int64, primary: true
  column email : String?
  column age : Int32?

  validates_presence_of :email          # email must be present
  validates_numericality_of :age, greater_than: 0, allow_nil: true
end

s = Signup.new(email: nil, age: -1)
s.valid?               # => false (email blank, age not > 0)
s.errors.size          # => 2
s.errors.full_messages # => ["Email can't be blank", "Age must be greater than 0"]
s.errors.first.message # => "can't be blank"  (bare message; #full_messages prefixes the field)

s.email = "x@example.com"
s.age = 30
s.valid?            # => true
s.save              # now succeeds
```

Grant offers a rich `validates_*` family (`validates_presence_of`,
`validates_length_of`, `validates_uniqueness_of`, `validates_format_of`,
`validates_numericality_of`, …) plus terse `validate_*` one-liners and custom
`validate :method` blocks. See [`validations.md`](validations.md).

---

## 10. Transactions — `transaction`

Wrap multiple writes so they commit together or roll back together. Raising
inside the block rolls the whole thing back.

```crystal
Author.transaction do
  ada  = Author.create!(name: "Ada")
  Book.create!(title: "Book One", author_id: ada.id)
  Book.create!(title: "Book Two", author_id: ada.id)
  # if anything raises here, ALL of the above is rolled back
end
```

`transaction` also takes options for isolation level, read-only, and nested
savepoints (`requires_new: true`). See
[`LOCKING_AND_TRANSACTIONS.md`](LOCKING_AND_TRANSACTIONS.md) and
[`callbacks.md`](callbacks.md) for nested transactions, isolation levels, and
locking.

---

## Where to go next

- [`reading_the_generated_api.md`](reading_the_generated_api.md) — map any
  `column`/association line to the methods it produces.
- [`relationships.md`](relationships.md) — the full association guide.
- [`validations.md`](validations.md) — every validator and option.
- [`querying.md`](querying.md) — the complete query builder (scopes, OR/NOT
  groups, aggregations, raw SQL).
- [`compile_target_adapters.md`](compile_target_adapters.md) and
  [`monorepo_cross_device.md`](monorepo_cross_device.md) — compile the same
  models for a SQLite mobile target and a Postgres web target from one repo.
