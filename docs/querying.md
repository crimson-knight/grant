# Querying

The query macro and where clause combine to give you full control over your query.

## Where

Where is using a QueryBuilder that allows you to chain where clauses together to build up a complete query.

```crystal
posts = Post.where(published: true, author_id: User.first!.id)
```

It supports different operators:

```crystal
Post.where(:created_at, :gt, Time.local - 7.days)
```

Supported operators are :eq, :gteq, :lteq, :neq, :gt, :lt, :nlt, :ngt, :ltgt, :in, :nin, :like, :nlike

Alternatively, `#where`, `#and`, and `#or` accept a raw SQL clause. Use `?` placeholders on any adapter, or numbered `$1`, `$2`, … placeholders in PostgreSQL SQL. Pass the bind values as an array when a clause has multiple placeholders. Grant checks that the placeholder count matches the values before sending the query.

```crystal
# Example using Postgres adapter
Post.where(:created_at, :gt, Time.local - 7.days)
  .where("LOWER(author_name) = $1", name)
  .where("tags @> '{"Journal", "Book"}') # PG's array contains operator
```

This is useful for building more sophisticated queries, including queries dependent on database specific features not supported by the operators above. However, **clauses built with this method are not validated.**

## Relations

Every chain method (`where`, `order`, `limit`, `joins`, `group_by`, `merge`, ...)
returns a new relation and leaves the receiver alone, so a stored relation is
safe to reuse. Clause arrays are shared copy-on-write, so a chain step costs one
small object plus a copy of only the arrays it changes. The bang variants
(`where!`, `order!`, `limit!`, ...) mutate in place for code that owns the
relation.

```crystal
active = Post.where(published: true)
recent = active.order(created_at: :desc).limit(10) # `active` is unchanged
```

`Model.all` returns a lazy relation. Use `to_a` (or `select`) for an `Array`, or
`Model.all("WHERE ...", params)` for the raw-SQL form, which still returns an
`Array`.

A relation memoizes its records once it is iterated or `load`ed. `loaded?`,
`records`, `reset`, and `reload` manage that memo; `empty?`, `size`, `first`,
and `last` answer from it without SQL. On an unloaded relation `size` runs
`COUNT(*)` and the existence predicates run a bounded query.

```crystal
posts = Post.where(published: true).load
posts.loaded? # => true
posts.empty?  # no SQL
posts.reload  # runs the query again
```

Finders: `take`/`take(n)` (no ordering), `first`/`first(n)`, `last`/`last(n)`,
`second` through `fifth`, `forty_two`, `second_to_last`, `third_to_last`, and
their bang forms (`LIMIT 1 OFFSET n`). `many?`, `one?`, `none?`, `empty?`, and
`any?` use `LIMIT 1` or `LIMIT 2`; `sole` uses `LIMIT 2`. None of them change the
receiver.

`only(*components)` and `except(*components)` keep or drop clause components
(`:where`, `:order`, `:limit`, `:offset`, `:group`, `:having`, `:joins`,
`:select`, `:distinct`, `:lock`). `to_sql` returns the SQL, `cache_key` a digest
of the query, and `cache_version` `"<count>-<newest updated_at>"` from one
aggregate query.

### Ordering

An unordered relation carries no `ORDER BY`. `first`, `last`, the ordinal
finders, and `find_each` order by the model's `implicit_order_column`s and then
its primary key (every column of a composite key):

```crystal
class Event < Grant::Base
  column id : Int64, primary: true
  column created_at : Time
  implicit_order_column :created_at
end

Event.first # ORDER BY created_at ASC, id ASC LIMIT 1
```

Earlier releases appended `ORDER BY <primary key> DESC` to every unordered
SELECT. Set `Grant.settings.implicit_order = true` to keep that behavior; the
flag is temporary and will be removed.

## Raw SQL

Use model-level raw SQL methods when the statement should still return hydrated
Grant models, or use `connection` when you need a raw database result. Pass bind
values as an array; Grant sends them through the adapter's parameter binding and
does not interpolate them into the SQL string.

```crystal
posts = Post.find_by_sql(
  "SELECT * FROM posts WHERE author_id = ? ORDER BY id",
  [author_id]
)

post_count = Post.count_by_sql(
  "SELECT COUNT(*) FROM posts WHERE author_id = ?",
  [author_id]
)

Post.exec("UPDATE posts SET published = ? WHERE id = ?", [true, post_id])
Post.scalar("SELECT title FROM posts WHERE id = ?", [post_id])
```

