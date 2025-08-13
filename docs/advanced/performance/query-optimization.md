---
title: "Query Optimization"
category: "advanced"
subcategory: "performance"
tags: ["performance", "optimization", "database", "indexing", "query-analysis", "sql", "benchmarking"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../../core-features/querying-and-scopes.md", "eager-loading.md"]
related_docs: ["eager-loading.md", "database-indexing.md", "../instrumentation/query-analysis.md"]
last_updated: "2025-01-13"
estimated_read_time: "18 minutes"
use_cases: ["high-traffic", "api-optimization", "reporting", "data-analytics"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Query Optimization

Advanced guide to optimizing database queries in Grant, including query analysis, indexing strategies, advanced query techniques, and performance monitoring.

## Overview

Query optimization is crucial for application performance at scale. This guide covers advanced techniques for writing efficient queries, analyzing performance bottlenecks, and leveraging Grant's advanced query interface for optimal database interactions.

## Query Analysis Tools

### Built-in Query Logging

```crystal
# Enable query logging
Grant.logger = Logger.new(STDOUT)
Grant.logger.level = Logger::DEBUG

# Log with execution time
Grant::Instrumentation.subscribe("query.grant") do |event|
  sql = event.payload[:sql]
  duration = event.duration.total_milliseconds
  
  if duration > 100  # Log slow queries
    Log.warn { "Slow query (#{duration}ms): #{sql}" }
  end
end
```

### Query Analysis Framework

```crystal
class QueryAnalyzer
  def self.analyze(&)
    queries = [] of NamedTuple(sql: String, duration: Float64, source: String)
    
    Grant::Instrumentation.subscribe("query.grant") do |event|
      queries << {
        sql: event.payload[:sql],
        duration: event.duration.total_milliseconds,
        source: caller.first(5).join("\n")
      }
    end
    
    result = yield
    
    # Analyze results
    report = {
      total_queries: queries.size,
      total_time: queries.sum(&.[:duration]),
      slow_queries: queries.select { |q| q[:duration] > 100 },
      duplicate_queries: find_duplicates(queries),
      n_plus_one: detect_n_plus_one(queries)
    }
    
    Log.info { "Query Analysis:\n#{report.to_pretty_json}" }
    result
  end
  
  private def self.find_duplicates(queries)
    queries.group_by(&.[:sql])
           .select { |_, group| group.size > 1 }
           .map { |sql, group| {sql: sql, count: group.size} }
  end
  
  private def self.detect_n_plus_one(queries)
    # Detect similar queries with different IDs
    patterns = queries.map { |q| q[:sql].gsub(/\d+/, "?") }
    patterns.group_by(&.itself)
            .select { |_, group| group.size > 10 }
            .map { |pattern, group| {pattern: pattern, count: group.size} }
  end
end

# Usage
QueryAnalyzer.analyze do
  posts = Post.all
  posts.each { |p| p.author.name }  # N+1 detected!
end
```

## Advanced Query Interface

### Query Merging

Combine multiple query conditions efficiently:

```crystal
# Define reusable scopes
class User < Grant::Base
  scope :active, -> { where(active: true) }
  scope :verified, -> { where(email_verified: true) }
  scope :premium, -> { where(subscription: "premium") }
  scope :recent, -> { where.gteq(:created_at, 30.days.ago) }
end

# Merge queries dynamically
def build_user_query(filters)
  query = User.all
  
  query = query.merge(User.active) if filters[:active]
  query = query.merge(User.verified) if filters[:verified]
  query = query.merge(User.premium) if filters[:premium]
  query = query.merge(User.recent) if filters[:recent]
  
  query
end

# Results in single optimized query
users = build_user_query({active: true, verified: true, recent: true})
# SQL: WHERE active = true AND email_verified = true AND created_at >= '...'
```

### Advanced WHERE Conditions

```crystal
# Chain complex conditions
users = User.where.gt(:age, 18)
            .lt(:age, 65)
            .like(:email, "%@company.com")
            .not_in(:status, ["banned", "suspended"])
            .is_not_null(:confirmed_at)

# Use WhereChain for readable queries
active_premium_users = User
  .where(active: true)
  .where.gteq(:subscription_expires, Time.utc)
  .where.not(:subscription_type, "trial")
  .where.between(:age, 25..45)

# Combine with OR conditions
admins_or_moderators = User
  .where(role: "admin")
  .or(User.where(role: "moderator"))
  .where(active: true)
```

### Subqueries

```crystal
# IN subquery
admin_post_ids = Post.where(featured: true).select(:id)
comments = Comment.where.in(:post_id, admin_post_ids)

# NOT IN subquery
inactive_user_ids = User.where(active: false).select(:id)
posts = Post.where.not_in(:user_id, inactive_user_ids)

# EXISTS subquery
users_with_orders = User.where.exists(
  Order.where("orders.user_id = users.id")
       .where.gteq(:total, 100)
)

# NOT EXISTS
users_without_posts = User.where.not_exists(
  Post.where("posts.author_id = users.id")
)

# Correlated subquery
class User < Grant::Base
  scope :with_recent_activity, -> {
    where.exists(
      Post.where("posts.user_id = users.id")
          .where.gteq(:created_at, 7.days.ago)
    ).or(
      where.exists(
        Comment.where("comments.user_id = users.id")
               .where.gteq(:created_at, 7.days.ago)
      )
    )
  }
end
```

### Common Table Expressions (CTEs)

```crystal
# WITH clause for complex queries
class Report < Grant::Base
  def self.monthly_summary(date)
    with(
      active_users: User.where(active: true)
                       .where.between(:last_login, date.beginning_of_month..date.end_of_month),
      premium_users: User.where(subscription: "premium"),
      recent_orders: Order.where.between(:created_at, date.beginning_of_month..date.end_of_month)
    ).select(
      "active_users.count as active_count",
      "premium_users.count as premium_count", 
      "recent_orders.sum(total) as revenue"
    ).from("active_users, premium_users, recent_orders")
  end
end

# Recursive CTE for hierarchical data
class Category < Grant::Base
  def self.descendants_of(category_id)
    with_recursive(
      subcategories: union(
        where(id: category_id),
        from("categories").joins("INNER JOIN subcategories ON categories.parent_id = subcategories.id")
      )
    ).from("subcategories")
  end
end
```

## Indexing Strategies

### Index Analysis

```crystal
class IndexAnalyzer
  # Check for missing indexes
  def self.analyze_query(sql)
    # Use EXPLAIN to analyze query plan
    result = Grant.connection.query("EXPLAIN ANALYZE #{sql}")
    
    # Parse execution plan
    if result.to_s.includes?("Seq Scan")
      Log.warn { "Sequential scan detected - consider adding index" }
    end
    
    if result.to_s.includes?("Sort")
      Log.info { "Sort operation - consider index on ORDER BY columns" }
    end
    
    result
  end
  
  # Suggest indexes based on query patterns
  def self.suggest_indexes(model)
    suggestions = [] of String
    
    # Check foreign keys
    model.associations.each do |assoc|
      if assoc.type == :belongs_to
        suggestions << "CREATE INDEX idx_#{model.table}_#{assoc.foreign_key} ON #{model.table}(#{assoc.foreign_key});"
      end
    end
    
    # Check commonly queried columns
    model.common_queries.each do |query|
      columns = extract_where_columns(query)
      if columns.size == 1
        suggestions << "CREATE INDEX idx_#{model.table}_#{columns.first} ON #{model.table}(#{columns.first});"
      elsif columns.size > 1
        suggestions << "CREATE INDEX idx_#{model.table}_#{columns.join("_")} ON #{model.table}(#{columns.join(", ")});"
      end
    end
    
    suggestions.uniq
  end
end
```

### Composite Indexes

```crystal
# Migration with composite indexes
class AddPerformanceIndexes < Grant::Migration
  def up
    # Composite index for common query pattern
    add_index :posts, [:user_id, :published, :created_at], 
              name: "idx_posts_user_published_recent"
    
    # Partial index for specific conditions
    execute <<-SQL
      CREATE INDEX idx_active_users_email 
      ON users(email) 
      WHERE active = true;
    SQL
    
    # Index for full-text search (PostgreSQL)
    execute <<-SQL
      CREATE INDEX idx_posts_title_gin 
      ON posts USING gin(to_tsvector('english', title));
    SQL
    
    # Index for JSON columns (PostgreSQL)
    execute <<-SQL
      CREATE INDEX idx_users_metadata 
      ON users USING gin(metadata);
    SQL
  end
end
```

### Index Usage Verification

```crystal
# Check if indexes are being used
class Post < Grant::Base
  def self.verify_index_usage
    queries = [
      {name: "by_user", sql: where(user_id: 1).to_sql},
      {name: "published", sql: where(published: true).to_sql},
      {name: "recent", sql: order(created_at: :desc).limit(10).to_sql}
    ]
    
    queries.each do |query|
      plan = connection.query("EXPLAIN #{query[:sql]}")
      uses_index = plan.to_s.includes?("Index Scan") || 
                   plan.to_s.includes?("Bitmap Index Scan")
      
      Log.info { "Query '#{query[:name]}': #{uses_index ? "✓ Uses index" : "✗ No index"}" }
    end
  end
end
```

## Query Optimization Techniques

### Selective Loading

```crystal
# Load only needed columns
users = User.select(:id, :name, :email)
            .where(active: true)

# Avoid loading large columns unnecessarily
posts = Post.select("id, title, created_at, substring(content, 1, 100) as preview")
            .where(published: true)

# Use pluck for single columns
user_emails = User.where(newsletter: true).pluck(:email)
user_ids = User.where(active: true).pluck(:id)

# Use pick for single value
latest_post_id = Post.order(created_at: :desc).pick(:id)
```

### Batch Operations

```crystal
# Batch updates without loading records
User.where(last_login: nil).update_all(active: false)

# Batch inserts
users_data = [
  {name: "User1", email: "user1@example.com"},
  {name: "User2", email: "user2@example.com"},
  # ... many more
]

User.insert_all(users_data)  # Single INSERT statement

# Upsert (insert or update)
User.upsert_all(
  users_data,
  unique_by: :email,
  update_only: [:name, :updated_at]
)
```

### Query Result Caching

```crystal
class CachedQuery
  @@cache = {} of String => {Time, Array(Grant::Base)}
  
  def self.fetch(key : String, ttl : Time::Span = 5.minutes, &)
    if cached = @@cache[key]?
      expires_at, result = cached
      return result if expires_at > Time.utc
    end
    
    result = yield
    @@cache[key] = {Time.utc + ttl, result}
    result
  end
  
  def self.clear(key : String? = nil)
    key ? @@cache.delete(key) : @@cache.clear
  end
end

# Usage
popular_posts = CachedQuery.fetch("popular_posts", 1.hour) do
  Post.where(published: true)
      .where.gteq(:views, 1000)
      .order(views: :desc)
      .limit(10)
      .includes(:author)
      .to_a
end
```

### Database Views

```crystal
# Create materialized view for complex queries
class CreatePopularPostsView < Grant::Migration
  def up
    execute <<-SQL
      CREATE MATERIALIZED VIEW popular_posts AS
      SELECT 
        p.*,
        u.name as author_name,
        COUNT(c.id) as comment_count,
        AVG(r.rating) as avg_rating
      FROM posts p
      JOIN users u ON p.user_id = u.id
      LEFT JOIN comments c ON c.post_id = p.id
      LEFT JOIN ratings r ON r.post_id = p.id
      WHERE p.published = true
      GROUP BY p.id, u.name
      HAVING COUNT(c.id) > 10
      ORDER BY avg_rating DESC, comment_count DESC;
      
      CREATE INDEX idx_popular_posts_rating ON popular_posts(avg_rating);
    SQL
  end
end

# Model for the view
class PopularPost < Grant::Base
  table "popular_posts"
  
  # Refresh materialized view
  def self.refresh!
    connection.execute("REFRESH MATERIALIZED VIEW popular_posts")
  end
end
```

## Performance Monitoring

### Query Performance Metrics

```crystal
class PerformanceMonitor
  @@metrics = [] of NamedTuple(
    query: String,
    duration: Float64,
    rows: Int32,
    timestamp: Time
  )
  
  def self.track(&)
    Grant::Instrumentation.subscribe("query.grant") do |event|
      @@metrics << {
        query: event.payload[:sql],
        duration: event.duration.total_milliseconds,
        rows: event.payload[:row_count] || 0,
        timestamp: Time.utc
      }
    end
    
    yield
    
    analyze_metrics
  end
  
  private def self.analyze_metrics
    {
      total_queries: @@metrics.size,
      total_time: @@metrics.sum(&.[:duration]),
      avg_time: @@metrics.sum(&.[:duration]) / @@metrics.size,
      slowest: @@metrics.max_by(&.[:duration]),
      most_rows: @@metrics.max_by(&.[:rows])
    }
  end
end
```

### Database Connection Pooling

```crystal
# Configure connection pool for optimal performance
Grant.configure do |config|
  config.connection_pool_size = 25      # Match expected concurrency
  config.checkout_timeout = 5.seconds   # Fail fast on pool exhaustion
  config.idle_timeout = 300.seconds     # Return idle connections
  config.max_lifetime = 1.hour         # Prevent connection staleness
end

# Monitor pool usage
class PoolMonitor
  def self.stats
    pool = Grant.connection_pool
    
    {
      size: pool.size,
      available: pool.available,
      in_use: pool.size - pool.available,
      waiting: pool.waiting_count,
      health: pool.available.to_f / pool.size
    }
  end
  
  def self.alert_if_exhausted
    stats = self.stats
    if stats[:health] < 0.2
      Log.error { "Connection pool nearly exhausted: #{stats}" }
    end
  end
end
```

## Query Optimization Patterns

### Pagination Optimization

```crystal
# Cursor-based pagination (more efficient for large datasets)
class CursorPagination
  def self.paginate(scope, cursor: nil, limit: 20)
    query = scope.limit(limit + 1)
    query = query.where.gt(:id, cursor) if cursor
    
    results = query.to_a
    has_more = results.size > limit
    results = results.first(limit) if has_more
    
    {
      data: results,
      next_cursor: has_more ? results.last.id : nil,
      has_more: has_more
    }
  end
end

# Usage
page1 = CursorPagination.paginate(Post.order(:id))
page2 = CursorPagination.paginate(Post.order(:id), cursor: page1[:next_cursor])
```

### Aggregation Optimization

```crystal
# Use database aggregations instead of Ruby
class Statistics
  def self.user_stats
    User.select(
      "COUNT(*) as total_users",
      "COUNT(CASE WHEN active THEN 1 END) as active_users",
      "AVG(age) as average_age",
      "MIN(created_at) as first_user_date",
      "MAX(created_at) as latest_user_date"
    ).first
  end
  
  def self.grouped_stats
    Post.group(:category_id)
        .select(
          "category_id",
          "COUNT(*) as post_count",
          "AVG(views) as avg_views",
          "SUM(comments_count) as total_comments"
        )
  end
end
```

### Join Optimization

```crystal
# Optimize joins with selective loading
posts_with_authors = Post
  .joins(:author)
  .select("posts.*, users.name as author_name, users.email as author_email")
  .where(published: true)

# Use left joins when association might not exist
posts_with_optional_category = Post
  .left_joins(:category)
  .select("posts.*, categories.name as category_name")
  
# Avoid joins when possible
user_ids = [1, 2, 3, 4, 5]
# Bad: Join
posts = Post.joins(:author).where(users: {id: user_ids})

# Good: Direct foreign key query
posts = Post.where(user_id: user_ids)
```

## Best Practices

### 1. Profile Before Optimizing

```crystal
# Always measure first
def measure_query(&)
  start = Time.monotonic
  result = yield
  duration = Time.monotonic - start
  
  Log.info { "Query took #{duration.total_milliseconds}ms" }
  result
end

posts = measure_query { Post.complex_scope.to_a }
```

### 2. Use Database Indexes Wisely

```crystal
# Good: Index on foreign keys and commonly queried columns
add_index :posts, :user_id
add_index :posts, [:published, :created_at]

# Bad: Too many indexes slow down writes
# Don't index every column
```

### 3. Avoid SELECT *

```crystal
# Bad
User.all

# Good
User.select(:id, :name, :email)
```

### 4. Use Batch Loading

```crystal
# Bad: Load everything at once
Post.where(published: true).each do |post|
  process(post)
end

# Good: Process in batches
Post.where(published: true).find_in_batches(batch_size: 100) do |posts|
  posts.each { |post| process(post) }
end
```

## Troubleshooting

### Slow Query Diagnosis

```crystal
# Enable slow query logging
Grant.configure do |config|
  config.slow_query_threshold = 100.ms
  config.on_slow_query = ->(sql : String, duration : Time::Span) {
    Log.error { "Slow query (#{duration.total_milliseconds}ms): #{sql}" }
    
    # Auto-explain slow queries
    explain = Grant.connection.query("EXPLAIN ANALYZE #{sql}")
    Log.error { "Query plan:\n#{explain}" }
  }
end
```

### Memory Usage

```crystal
# Monitor memory usage during queries
class MemoryMonitor
  def self.track(&)
    before = GC.stats.heap_size
    result = yield
    after = GC.stats.heap_size
    
    Log.info { "Memory delta: #{(after - before) / 1024}KB" }
    result
  end
end

# Large result sets
MemoryMonitor.track do
  Post.all.to_a  # Loads everything into memory
end
```

## Next Steps

- [Database Indexing](database-indexing.md)
- [Caching Strategies](caching-strategies.md)
- [Connection Pooling](connection-pooling.md)
- [Query Analysis](../instrumentation/query-analysis.md)