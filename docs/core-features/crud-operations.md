---
title: "CRUD Operations"
category: "core-features"
subcategory: "operations"
tags: ["crud", "create", "read", "update", "delete", "database", "queries"]
complexity: "beginner"
version: "1.0.0"
prerequisites: ["../getting-started/first-model.md", "models-and-columns.md"]
related_docs: ["querying-and-scopes.md", "validations.md", "callbacks-lifecycle.md", "../advanced/performance/query-optimization.md"]
last_updated: "2025-01-13"
estimated_read_time: "15 minutes"
use_cases: ["data-manipulation", "database-operations", "api-development"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# CRUD Operations

Complete guide to Create, Read, Update, and Delete operations in Grant ORM, including bulk operations and advanced techniques.

## Create Operations

### Basic Creation

```crystal
# Method 1: Create and save in one step
post = Post.create(
  title: "Grant ORM Guide",
  content: "Learn how to use Grant effectively",
  published: true
)

if post.persisted?
  puts "Created post with ID: #{post.id}"
else
  puts "Errors: #{post.errors.full_messages.join(", ")}"
end

# Method 2: Create with exception on failure
post = Post.create!(
  title: "Grant ORM Guide",
  content: "Learn how to use Grant effectively"
)
# Raises Grant::RecordNotSaved if validation fails
```

### Step-by-Step Creation

```crystal
# Method 1: New and save separately
post = Post.new
post.title = "My Post"
post.content = "Post content"
post.published = false

if post.save
  puts "Saved successfully"
else
  puts "Validation errors: #{post.errors.full_messages}"
end

# Method 2: New with block
post = Post.new do |p|
  p.title = "Another Post"
  p.content = "More content"
  p.author_id = current_user.id
end
post.save!

# Method 3: New with attributes
post = Post.new(
  title: "Third Post",
  content: "Content here",
  author_id: 1
)
post.save
```

### Skipping Callbacks and Timestamps

```crystal
# Skip timestamps
post = Post.create(
  {title: "No Timestamps", content: "Content"},
  skip_timestamps: true
)

# Skip validation
post = Post.new(title: "")
post.save(validate: false)  # Saves even with invalid data

# Skip callbacks
post.save(skip_callbacks: true)
```

### Bulk Creation

```crystal
# Create multiple records efficiently
users_data = [
  {name: "Alice", email: "alice@example.com", age: 25},
  {name: "Bob", email: "bob@example.com", age: 30},
  {name: "Charlie", email: "charlie@example.com", age: 35}
]

# Method 1: insert_all (single query, no validations)
User.insert_all(users_data)

# Method 2: With timestamps
User.insert_all(users_data, record_timestamps: true)

# Method 3: With returning (PostgreSQL/SQLite)
created_users = User.insert_all(
  users_data,
  returning: [:id, :name, :email]
)

# Method 4: Traditional loop (runs validations)
users = users_data.map do |data|
  User.create(data)
end
```

## Read Operations

### Finding by Primary Key

```crystal
# Find by ID
user = User.find(1)
if user
  puts user.name
end

# Find with exception
user = User.find!(1)  # Raises Grant::RecordNotFound if not found

# Find multiple by IDs
users = User.find([1, 2, 3])
# Returns array of found records (may be less than requested)
```

### Finding by Attributes

```crystal
# Find single record
user = User.find_by(email: "john@example.com")
user = User.find_by!(email: "john@example.com")  # Raises if not found

# Find with multiple conditions
post = Post.find_by(
  author_id: 1,
  published: true,
  category: "tech"
)

# Find or create
user = User.find_or_create_by(email: "new@example.com") do |u|
  u.name = "New User"
  u.age = 25
end

# Find or initialize (doesn't save)
user = User.find_or_initialize_by(email: "test@example.com")
user.new_record?  # => true if not found
```

### First, Last, and All

```crystal
# Get first record
first_user = User.first
first_user = User.first!  # Raises if table empty

# Get first N records
first_five = User.first(5)

# Get last record
last_user = User.last
last_user = User.last!

# Get last N records
last_ten = User.last(10)

# Get all records
all_users = User.all
all_users.each do |user|
  puts user.name
end

# Check existence
User.any?                    # => true if any records exist
User.none?                   # => true if no records exist
User.exists?(1)              # => true if record with ID 1 exists
User.exists?(email: "test@example.com")  # Check by attributes
```

### Reload

```crystal
user = User.find(1)
user.name = "Changed"

# Reload from database (discards changes)
user.reload
user.name  # => Original name from database

# Useful for refreshing associations
post = Post.find(1)
# ... comments added elsewhere ...
post.reload
post.comments.size  # => Updated count
```

### Selecting Specific Columns

```crystal
# Select only needed columns
users = User.select(:id, :name, :email)

# Exclude columns
users = User.select_all.except(:password_hash, :secret_token)

# With calculated columns
users = User.select("*, age * 2 as double_age")
```

### Pluck and Pick

```crystal
# Extract column values without instantiating models
names = User.pluck(:name)
# => ["Alice", "Bob", "Charlie"]

# Multiple columns
data = User.pluck(:id, :name, :email)
# => [[1, "Alice", "alice@example.com"], ...]

# Pick first result only
first_name = User.pick(:name)
# => "Alice"

first_data = User.where(active: true).pick(:id, :name)
# => [1, "Alice"]
```

## Update Operations

### Individual Updates

```crystal
# Method 1: Find, modify, save
user = User.find(1)
user.name = "Updated Name"
user.email = "new@example.com"

if user.save
  puts "Updated successfully"
else
  puts "Errors: #{user.errors.full_messages}"
end

# Method 2: Update attributes and save
user = User.find(1)
user.update(
  name: "New Name",
  email: "newemail@example.com"
)

# Method 3: Update with exception
user.update!(name: "Must Work")  # Raises if validation fails

# Method 4: Update single attribute (skips validation)
user.update_attribute(:last_login, Time.utc)

# Method 5: Update columns directly (skips everything)
user.update_columns(
  name: "Direct Update",
  updated_at: Time.utc
)
```

### Mass Updates

```crystal
# Update all matching records
User.where(active: false).update_all(
  status: "inactive",
  deactivated_at: Time.utc
)

# Update with SQL fragments
Post.where(published: true).update_all(
  "view_count = view_count + 1"
)

# Conditional updates
User.where("last_login < ?", [30.days.ago])
    .update_all(active: false)
```

### Increment and Decrement

```crystal
# Increment a numeric column
post = Post.find(1)
post.increment(:view_count)      # +1
post.increment(:view_count, 5)   # +5
post.save

# Increment and save
post.increment!(:view_count)

# Decrement
post.decrement(:stock_quantity)
post.decrement!(:stock_quantity, 10)

# Toggle boolean
user = User.find(1)
user.toggle(:active)   # true -> false, false -> true
user.save

user.toggle!(:email_verified)  # Toggle and save
```

### Touch

```crystal
# Update timestamps
post = Post.find(1)
post.touch  # Updates updated_at

# Touch specific timestamp
post.touch(:published_at)

# Touch associated records
comment = Comment.find(1)
comment.touch(include_parent: true)  # Also touches parent post
```

### Upsert (Insert or Update)

```crystal
# Single record upsert
User.upsert(
  {email: "john@example.com", name: "John Doe", age: 30},
  unique_by: [:email]
)

# Bulk upsert
User.upsert_all([
  {email: "alice@example.com", name: "Alice", age: 25},
  {email: "bob@example.com", name: "Bob", age: 30}
], unique_by: [:email])

# Update only specific columns on conflict
Product.upsert_all([
  {sku: "WIDGET-1", name: "Widget", price: 19.99, stock: 100}
], 
  unique_by: [:sku],
  update_only: [:price, :stock]
)
```

## Delete Operations

### Individual Deletion

```crystal
# Method 1: Find and destroy
user = User.find(1)
if user.destroy
  puts "Deleted successfully"
else
  puts "Could not delete: #{user.errors.full_messages}"
end

# Method 2: Destroy with exception
user.destroy!  # Raises if callbacks prevent deletion

# Check if destroyed
user.destroyed?  # => true

# Method 3: Delete by ID (skips callbacks)
User.delete(1)

# Method 4: Delete by IDs
User.delete([1, 2, 3])
```

### Mass Deletion

```crystal
# Delete all matching records (skips callbacks)
User.where(active: false).delete_all

# Destroy all matching records (runs callbacks)
User.where(spam: true).destroy_all

# Clear entire table (truncate)
User.clear

# Conditional deletion
Post.where("created_at < ?", [1.year.ago]).delete_all
```

### Soft Deletes

```crystal
# Implementation example
class User < Grant::Base
  column id : Int64, primary: true
  column deleted_at : Time?
  
  # Default scope excludes soft-deleted
  scope active { where(deleted_at: nil) }
  
  # Include soft-deleted
  scope with_deleted { unscoped }
  
  # Only soft-deleted
  scope deleted { unscoped.where.not(deleted_at: nil) }
  
  def soft_delete
    update(deleted_at: Time.utc)
  end
  
  def restore
    update(deleted_at: nil)
  end
  
  def really_destroy!
    destroy!
  end
end

# Usage
user = User.find(1)
user.soft_delete

# Won't find soft-deleted
User.find(1)  # => nil

# Will find soft-deleted
User.with_deleted.find(1)  # => User

# Restore
user.restore
```

## Batch Processing

### Find in Batches

```crystal
# Process records in batches
User.find_in_batches(batch_size: 1000) do |users|
  users.each do |user|
    UserMailer.send_newsletter(user)
  end
end

# With conditions
User.where(subscribed: true)
    .find_in_batches(batch_size: 500) do |users|
  # Process batch
end
```

### In Batches

```crystal
# Process with query methods available
User.in_batches(of: 1000) do |batch|
  batch.update_all(processed: true)
end

# With start and finish
User.in_batches(
  of: 500,
  start: 1000,
  finish: 5000
) do |batch|
  # Process IDs 1000-5000
end

# Load records if needed
User.in_batches do |batch|
  batch.each do |user|  # Loads records
    user.process!
  end
end
```

## Transaction Support

```crystal
# Wrap operations in transaction
Grant::Base.transaction do
  user = User.create!(name: "John")
  account = Account.create!(user: user, balance: 0)
  
  # Rolls back if any operation fails
end

# Manual rollback
Grant::Base.transaction do
  user = User.create!(name: "Jane")
  
  if user.email.blank?
    raise Grant::Rollback.new
  end
  
  account = Account.create!(user: user)
end

# Nested transactions (savepoints)
User.transaction do
  user1 = User.create!(name: "User 1")
  
  User.transaction do
    user2 = User.create!(name: "User 2")
    # Inner transaction can roll back independently
  end
end
```

## Performance Tips

### 1. Use Bulk Operations

```crystal
# Bad: N+1 inserts
users.each { |data| User.create(data) }

# Good: Single insert
User.insert_all(users)
```

### 2. Select Only Needed Columns

```crystal
# Bad: Loads all columns
users = User.all

# Good: Loads only what's needed
users = User.select(:id, :name, :email)
```

### 3. Use Pluck for Values

```crystal
# Bad: Instantiates models
emails = User.all.map(&.email)

# Good: Direct column access
emails = User.pluck(:email)
```

### 4. Batch Large Operations

```crystal
# Bad: Loads all records at once
User.all.each(&.process!)

# Good: Processes in batches
User.find_in_batches(batch_size: 1000) do |users|
  users.each(&.process!)
end
```

### 5. Use Update_all for Mass Updates

```crystal
# Bad: N queries
Post.where(draft: true).each do |post|
  post.update(published: false)
end

# Good: Single query
Post.where(draft: true).update_all(published: false)
```

## Common Patterns

### Find or Create

```crystal
# Find or create with attributes
user = User.find_or_create_by(email: "test@example.com") do |u|
  u.name = "Test User"
  u.age = 25
end
```

### Existence Checks

```crystal
# Check before operating
if User.exists?(email: "test@example.com")
  puts "Email already taken"
else
  User.create(email: "test@example.com", name: "New User")
end
```

### Conditional Updates

```crystal
# Update only if changed
user = User.find(1)
if user.email != new_email
  user.update(email: new_email)
end
```

### Safe Navigation

```crystal
# Handle missing records gracefully
User.find_by(email: email).try do |user|
  user.update(last_login: Time.utc)
end
```

## Error Handling

```crystal
begin
  user = User.create!(invalid_data)
rescue Grant::RecordInvalid => e
  puts "Validation failed: #{e.record.errors.full_messages}"
rescue Grant::RecordNotFound => e
  puts "Record not found: #{e.message}"
rescue Grant::RecordNotSaved => e
  puts "Save failed: #{e.record.errors.full_messages}"
rescue Grant::RecordNotDestroyed => e
  puts "Destroy failed: #{e.record.errors.full_messages}"
end
```

## Next Steps

- [Querying and Scopes](querying-and-scopes.md)
- [Validations](validations.md)
- [Callbacks and Lifecycle](callbacks-lifecycle.md)
- [Relationships](relationships.md)
- [Batch Processing](../advanced/performance/batch-processing.md)