`find_by_sql` returns an `Array(Post)` and hydrates each row as a persisted
model. `count_by_sql` returns `Int64`. `exec` uses the write connection;
`scalar` uses the read route and returns the first cell or `nil`. `Model.query`
also accepts bound values and yields the adapter result set to its block.

For rows and columns without model hydration, use the model's raw connection:

```crystal
result = Post.connection.exec_query(
  "SELECT id, title FROM posts WHERE author_id = ?",
  [author_id]
)

result.columns # => ["id", "title"]
result.to_a    # => [{"id" => 1, "title" => "First post"}, ...]
result.each { |row| puts row["title"] }
result.size
result.empty?
```

`Grant::Result` also exposes positional `rows`. `connection.execute(sql, binds)`
executes a bound statement on the write route and returns `DB::ExecResult`.
Read helpers are `select_all`, `select_one`, `select_value`, `select_values`,
and `select_rows`. A named connection can be reached through
`Grant.connection("analytics")`; the default connection is
`Grant.connection`.

`sanitize_sql_array(["title = ?", value])` and `sanitize_sql` are available on
models for constructing SQL fragments. Prefer bound execution methods for SQL
sent to a database.

### Scopes and tenancy

Raw SQL does not infer a model's default scope or inject row-tenant predicates.
Model-level raw calls (`find_by_sql`, `count_by_sql`, `exec`, `scalar`, and
`query`) on a model with a default scope raise
`Grant::Querying::ScopedRawSqlError` unless the call is deliberately wrapped in
`Model.unscoped { ... }`. Add any tenant predicate required by the statement
yourself. `Model.connection` and `Grant.connection(name)` are explicitly raw and
do not apply model scopes or row-tenant predicates. They still use Grant's
connection routing and keep active transactions and schema-tenant connection
pinning.

## Order

Order is using the QueryBuilder and supports providing an ORDER BY clause:

```crystal
Post.order(:created_at)
```

Direction

```crystal
Post.order(updated_at: :desc)
```

Multiple fields

```crystal
Post.order([:created_at, :title])
```

With direction

```crystal
Post.order(created_at: :desc, title: :asc)
```

## Group By

Group is using the QueryBuilder and supports providing an GROUP BY clause:

```crystal
posts = Post.group_by(:published)
```

Multiple fields

```crystal
Post.group_by([:published, :author_id])
```

## Limit

Limit is using the QueryBuilder and provides the ability to limit the number of tuples returned:

```crystal
Post.limit(50)
```

## Offset

Offset is using the QueryBuilder and provides the ability to offset the results. This is used for pagination:

```crystal
Post.offset(100).limit(50)
```

## All

All is not using the QueryBuilder. It allows you to directly query the database using SQL.

When using the `all` method, the selected fields will match the
fields specified in the model unless the `select` macro was used to customize
the SELECT.

