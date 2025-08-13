---
title: "Querying and Scopes"
category: "core-features"
subcategory: "querying"
tags: ["querying", "scopes", "where", "sql", "database", "search", "filters"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../getting-started/first-model.md", "models-and-columns.md", "crud-operations.md"]
related_docs: ["relationships.md", "../advanced/performance/query-optimization.md", "../advanced/performance/eager-loading.md"]
last_updated: "2025-01-13"
estimated_read_time: "20 minutes"
use_cases: ["data-retrieval", "filtering", "search", "reporting", "analytics"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Querying and Scopes

Comprehensive guide to Grant's powerful query interface, from basic queries to advanced patterns, scopes, and optimization techniques.

## Basic Querying

Grant provides a fluent, chainable query API that generates efficient SQL while maintaining type safety.

### Simple Queries

```crystal
# Find all active users
users = User.where(active: true)

# Chain multiple conditions (AND)
posts = Post.where(published: true, featured: true)
            .where(author_id: current_user.id)

# Find with multiple fields
post = Post.find_by(slug: "my-post", published: true)
```

### Query Execution

Queries are lazy - they don't execute until you call a terminal method:

```crystal
# Building query (not executed)
query = User.where(active: true).order(:name)

# Execution happens here
users = query.select     # Returns array of User
first = query.first      # Returns User?
count = query.count      # Returns Int32
exists = query.exists?   # Returns Bool
```

## Where Conditions

### Basic WHERE Syntax

```crystal
# Equality
User.where(status: "active")
User.where(age: 25)

# Multiple conditions (AND)
User.where(status: "active", verified: true)

# Hash syntax
User.where({status: "active", age: 25})

# NamedTuple syntax
User.where(status: "active", country: "US")
```

### Comparison Operators

```crystal
# Using operator syntax
Post.where(:views, :gt, 100)        # Greater than
Post.where(:price, :lteq, 50.0)     # Less than or equal
Post.where(:created_at, :gt, 7.days.ago)

# Available operators
Post.where(:field, :eq, value)      # = (equal)
Post.where(:field, :neq, value)     # != (not equal)
Post.where(:field, :gt, value)      # > (greater than)
Post.where(:field, :lt, value)      # < (less than)
Post.where(:field, :gteq, value)    # >= (greater or equal)
Post.where(:field, :lteq, value)    # <= (less or equal)
Post.where(:field, :in, array)      # IN
Post.where(:field, :nin, array)     # NOT IN
Post.where(:field, :like, pattern)  # LIKE
Post.where(:field, :nlike, pattern) # NOT LIKE
```

### WhereChain Methods

Access advanced methods by calling `where` without arguments:

```crystal
# Pattern matching
User.where.like(:email, "%@gmail.com")
User.where.not_like(:name, "test%")

# Comparisons
User.where.gt(:age, 18)
User.where.lt(:age, 65)
User.where.gteq(:score, 80)
User.where.lteq(:price, 100)

# NULL checks
User.where.is_null(:deleted_at)
User.where.is_not_null(:verified_at)

# Ranges
User.where.between(:age, 25..35)
Product.where.between(:price, 10.0..50.0)

# NOT IN
User.where.not_in(:id, [1, 2, 3])
Post.where.not_in(:status, ["draft", "archived"])

# NOT (inequality)
User.where.not(:role, "guest")
```

### Raw SQL Conditions

For database-specific features or complex conditions:

```crystal
# With placeholders (? for MySQL/SQLite, $ for PostgreSQL)
Post.where("LOWER(title) LIKE ?", ["%crystal%"])
User.where("age * 2 > ?", [50])

# PostgreSQL specific
Post.where("tags @> ARRAY[?]::varchar[]", ["ruby"])
Post.where("metadata->>'key' = $", ["value"])

# MySQL specific
Post.where("MATCH(title, content) AGAINST(? IN BOOLEAN MODE)", ["+crystal +orm"])

# Combining with regular where
User.where(active: true)
    .where("created_at > NOW() - INTERVAL ? DAY", [30])
```

## OR and NOT Conditions

### OR Groups

```crystal
# Simple OR
User.where(role: "admin").or { |q| q.where(role: "moderator") }
# SQL: WHERE role = 'admin' OR role = 'moderator'

# Complex OR with multiple conditions
User.where(verified: true)
    .or do |q|
      q.where(role: "admin")
       .where.gt(:level, 10)
    end
# SQL: WHERE verified = true OR (role = 'admin' AND level > 10)

# Multiple OR groups
Post.where(featured: true)
    .or { |q| q.where(editor_pick: true) }
    .or { |q| q.where.gt(:views, 10000) }
# SQL: WHERE featured = true OR editor_pick = true OR views > 10000
```

### NOT Groups

```crystal
# Simple NOT
User.not { |q| q.where(status: "banned") }

# Complex NOT conditions
User.not do |q|
  q.where(active: false)
   .where.is_null(:email_verified_at)
end
# SQL: WHERE NOT (active = false AND email_verified_at IS NULL)

# Combining NOT with other conditions
Product.where(available: true)
       .not { |q| q.where.in(:category_id, restricted_categories) }
       .where.gt(:stock, 0)
```

## Ordering and Limiting

### Order

```crystal
# Single field
User.order(:name)              # ASC by default
User.order(created_at: :desc)  # Explicit direction

# Multiple fields
Post.order(featured: :desc, created_at: :desc)
Post.order([:category, :title])  # Multiple with default ASC

# Raw SQL ordering
Product.order("RANDOM()")  # PostgreSQL
Product.order("RAND()")    # MySQL
```

### Limit and Offset

```crystal
# Limit results
Post.limit(10)

# Pagination with offset
page = 3
per_page = 20
Post.offset((page - 1) * per_page).limit(per_page)

# First/Last helpers
User.first          # Single record
User.first(5)       # First 5 records
User.last(10)       # Last 10 records
```

### Distinct

```crystal
# Unique values
User.distinct.select(:country)

# Count distinct
User.distinct.count(:email)
```

## Grouping and Having

```crystal
# Group by single field
Order.group_by(:status)

# Group by multiple fields
Sale.group_by([:product_id, :store_id])

# Group with having clause
Order.group_by(:customer_id)
     .having("COUNT(*) > ?", [5])
     .select("customer_id, COUNT(*) as order_count")

# Complex aggregation
Product.select("category_id, AVG(price) as avg_price")
       .group_by(:category_id)
       .having("AVG(price) > ?", [50])
```

## Joins and Includes

### Inner Joins

```crystal
# Join with association
Post.joins(:author)
    .where("users.active = ?", [true])

# Multiple joins
Comment.joins(:post, :user)
       .where("posts.published = ?", [true])

# Join with custom conditions
Order.joins("INNER JOIN products ON products.id = orders.product_id 
            AND products.active = true")
```

### Left Joins

```crystal
# Include records even without association
User.left_joins(:posts)
    .where("posts.id IS NULL")  # Users without posts

# Multiple left joins
Product.left_joins(:reviews, :orders)
```

### Eager Loading (N+1 Prevention)

```crystal
# Preload associations
posts = Post.includes(:author, :comments)
posts.each do |post|
  puts post.author.name        # No additional query
  puts post.comments.size      # No additional query
end

# Nested includes
User.includes(posts: [:comments, :tags])

# Conditional includes
Post.includes(:comments)
    .where("comments.approved = ?", [true])
    .references(:comments)
```

## Scopes

### Defining Scopes

```crystal
class Post < Grant::Base
  # Simple scopes
  scope :published, -> { where(published: true) }
  scope :featured, -> { where(featured: true) }
  scope :recent, -> { order(created_at: :desc) }
  
  # Parameterized scopes
  scope :by_author, ->(author_id : Int32) { where(author_id: author_id) }
  scope :tagged_with, ->(tag : String) { where("tags @> ARRAY[?]", [tag]) }
  scope :older_than, ->(date : Time) { where.lt(:created_at, date) }
  
  # Complex scopes
  scope :popular, -> {
    where.gt(:views, 1000)
         .where.gt(:likes, 100)
         .order(views: :desc)
  }
  
  # Scopes with joins
  scope :with_comments, -> {
    joins(:comments)
    .where.is_not_null("comments.id")
    .distinct
  }
end

# Using scopes
Post.published.recent.limit(10)
Post.by_author(current_user.id).featured
Post.tagged_with("crystal").popular
```

### Default Scopes

```crystal
class Product < Grant::Base
  # Applied to all queries automatically
  default_scope { where(active: true).where.is_null(:deleted_at) }
  
  # Bypass default scope
  scope :unscoped, -> { unscoped }
  scope :all_including_deleted, -> { unscoped }
end

Product.all              # Includes default scope
Product.unscoped.all     # Bypasses default scope
```

### Scope Composition

```crystal
class User < Grant::Base
  scope :active, -> { where(active: true) }
  scope :verified, -> { where.is_not_null(:email_verified_at) }
  scope :admins, -> { where(role: "admin") }
  
  # Combine scopes
  scope :active_admins, -> { active.admins }
  scope :verified_active, -> { active.verified }
  
  # Dynamic composition
  def self.for_dashboard
    active.verified.order(last_login: :desc)
  end
end
```

## Subqueries

### IN Subqueries

```crystal
# Find posts by admin users
admin_ids = User.where(role: "admin").select(:id)
Post.where.in(:user_id, admin_ids)

# Products in active categories
active_category_ids = Category.where(active: true).select(:id)
Product.where.in(:category_id, active_category_ids)

# Complex subquery
recent_order_ids = Order.where.gt(:created_at, 30.days.ago)
                        .where(status: "completed")
                        .select(:id)
OrderItem.where.in(:order_id, recent_order_ids)
```

### EXISTS Subqueries

```crystal
# Users with posts
User.where.exists(
  Post.where("posts.user_id = users.id")
)

# Products with stock in any warehouse
Product.where.exists(
  Stock.where("stocks.product_id = products.id")
       .where.gt(:quantity, 0)
)

# NOT EXISTS
User.where.not_exists(
  Post.where("posts.user_id = users.id")
      .where.gt(:created_at, 30.days.ago)
)
```

## Aggregations

### Count

```crystal
# Total count
User.count

# Count specific column
User.count(:email)  # Non-null emails

# Count with conditions
User.where(active: true).count

# Count distinct
User.distinct.count(:country)

# Group count
User.group_by(:role).count
# => {"admin" => 5, "user" => 100, "moderator" => 10}
```

### Sum, Average, Min, Max

```crystal
# Sum
Order.sum(:total)
Order.where(status: "completed").sum(:total)

# Average
Product.average(:price)
Review.where(product_id: 1).average(:rating)

# Minimum and Maximum
Product.minimum(:price)
Product.maximum(:stock)

# With grouping
Order.group_by(:customer_id).sum(:total)
Review.group_by(:product_id).average(:rating)
```

### Calculations

```crystal
# Multiple aggregations at once
stats = Product.select(
  "COUNT(*) as total",
  "AVG(price) as avg_price",
  "MIN(price) as min_price",
  "MAX(price) as max_price",
  "SUM(stock) as total_stock"
).first

# Conditional aggregations
Order.select(
  "COUNT(*) as total_orders",
  "COUNT(CASE WHEN status = 'completed' THEN 1 END) as completed",
  "COUNT(CASE WHEN status = 'pending' THEN 1 END) as pending"
).first
```

## Query Merging

```crystal
# Define reusable query components
module Scopes
  def self.active
    User.where(active: true)
  end
  
  def self.verified
    User.where.is_not_null(:email_verified_at)
  end
  
  def self.premium
    User.where(subscription: "premium")
  end
end

# Merge queries
active_verified = Scopes.active.merge(Scopes.verified)
premium_active = Scopes.premium.merge(Scopes.active)

# Merging rules:
# - WHERE conditions are combined with AND
# - ORDER BY from merged query takes precedence
# - LIMIT/OFFSET from merged query takes precedence
# - Associations are combined
```

## Raw SQL

### Complete Queries

```crystal
# Raw SQL with model instantiation
posts = Post.all("WHERE title LIKE ? ORDER BY created_at DESC", ["%crystal%"])

# First record
post = Post.first("WHERE id = ?", [1])

# Custom SELECT
results = Post.all(
  "SELECT p.*, COUNT(c.id) as comment_count 
   FROM posts p 
   LEFT JOIN comments c ON c.post_id = p.id 
   GROUP BY p.id 
   HAVING COUNT(c.id) > ?", 
  [5]
)
```

### Custom SELECT Statement

```crystal
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

# Use with additional conditions
popular = PostWithComments.all("HAVING COUNT(c.id) > ?", [10])
```

## Query Optimization

### Use Indexes

```crystal
# Ensure indexed columns in WHERE
User.where(email: "user@example.com")  # email should be indexed
Post.where(slug: "my-post")            # slug should be indexed

# Composite indexes for multiple conditions
Order.where(customer_id: 1, status: "pending")  # INDEX(customer_id, status)
```

### Select Only Needed Columns

```crystal
# Bad: Loads all columns
users = User.where(active: true)

# Good: Load only required columns
users = User.where(active: true).select(:id, :name, :email)
```

### Batch Processing

```crystal
# Bad: Loads everything at once
User.all.each { |user| user.process! }

# Good: Process in batches
User.find_in_batches(batch_size: 1000) do |users|
  users.each(&.process!)
end
```

### Avoid N+1 Queries

```crystal
# Bad: N+1 queries
posts = Post.all
posts.each do |post|
  puts post.author.name  # Query for each post
end

# Good: Eager loading
posts = Post.includes(:author)
posts.each do |post|
  puts post.author.name  # No additional queries
end
```

### Use Pluck for Values

```crystal
# Bad: Instantiate models
emails = User.where(active: true).map(&.email)

# Good: Direct database values
emails = User.where(active: true).pluck(:email)
```

## Complex Query Examples

### Search Implementation

```crystal
def search_products(params)
  query = Product.where(active: true)
  
  # Text search
  if term = params["q"]?
    query = query.where.like(:name, "%#{term}%")
                 .or { |q| q.where.like(:description, "%#{term}%") }
  end
  
  # Price range
  if min_price = params["min_price"]?
    query = query.where.gteq(:price, min_price.to_f)
  end
  
  if max_price = params["max_price"]?
    query = query.where.lteq(:price, max_price.to_f)
  end
  
  # Categories
  if categories = params["categories"]?
    query = query.where.in(:category_id, categories.split(","))
  end
  
  # In stock only
  if params["in_stock"]?
    query = query.where.gt(:stock, 0)
  end
  
  # Sorting
  case params["sort"]?
  when "price_asc"
    query = query.order(:price)
  when "price_desc"
    query = query.order(price: :desc)
  when "newest"
    query = query.order(created_at: :desc)
  else
    query = query.order(:name)
  end
  
  query.limit(params.fetch("limit", "20").to_i)
end
```

### Dashboard Queries

```crystal
class DashboardQuery
  def self.user_stats(user_id : Int32)
    {
      posts_count: Post.where(author_id: user_id).count,
      comments_count: Comment.where(user_id: user_id).count,
      total_views: Post.where(author_id: user_id).sum(:views),
      avg_rating: Review.where(user_id: user_id).average(:rating),
      recent_activity: Activity.where(user_id: user_id)
                               .where.gt(:created_at, 7.days.ago)
                               .order(created_at: :desc)
                               .limit(10)
    }
  end
  
  def self.trending_posts
    Post.published
        .where.gt(:created_at, 7.days.ago)
        .where.gt(:views, 100)
        .order(views: :desc, likes: :desc)
        .limit(10)
  end
end
```

### Report Generation

```crystal
class ReportQuery
  def self.monthly_sales(year : Int32, month : Int32)
    start_date = Time.local(year, month, 1)
    end_date = start_date.shift(months: 1)
    
    Order.select(
      "DATE(created_at) as date",
      "COUNT(*) as order_count",
      "SUM(total) as revenue",
      "AVG(total) as avg_order_value"
    )
    .where(status: "completed")
    .where.between(:created_at, start_date..end_date)
    .group_by("DATE(created_at)")
    .order("DATE(created_at)")
  end
end
```

## Testing Queries

```crystal
describe "User queries" do
  it "finds active verified users" do
    active = User.create(active: true, email_verified_at: Time.utc)
    inactive = User.create(active: false, email_verified_at: Time.utc)
    unverified = User.create(active: true, email_verified_at: nil)
    
    results = User.where(active: true)
                  .where.is_not_null(:email_verified_at)
    
    results.should contain(active)
    results.should_not contain(inactive)
    results.should_not contain(unverified)
  end
end
```

## Next Steps

- [Relationships](relationships.md)
- [Validations](validations.md)
- [Callbacks and Lifecycle](callbacks-lifecycle.md)
- [Query Optimization](../advanced/performance/query-optimization.md)
- [Eager Loading](../advanced/performance/eager-loading.md)