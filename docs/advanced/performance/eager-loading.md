---
title: "Eager Loading and N+1 Query Prevention"
category: "advanced"
subcategory: "performance"
tags: ["performance", "optimization", "eager-loading", "n+1", "includes", "preload", "database"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../../core-features/relationships.md", "../../core-features/querying-and-scopes.md"]
related_docs: ["query-optimization.md", "../../core-features/relationships.md", "../data-management/batch-operations.md"]
last_updated: "2025-01-13"
estimated_read_time: "15 minutes"
use_cases: ["api-optimization", "view-rendering", "report-generation", "data-export"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Eager Loading and N+1 Query Prevention

Comprehensive guide to optimizing database queries through eager loading, preventing N+1 query problems, and improving application performance by efficiently loading associated data.

## Overview

The N+1 query problem is one of the most common performance issues in database-driven applications. It occurs when your code executes one query to fetch primary records, then N additional queries to fetch associated records for each of those N primary records. Grant provides powerful eager loading capabilities to solve this problem.

### The N+1 Problem

```crystal
# BAD: N+1 queries (1 + 100 = 101 queries)
posts = Post.limit(100)  # Query 1
posts.each do |post|
  puts post.author.name  # Queries 2-101 (one per post)
end

# GOOD: Eager loading (2 queries total)
posts = Post.includes(:author).limit(100)  # Query 1 + 1 join
posts.each do |post|
  puts post.author.name  # No additional queries
end
```

## Basic Eager Loading

### Single Association

```crystal
# Eager load a belongs_to association
posts = Post.includes(:author)

# Eager load a has_many association
users = User.includes(:posts)

# Eager load a has_one association
users = User.includes(:profile)

# Access loaded associations without additional queries
posts.each do |post|
  puts "#{post.title} by #{post.author.name}"
end
```

### Multiple Associations

```crystal
# Load multiple associations at once
posts = Post.includes(:author, :comments, :tags)

# Each association is loaded efficiently
posts.each do |post|
  puts "#{post.title} by #{post.author.name}"
  puts "Comments: #{post.comments.size}"
  puts "Tags: #{post.tags.map(&.name).join(", ")}"
end
```

### Nested Associations

```crystal
# Load associations of associations
users = User.includes(posts: [:comments, :tags])

# Deep nesting
users = User.includes(
  posts: {
    comments: :author,
    tags: :category
  }
)

# Access deeply nested data efficiently
users.each do |user|
  user.posts.each do |post|
    post.comments.each do |comment|
      puts "#{comment.author.name}: #{comment.body}"
    end
  end
end
```

## Eager Loading Strategies

### includes vs preload vs eager_load

Grant provides different strategies for eager loading:

```crystal
# includes - Smart loading (decides between preload and eager_load)
Post.includes(:comments)
# Uses separate queries when possible (better for memory)
# Falls back to JOIN when necessary (with conditions)

# preload - Always uses separate queries
Post.preload(:comments)
# SELECT * FROM posts
# SELECT * FROM comments WHERE post_id IN (1, 2, 3, ...)

# eager_load - Always uses LEFT OUTER JOIN
Post.eager_load(:comments)
# SELECT posts.*, comments.* FROM posts
# LEFT OUTER JOIN comments ON comments.post_id = posts.id

# joins - INNER JOIN without loading (for filtering only)
Post.joins(:comments).where(comments: {approved: true})
```

### Choosing the Right Strategy

```crystal
# Use includes for most cases (automatic optimization)
posts = Post.includes(:author, :comments)

# Use preload when you know separate queries are better
# (Large associations, avoiding JOIN complexity)
users = User.preload(:orders)  # If users have many orders

# Use eager_load when you need a JOIN
# (Ordering by associated column, complex conditions)
posts = Post.eager_load(:author)
            .order("users.name")

# Use joins when you only need to filter, not load
popular_posts = Post.joins(:comments)
                    .group("posts.id")
                    .having("COUNT(comments.id) > ?", 10)
```

## Conditional Eager Loading

### Dynamic Includes

```crystal
class PostsController
  def index
    posts = Post.all
    
    # Conditionally add includes based on parameters
    posts = posts.includes(:author) if params[:with_author]
    posts = posts.includes(:comments) if params[:with_comments]
    posts = posts.includes(:tags) if params[:with_tags]
    
    posts
  end
end

# Or using a method
def posts_with_includes(include_opts = {})
  query = Post.all
  
  includes = []
  includes << :author if include_opts[:author]
  includes << :comments if include_opts[:comments]
  includes << {comments: :author} if include_opts[:comment_authors]
  
  includes.any? ? query.includes(*includes) : query
end
```

### Scoped Associations

```crystal
class Post < Grant::Base
  has_many :comments
  has_many :approved_comments, -> { where(approved: true) }, class_name: "Comment"
  has_many :recent_comments, -> { order(created_at: :desc).limit(5) }, class_name: "Comment"
end

# Eager load scoped associations
posts = Post.includes(:approved_comments, :recent_comments)

# The scoped conditions are applied during eager loading
posts.each do |post|
  puts "Approved: #{post.approved_comments.size}"
  puts "Recent: #{post.recent_comments.map(&.body)}"
end
```

## Advanced Patterns

### Polymorphic Associations

```crystal
class Comment < Grant::Base
  belongs_to :commentable, polymorphic: true
end

class Post < Grant::Base
  has_many :comments, as: :commentable
end

class Video < Grant::Base
  has_many :comments, as: :commentable
end

# Eager load polymorphic associations
comments = Comment.includes(:commentable)

# Grant handles different types automatically
comments.each do |comment|
  case comment.commentable
  when Post
    puts "Comment on post: #{comment.commentable.title}"
  when Video
    puts "Comment on video: #{comment.commentable.name}"
  end
end
```

### Self-Referential Associations

```crystal
class Category < Grant::Base
  belongs_to :parent, class_name: "Category", foreign_key: "parent_id"
  has_many :children, class_name: "Category", foreign_key: "parent_id"
end

# Load hierarchy efficiently
categories = Category.includes(children: {children: :children})

# Traverse without N+1
categories.each do |category|
  puts category.name
  category.children.each do |child|
    puts "  #{child.name}"
    child.children.each do |grandchild|
      puts "    #{grandchild.name}"
    end
  end
end
```

### Through Associations

```crystal
class Doctor < Grant::Base
  has_many :appointments
  has_many :patients, through: :appointments
end

class Patient < Grant::Base
  has_many :appointments
  has_many :doctors, through: :appointments
end

# Eager load through associations
doctors = Doctor.includes(:patients)

# Or load the join model too
doctors = Doctor.includes(appointments: :patient)
```

## Performance Optimization

### Selective Column Loading

```crystal
# Load only needed columns to reduce memory usage
posts = Post.select(:id, :title, :author_id)
            .includes(:author)

# For associations
users = User.includes(:posts)
            .references(:posts)
            .select("users.*, posts.id, posts.title")
```

### Batch Loading

```crystal
# Process large datasets in batches with eager loading
Post.includes(:author, :comments)
    .find_in_batches(batch_size: 100) do |posts|
  posts.each do |post|
    # Process post with preloaded associations
    ProcessPostJob.perform_later(post)
  end
end

# Using find_each
User.includes(:profile)
    .find_each(batch_size: 500) do |user|
  # Process each user with profile loaded
  user.profile.update!(last_accessed: Time.utc)
end
```

### Counter Caches

```crystal
class Post < Grant::Base
  has_many :comments
  # Add comments_count column to posts table
end

class Comment < Grant::Base
  belongs_to :post, counter_cache: true
end

# No need to load comments just for count
posts = Post.all
posts.each do |post|
  puts "#{post.title} (#{post.comments_count} comments)"
end
```

## Query Analysis

### Detecting N+1 Queries

```crystal
# Use Grant's query analysis
Grant::Instrumentation.analyze do
  posts = Post.all
  posts.each do |post|
    puts post.author.name  # N+1 detected!
  end
end
# => Warning: N+1 query detected for Post#author

# Enable logging to see all queries
Grant.logger.level = Logger::DEBUG

# Use bullet gem equivalent for Crystal
class N1Detector
  def self.detect(&)
    query_count = Hash(String, Int32).new(0)
    
    Grant::Instrumentation.subscribe("query.grant") do |event|
      sql = event.payload[:sql]
      query_count[sql] += 1
    end
    
    yield
    
    # Report potential N+1s
    query_count.select { |_, count| count > 10 }
  end
end
```

### Measuring Performance

```crystal
require "benchmark"

# Compare with and without eager loading
Benchmark.bm do |x|
  x.report("without eager loading") do
    posts = Post.limit(100)
    posts.each { |p| p.author.name }
  end
  
  x.report("with eager loading") do
    posts = Post.includes(:author).limit(100)
    posts.each { |p| p.author.name }
  end
end
```

## Common Patterns

### API Responses

```crystal
class PostSerializer
  def self.collection(posts, includes: [] of Symbol)
    # Base query with common associations
    posts = posts.includes(:author, :category)
    
    # Optional associations based on API params
    posts = posts.includes(:comments) if includes.includes?(:comments)
    posts = posts.includes(:tags) if includes.includes?(:tags)
    
    posts.map { |post| serialize(post) }
  end
  
  def self.serialize(post)
    {
      id: post.id,
      title: post.title,
      author: {
        id: post.author.id,
        name: post.author.name
      },
      category: post.category.name,
      comments_count: post.comments.size,
      tags: post.tags.map(&.name)
    }
  end
end

# Usage in controller
posts = PostSerializer.collection(
  Post.published,
  includes: [:comments, :tags]
)
```

### View Rendering

```crystal
# In controller
@posts = Post.published
             .includes(:author, comments: :author)
             .page(params[:page])

# In view (no N+1 queries)
@posts.each do |post|
  h.div(class: "post") do
    h.h2 post.title
    h.p "by #{post.author.name}"
    
    h.div(class: "comments") do
      post.comments.each do |comment|
        h.div(class: "comment") do
          h.strong comment.author.name
          h.p comment.body
        end
      end
    end
  end
end
```

### Report Generation

```crystal
class SalesReport
  def self.generate(date_range)
    # Load all data needed for report in minimal queries
    orders = Order.includes(
      :customer,
      :sales_rep,
      line_items: [:product, :discount]
    ).where(created_at: date_range)
    
    {
      total_revenue: calculate_revenue(orders),
      by_customer: group_by_customer(orders),
      by_product: group_by_product(orders),
      by_sales_rep: group_by_sales_rep(orders)
    }
  end
  
  private def self.calculate_revenue(orders)
    orders.sum do |order|
      order.line_items.sum(&.total)  # No N+1
    end
  end
end
```

## Anti-Patterns to Avoid

### Over-Eager Loading

```crystal
# BAD: Loading unnecessary associations
posts = Post.includes(:author, :comments, :tags, :category, :ratings)
            .limit(10)
# Only using title in view

# GOOD: Load only what you need
posts = Post.limit(10)  # Just the posts

# BETTER: Select only needed columns
posts = Post.select(:id, :title).limit(10)
```

### Eager Loading in Loops

```crystal
# BAD: Eager loading inside a loop
users.each do |user|
  # This creates a new query with includes each time
  posts = user.posts.includes(:comments)
end

# GOOD: Eager load at the top level
users = User.includes(posts: :comments)
users.each do |user|
  posts = user.posts  # Already loaded
end
```

### Conditional Association Access

```crystal
# BAD: Accessing associations conditionally
posts = Post.includes(:author)
posts.each do |post|
  # Author is loaded but might not be used
  puts post.author.name if post.featured?
end

# GOOD: Split queries if conditions are rare
featured_posts = Post.featured.includes(:author)
regular_posts = Post.not_featured  # No includes needed
```

## Best Practices

### 1. Profile First

```crystal
# Always measure before optimizing
class QueryProfiler
  def self.profile(name, &)
    start = Time.monotonic
    query_count = 0
    
    Grant::Instrumentation.subscribe("query.grant") do |_|
      query_count += 1
    end
    
    result = yield
    
    duration = Time.monotonic - start
    puts "#{name}: #{duration.total_milliseconds}ms, #{query_count} queries"
    
    result
  end
end

QueryProfiler.profile("posts index") do
  Post.includes(:author, :comments).to_a
end
```

### 2. Use Scopes

```crystal
class Post < Grant::Base
  # Define reusable eager loading scopes
  scope :with_author, -> { includes(:author) }
  scope :with_comments, -> { includes(:comments) }
  scope :with_all, -> { includes(:author, :comments, :tags) }
  
  # Compose as needed
  scope :for_index, -> { with_author.published.recent }
  scope :for_detail, -> { with_all }
end

# Clean controller code
Post.for_index.page(params[:page])
Post.for_detail.find(params[:id])
```

### 3. Default Includes

```crystal
class Comment < Grant::Base
  belongs_to :author, class_name: "User"
  
  # Always load author by default
  default_scope { includes(:author) }
  
  # Or conditional default
  def self.default_scope
    current_user.admin? ? all : includes(:author)
  end
end
```

### 4. Lazy Loading Detection

```crystal
class Post < Grant::Base
  # Detect lazy loading in development
  def author
    if !association_loaded?(:author) && Grant.env.development?
      Log.warn { "Lazy loading Post#author - consider eager loading" }
    end
    super
  end
end
```

## Testing Eager Loading

```crystal
describe Post do
  describe "eager loading" do
    it "prevents N+1 queries" do
      create_list(:post, 3, :with_author)
      
      query_count = 0
      Grant::Instrumentation.subscribe("query.grant") do |_|
        query_count += 1
      end
      
      posts = Post.includes(:author).to_a
      posts.each(&.author.name)
      
      # Should be 2 queries: one for posts, one for authors
      query_count.should eq(2)
    end
    
    it "loads nested associations" do
      user = create(:user, :with_posts_and_comments)
      
      loaded_user = User.includes(posts: :comments).find(user.id)
      
      # Check associations are loaded
      loaded_user.association_loaded?(:posts).should be_true
      loaded_user.posts.first.association_loaded?(:comments).should be_true
    end
  end
end
```

## Troubleshooting

### Association Not Loading

```crystal
# Check if association is actually loaded
post.association_loaded?(:author)  # => false

# Force reload
post.reload_author

# Check includes syntax
Post.includes(:authors)  # Wrong: should be :author
Post.includes(:author)   # Correct
```

### Memory Issues with Large Datasets

```crystal
# Don't load everything at once
# BAD
User.includes(:posts).to_a  # Loads all users and all posts

# GOOD - Use batches
User.includes(:posts).find_in_batches do |users|
  users.each { |u| process(u) }
end

# BETTER - Paginate
User.includes(:posts).page(1).per(50)
```

### Duplicate Data in Joins

```crystal
# Problem: DISTINCT needed with eager_load
Post.eager_load(:tags).count  # Wrong count due to JOIN

# Solution: Use distinct
Post.eager_load(:tags).distinct.count

# Or use includes (separate queries)
Post.includes(:tags).count
```

## Next Steps

- [Query Optimization](query-optimization.md)
- [Database Indexing](database-indexing.md)
- [Caching Strategies](caching-strategies.md)
- [Batch Operations](../data-management/batch-operations.md)