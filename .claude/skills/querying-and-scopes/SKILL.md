---
name: grant-querying-and-scopes
description: Grant ORM query builder API including where clauses, operators, WhereChain, OR/NOT groups, scopes, aggregations, raw SQL, and Enumerable integration.
user-invocable: false
---

# Grant Querying and Scopes

## Query Execution Model

Queries in Grant are **lazy** -- they build up a query description but do not execute until a terminal method is called:

```crystal
# Building query (NOT executed yet)
query = User.where(active: true).order(:name)

# These are terminal methods that trigger execution:
users  = query.select     # Returns Array(User)
first  = query.first      # Returns User?
count  = query.count      # Returns Int64 (SQL COUNT)
exists = query.exists?    # Returns Bool
```

## Where Conditions

### Basic WHERE

```crystal
User.where(status: "active")                    # Equality
User.where(status: "active", verified: true)    # Multiple conditions (AND)
User.where({status: "active", age: 25})         # Hash syntax
```

### Operator Syntax

```crystal
Post.where(:views, :gt, 100)           # >
Post.where(:price, :lteq, 50.0)       # <=
Post.where(:created_at, :gt, 7.days.ago)
```

Supported operators: `:eq`, `:neq`, `:gt`, `:lt`, `:gteq`, `:lteq`, `:nlt`, `:ngt`, `:ltgt`, `:in`, `:nin`, `:like`, `:nlike`

### WhereChain Methods

Call `where` without arguments to access the WhereChain:

```crystal
User.where.like(:email, "%@gmail.com")      # LIKE
User.where.not_like(:name, "test%")         # NOT LIKE
User.where.gt(:age, 18)                     # >
User.where.lt(:age, 65)                     # <
User.where.gteq(:score, 80)                # >=
User.where.lteq(:price, 100)               # <=
User.where.is_null(:deleted_at)             # IS NULL
User.where.is_not_null(:verified_at)        # IS NOT NULL
User.where.between(:age, 25..35)           # >= 25 AND <= 35
User.where.not_in(:id, [1, 2, 3])         # NOT IN
User.where.not(:role, "guest")             # != 'guest'
```

### EXISTS / NOT EXISTS Subqueries

```crystal
User.where.exists(
  Post.where("posts.user_id = users.id")
)

User.where.not_exists(
  Post.where("posts.user_id = users.id").where.gt(:created_at, 30.days.ago)
)
```

### Raw SQL Conditions

```crystal
Post.where("LOWER(title) LIKE ?", ["%crystal%"])
User.where("age * 2 > ?", [50])
# PostgreSQL: use $ placeholder
Post.where("metadata->>'key' = $", ["value"])
```

## OR and NOT Conditions

### OR Groups

```crystal
User.where(role: "admin").or { |q| q.where(role: "moderator") }
# SQL: WHERE role = 'admin' OR role = 'moderator'

User.where(verified: true)
    .or do |q|
      q.where(role: "admin").where.gt(:level, 10)
    end
# SQL: WHERE verified = true OR (role = 'admin' AND level > 10)
```

### NOT Groups

```crystal
User.not { |q| q.where(status: "banned") }
# SQL: WHERE NOT (status = 'banned')

User.where(country: "US")
    .not { |q| q.where(status: "suspended") }
    .where.gteq(:age, 18)
```

## Ordering, Limiting, Grouping

### Order

```crystal
User.order(:name)                          # ASC default
User.order(created_at: :desc)             # Explicit DESC
Post.order(featured: :desc, created_at: :desc)  # Multiple
```

### Limit and Offset

```crystal
Post.limit(10)
Post.offset(40).limit(20)    # Pagination: page 3, 20 per page
```

### Distinct

```crystal
User.distinct.select(:country)
User.distinct.count(:email)
```

### Group By and Having

```crystal
Order.group_by(:status)
Order.group_by(:customer_id)
     .having("COUNT(*) > ?", [5])
     .select("customer_id, COUNT(*) as order_count")
```

## Joins

```crystal
# Inner join via association
Post.joins(:author).where("users.active = ?", [true])

# Multiple joins
Comment.joins(:post, :user)

# Left join (include records without associations)
User.left_joins(:posts).where("posts.id IS NULL")

# Raw JOIN
Order.joins("INNER JOIN products ON products.id = orders.product_id AND products.active = true")
```

## Eager Loading (N+1 Prevention)

```crystal
posts = Post.includes(:author, :comments)
posts.each do |post|
  puts post.author.name      # No additional query
  puts post.comments.size    # No additional query
end

# Nested includes
User.includes(posts: [:comments, :tags])
```

## Scopes

### Defining Scopes

