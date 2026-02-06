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

Alternatively, `#where`, `#and`, and `#or` accept a raw SQL clause, with an optional placeholder (`?` for MySQL/SQLite, `$` for Postgres) to avoid SQL Injection.

```crystal
# Example using Postgres adapter
Post.where(:created_at, :gt, Time.local - 7.days)
  .where("LOWER(author_name) = $", name)
  .where("tags @> '{"Journal", "Book"}') # PG's array contains operator
```

This is useful for building more sophisticated queries, including queries dependent on database specific features not supported by the operators above. However, **clauses built with this method are not validated.**

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
