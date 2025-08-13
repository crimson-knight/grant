---
title: "Quick Start Guide"
category: "core-features"
subcategory: "getting-started"
tags: ["tutorial", "quick-start", "beginner", "example"]
complexity: "beginner"
version: "1.0.0"
prerequisites: ["installation.md"]
related_docs: ["first-model.md", "database-setup.md", "../core-features/crud-operations.md"]
last_updated: "2025-01-13"
estimated_read_time: "15 minutes"
use_cases: ["web-development", "learning", "prototyping"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Quick Start Guide

Build a simple blog application in 15 minutes to learn Grant's core features.

## What We'll Build

A basic blog with:
- Posts with title and content
- Authors who write posts
- Comments on posts
- Categories for organizing posts

## Step 1: Project Setup (2 minutes)

Create a new Crystal project:

```bash
crystal init app my_blog
cd my_blog
```

Add Grant to `shard.yml`:

```yaml
dependencies:
  grant:
    github: amberframework/grant
  
  # Using SQLite for simplicity
  sqlite3:
    github: crystal-lang/crystal-sqlite3
```

Install dependencies:

```bash
shards install
```

## Step 2: Database Connection (1 minute)

Create `src/db.cr`:

```crystal
require "grant/adapter/sqlite"

# Configure database connection
Grant::Connections << Grant::Adapter::Sqlite.new(
  name: "sqlite",
  url: "sqlite3://./blog.db"
)
```

## Step 3: Define Models (5 minutes)

Create `src/models.cr`:

```crystal
require "./db"

# Author model
class Author < Grant::Base
  connection sqlite
  table authors
  
  column id : Int64, primary: true
  column name : String
  column email : String
  column bio : String?
  timestamps
  
  # Relationships
  has_many posts : Post
  has_many comments : Comment
  
  # Validations
  validate :name, "is required", ->(author : Author) { !author.name.blank? }
  validate :email, "must be valid", ->(author : Author) { 
    author.email.matches?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
  }
end

# Category model
class Category < Grant::Base
  connection sqlite
  table categories
  
  column id : Int64, primary: true
  column name : String
  column slug : String
  timestamps
  
  # Relationships
  has_many posts : Post
  
  # Validations
  validate_uniqueness :slug
end

# Post model
class Post < Grant::Base
  connection sqlite
  table posts
  
  column id : Int64, primary: true
  column title : String
  column content : String
  column published : Bool = false
  column views : Int32 = 0
  column author_id : Int64
  column category_id : Int64?
  timestamps
  
  # Relationships
  belongs_to author : Author
  belongs_to category : Category?
  has_many comments : Comment
  
  # Validations
  validate :title, "is required", ->(post : Post) { !post.title.blank? }
  validate :content, "minimum 10 characters", ->(post : Post) { 
    post.content.size >= 10 
  }
  
  # Scopes
  scope published { where(published: true) }
  scope draft { where(published: false) }
  scope popular { where("views > ?", [100]).order(views: :desc) }
  scope recent { order(created_at: :desc) }
  
  # Callbacks
  before_save :generate_slug
  
  def generate_slug
    # Simple slug generation (in production, use a proper slugging library)
    @title = title.downcase.gsub(/[^a-z0-9]+/, "-") if title_changed?
  end
end

# Comment model
class Comment < Grant::Base
  connection sqlite
  table comments
  
  column id : Int64, primary: true
  column content : String
  column author_id : Int64
  column post_id : Int64
  timestamps
  
  # Relationships
  belongs_to author : Author
  belongs_to post : Post
  
  # Validations
  validate :content, "is required", ->(c : Comment) { !c.content.blank? }
end
```

## Step 4: Create Database Tables (2 minutes)

Create `src/migrations.cr`:

```crystal
require "./models"

# Simple migration runner
class CreateTables
  def self.run
    db = Grant::Connections["sqlite"]
    
    # Create authors table
    db.exec <<-SQL
      CREATE TABLE IF NOT EXISTS authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name VARCHAR(255) NOT NULL,
        email VARCHAR(255) NOT NULL,
        bio TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    SQL
    
    # Create categories table
    db.exec <<-SQL
      CREATE TABLE IF NOT EXISTS categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name VARCHAR(255) NOT NULL,
        slug VARCHAR(255) NOT NULL UNIQUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    SQL
    
    # Create posts table
    db.exec <<-SQL
      CREATE TABLE IF NOT EXISTS posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title VARCHAR(255) NOT NULL,
        content TEXT NOT NULL,
        published BOOLEAN DEFAULT 0,
        views INTEGER DEFAULT 0,
        author_id INTEGER NOT NULL,
        category_id INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (author_id) REFERENCES authors(id),
        FOREIGN KEY (category_id) REFERENCES categories(id)
      )
    SQL
    
    # Create comments table
    db.exec <<-SQL
      CREATE TABLE IF NOT EXISTS comments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content TEXT NOT NULL,
        author_id INTEGER NOT NULL,
        post_id INTEGER NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (author_id) REFERENCES authors(id),
        FOREIGN KEY (post_id) REFERENCES posts(id)
      )
    SQL
    
    puts "✅ Tables created successfully!"
  end
end

CreateTables.run if ARGV.includes?("--migrate")
```

Run the migration:

```bash
crystal run src/migrations.cr -- --migrate
```

## Step 5: Working with Data (5 minutes)

Create `src/my_blog.cr`:

```crystal
require "./models"

# Create an author
author = Author.create(
  name: "Jane Doe",
  email: "jane@example.com",
  bio: "Tech blogger and Crystal enthusiast"
)
puts "Created author: #{author.name}"

# Create categories
tech = Category.create(name: "Technology", slug: "tech")
crystal = Category.create(name: "Crystal", slug: "crystal")

# Create a post
post = Post.new(
  title: "Getting Started with Grant ORM",
  content: "Grant is a powerful ORM for Crystal that makes database operations simple and intuitive.",
  author: author,
  category: crystal,
  published: true
)

if post.save
  puts "Created post: #{post.title}"
else
  puts "Errors: #{post.errors.full_messages.join(", ")}"
end

# Add a comment
comment = Comment.create(
  content: "Great article! Very helpful.",
  author: author,
  post: post
)

# Query data
puts "\n📝 All published posts:"
Post.published.recent.each do |p|
  puts "- #{p.title} by #{p.author.name}"
end

# Find posts with eager loading
puts "\n💬 Posts with comments:"
Post.all.includes(:comments, :author).each do |p|
  puts "#{p.title} (#{p.comments.size} comments)"
  p.comments.each do |c|
    puts "  - #{c.content}"
  end
end

# Update a post
post.views = post.views + 1
post.save

# Advanced queries
puts "\n🔍 Advanced queries:"

# Find posts by category
crystal_posts = Post.joins(:category).where("categories.slug = ?", ["crystal"])
puts "Crystal posts: #{crystal_posts.count}"

# Complex conditions
recent_popular = Post
  .published
  .where("created_at > ?", [7.days.ago])
  .where("views > ?", [50])
  .order(views: :desc)
  .limit(5)

puts "Recent popular posts: #{recent_popular.count}"

# Aggregations
total_views = Post.published.sum(:views)
avg_views = Post.published.average(:views)
puts "Total views: #{total_views}, Average: #{avg_views}"

# Raw SQL when needed
custom_results = Post.raw_query(
  "SELECT category_id, COUNT(*) as count 
   FROM posts 
   WHERE published = 1 
   GROUP BY category_id"
)
```

Run the application:

```bash
crystal run src/my_blog.cr
```

## What You've Learned

In this quick start, you've learned how to:

✅ **Set up Grant** with a database connection  
✅ **Define models** with columns and data types  
✅ **Create relationships** between models  
✅ **Add validations** to ensure data integrity  
✅ **Use callbacks** for automatic behaviors  
✅ **Query data** with scopes and conditions  
✅ **Perform CRUD operations** (Create, Read, Update, Delete)  
✅ **Use eager loading** to optimize queries  
✅ **Write complex queries** with joins and aggregations  

## Next Steps

### Explore More Features

- **[Dirty Tracking](../advanced/data-management/dirty-tracking.md)** - Track attribute changes
- **[Encryption](../advanced/security/encrypted-attributes.md)** - Secure sensitive data
- **[Async Operations](../infrastructure/async-operations/async-queries.md)** - Non-blocking queries
- **[Sharding](../infrastructure/multiple-databases/sharding-guide.md)** - Scale across databases

### Build Something Real

1. Add user authentication
2. Implement post categories and tags
3. Add search functionality
4. Create an API endpoint
5. Deploy to production

### Learn Best Practices

- **[Query Optimization](../advanced/performance/query-optimization.md)**
- **[Testing Models](../development/testing-guide.md)**
- **[Migration Strategies](../advanced/data-management/migrations.md)**

## Complete Example

Find the complete blog example with additional features at:
[github.com/amberframework/grant-examples](https://github.com/amberframework/grant-examples)

## Getting Help

- 📚 [Full Documentation](../README.md)
- 💬 [Community Chat](https://gitter.im/amberframework/amber)
- 🐛 [Report Issues](https://github.com/amberframework/grant/issues)
- 🤝 [Contribute](../development/contributing.md)