Always pass in parameters to avoid SQL Injection. Use a `?`
in your query as placeholder. Checkout the [Crystal DB Driver](https://github.com/crystal-lang/crystal-db)
for documentation of the drivers.

Here are some examples:

```crystal
posts = Post.all("WHERE name LIKE ?", ["Joe%"])
if posts
  posts.each do |post|
    puts post.name
  end
end

# ORDER BY Example
posts = Post.all("ORDER BY created_at DESC")

# JOIN Example
posts = Post.all("JOIN comments c ON c.post_id = post.id
                  WHERE c.name = ?
                  ORDER BY post.created_at DESC",
                  ["Joe"])
```

## Customizing SELECT

The `select_statement` macro allows you to customize the entire query, including the SELECT portion. This shouldn't be necessary in most cases, but allows you to craft more complex (i.e. cross-table) queries if needed:

```crystal
class CustomView < Grant::Base
  connection pg

  column id : Int64, primary: true
  column articlebody : String
  column commentbody : String

  select_statement <<-SQL
    SELECT articles.articlebody, comments.commentbody
    FROM articles
    JOIN comments
    ON comments.articleid = articles.id
  SQL
end
```

You can combine this with an argument to `all` or `first` for maximum flexibility:

```crystal
results = CustomView.all("WHERE articles.author = ?", ["Noah"])
```

Note - the column order does matter, and you should match your SELECT query to have the columns in the same order they are in the database.

## Exists?

The `exists?` class method returns `true` if a record exists in the table that matches the provided _id_ or _criteria_, otherwise `false`.

If passed a `Number` or `String`, it will attempt to find a record with that primary key. If passed a `Hash` or `NamedTuple`, it will find the record that matches that criteria, similar to `find_by`.

```crystal
# Assume a model named Post with a title field
post = Post.new(title: "My Post")
post.save
post.id # => 1

Post.exists? 1 # => true
Post.exists? {"id" => 1, :title => "My Post"} # => true
Post.exists? {id: 1, title: "Some Post"} # => false
```

The `exists?` method can also be used with the query builder.

```crystal
Post.where(published: true, author_id: User.first!.id).exists?
Post.where(:created_at, :gt, Time.local - 7.days).exists?
```

## Collection Methods (Enumerable)

`Query::Builder` includes `Enumerable(Model)`, which means you can use all of Crystal's standard collection methods directly on query chains — no need to call `.all` first.

### Before & After

```crystal
# Before — required .all to access collection methods
Post.where(published: true).all.map { |p| p.title }
Post.where(published: true).all.select { |p| p.featured }

# After — Enumerable methods work directly on the query builder
Post.where(published: true).map { |p| p.title }
Post.where(published: true).select { |p| p.featured }
```

### Iterating

```crystal
# each — iterate over matching records
Post.where(published: true).each do |post|
  puts post.title
end
```

### Transforming

```crystal
# map — transform records into a new array
titles = Post.where(published: true).map { |p| p.title }

# compact_map — map and remove nil values
emails = User.where(active: true).compact_map { |u| u.email }

# flat_map — map and flatten nested arrays
all_tags = Post.where(published: true).flat_map { |p| p.tags }
```

### Filtering

```crystal
# select with block — filter records in memory
featured = Post.where(published: true).select { |p| p.featured }

# reject — inverse filter
non_featured = Post.where(published: true).reject { |p| p.featured }

# Note: select WITHOUT a block still executes the SQL query as before
posts = Post.where(published: true).select  # => Array(Post)
```

### Counting & Checking

```crystal
# count without block — executes SQL COUNT, returns Int64
Post.where(published: true).count  # => 42_i64

# count with block — counts matching records in memory
Post.where(published: true).count { |p| p.featured }  # => 5

# size — alias for count, returns Int64
Post.where(published: true).size  # => 42_i64

# any? without block — checks if any records exist (SQL)
Post.where(published: true).any?  # => true

# any? with block — checks with in-memory condition
Post.where(published: true).any? { |p| p.title.includes?("Crystal") }

# none? — true if no records match the block condition
Post.where(published: true).none? { |p| p.title.empty? }

# all? — true if every record matches the block condition
Post.where(published: true).all? { |p| p.author_id > 0 }
```

### Aggregating

```crystal
# min_by / max_by — find records by criteria
oldest = User.where(active: true).min_by { |u| u.created_at }
newest = User.where(active: true).max_by { |u| u.created_at }

# sum with block — sum computed values
total_revenue = Order.where(status: "completed").sum { |o| o.total_amount }

# reduce — accumulate a result
combined = Post.where(published: true).reduce("") { |acc, p| acc + p.title + ", " }

# tally_by — count occurrences by a key
role_counts = User.where(active: true).tally_by { |u| u.role }
# => {"admin" => 3, "member" => 15, "guest" => 7}
```

### Grouping & Partitioning

```crystal
# partition — split into two arrays based on a condition
admins, others = User.where(active: true).partition { |u| u.role == "admin" }

# each_with_object — iterate while building up an object
name_map = User.where(active: true).each_with_object({} of Int64 => String) do |user, hash|
  hash[user.id] = user.name
end
```

### Converting

```crystal
# to_a — materialize the query results into an Array
posts_array = Post.where(published: true).to_a  # => Array(Post)
```

### Chaining with Query Methods

Enumerable methods work at the end of any query chain:

```crystal
# Combine where, order, limit with Enumerable
Post.where(published: true)
    .order(created_at: :desc)
    .limit(10)
    .map { |p| p.title }

# Use with offset for pagination
Post.where(published: true)
    .offset(20)
    .limit(10)
    .each { |p| puts p.title }
```

### SQL-Optimized vs In-Memory Methods

| Method | Without Block | With Block |
|--------|--------------|------------|
| `count` / `size` | SQL `COUNT` → `Int64` | In-memory iteration |
| `any?` | SQL `LIMIT 1` check | In-memory iteration |
| `select` | Executes SQL query | In-memory filter |
| `map`, `reject`, `reduce`, etc. | — | In-memory iteration |

Methods **without a block** (like `count`, `size`, `any?`) use optimized SQL queries. Methods **with a block** fetch all matching records first, then iterate in memory. For large result sets, prefer SQL-level filtering with `where` clauses before using block-based methods.