```crystal
class Post < Grant::Base
  scope :published, -> { where(published: true) }
  scope :featured, -> { where(featured: true) }
  scope :recent, -> { order(created_at: :desc) }

  # Parameterized scopes
  scope :by_author, ->(author_id : Int32) { where(author_id: author_id) }
  scope :older_than, ->(date : Time) { where.lt(:created_at, date) }

  # Complex scopes
  scope :popular, -> {
    where.gt(:views, 1000).where.gt(:likes, 100).order(views: :desc)
  }
end

# Using scopes (chainable)
Post.published.recent.limit(10)
Post.by_author(current_user.id).featured
```

### Default Scopes

```crystal
class Product < Grant::Base
  default_scope { where(active: true).where.is_null(:deleted_at) }
end

Product.all              # Includes default scope
Product.unscoped.all     # Bypasses default scope
```

### Scope Composition

```crystal
scope :active_admins, -> { active.admins }

def self.for_dashboard
  active.verified.order(last_login: :desc)
end
```

## Aggregations

```crystal
User.count                                  # Total count => Int64
User.where(active: true).count             # Conditional count
User.distinct.count(:email)                # Count distinct

Order.sum(:total)                           # => Float64
Order.where(status: "completed").sum(:total)

Product.average(:price)                     # => Float64? (nil if empty)
# Alias: Product.avg(:price)

Product.minimum(:price)                     # min
Product.maximum(:stock)                     # max
# Aliases: Product.min(:price), Product.max(:price)
```

### Grouped Aggregations

```crystal
User.group_by(:role).count
Order.group_by(:customer_id).sum(:total)
```

## Query Merging and Duplication

```crystal
# Merge two queries (WHERE = AND, ORDER/LIMIT from merged)
active = User.where(active: true)
admins = User.where(role: "admin")
active_admins = active.merge(admins)

# Duplicate a query to create variations
base = User.where(active: true).order(name: :asc)
recent  = base.dup.where.gteq(:created_at, 7.days.ago)
verified = base.dup.where.is_not_null(:email_confirmed_at)
```

## IN Subqueries

```crystal
admin_ids = User.where(role: "admin").select(:id)
Post.where.in(:user_id, admin_ids)
# SQL: WHERE user_id IN (SELECT id FROM users WHERE role = 'admin')
```

## Raw SQL

```crystal
# Raw SQL with model instantiation
posts = Post.all("WHERE name LIKE ?", ["Joe%"])
post  = Post.first("WHERE id = ?", [1])

# Custom SELECT with select_statement macro
class PostWithComments < Grant::Base
  column id : Int64, primary: true
  column title : String
  column comment_count : Int32

  select_statement <<-SQL
    SELECT p.id, p.title, COUNT(c.id) as comment_count
    FROM posts p
    LEFT JOIN comments c ON c.post_id = p.id
    GROUP BY p.id, p.title
  SQL
end
```

## Enumerable Integration

`Query::Builder` includes `Enumerable(Model)`, so all Crystal collection methods work directly on query chains:

```crystal
# Transforming
titles = Post.where(published: true).map { |p| p.title }
emails = User.where(active: true).compact_map { |u| u.email }

# Filtering (in-memory, after SQL fetch)
featured = Post.where(published: true).select { |p| p.featured }
non_featured = Post.where(published: true).reject { |p| p.featured }

# Counting
Post.where(published: true).count                     # SQL COUNT => Int64
Post.where(published: true).count { |p| p.featured }  # In-memory count

# Checking
Post.where(published: true).any?                        # SQL LIMIT 1
Post.where(published: true).any? { |p| p.title.includes?("Crystal") }  # In-memory

# Aggregating
total = Order.where(status: "completed").sum { |o| o.total_amount }
oldest = User.where(active: true).min_by { |u| u.created_at }
role_counts = User.where(active: true).tally_by { |u| u.role }

# Partitioning
admins, others = User.where(active: true).partition { |u| u.role == "admin" }

# Converting
posts_array = Post.where(published: true).to_a
```

### SQL-Optimized vs In-Memory

| Method | Without Block | With Block |
|--------|--------------|------------|
| `count` / `size` | SQL COUNT => Int64 | In-memory iteration |
| `any?` | SQL LIMIT 1 check | In-memory iteration |
| `select` | Executes SQL query | In-memory filter |
| `map`, `reject`, `reduce`, etc. | -- | In-memory iteration |

For large result sets, prefer SQL-level filtering with `where` clauses before using block-based methods.

## Query Annotations

```crystal
users = User.where(active: true).annotate("Dashboard#active_users").select
# SQL: /* Dashboard#active_users */ SELECT * FROM users WHERE active = true
```

## Async Aggregations

```crystal
count_result = User.async_count
sum_result = Order.async_sum(:total)
avg_result = Product.async_avg(:price)

total_users = count_result.await
total_revenue = sum_result.await
average_price = avg_result.await
```
