---
name: grant-crud-operations
description: Create, read, update, and delete operations in Grant ORM including bulk operations, batch processing, upserts, and convenience methods.
user-invocable: false
---

# Grant CRUD Operations

## Create Operations

### Basic Creation

```crystal
# Create and save in one step
post = Post.create(title: "Grant ORM Guide", content: "Learn Grant", published: true)
post.persisted?  # => true if saved successfully

# Create with exception on failure
post = Post.create!(title: "Grant ORM Guide")  # Raises Grant::RecordNotSaved on failure
```

### Step-by-Step Creation

```crystal
# New + save
post = Post.new
post.title = "My Post"
post.save       # => true/false
post.save!      # Raises on failure

# New with named args
post = Post.new(title: "My Post", content: "Content", author_id: 1)
post.save

# New with block
post = Post.new do |p|
  p.title = "Another Post"
  p.content = "More content"
end
post.save!
```

### Skipping Callbacks and Timestamps

```crystal
Post.create({title: "No Timestamps"}, skip_timestamps: true)
post.save(validate: false)        # Skip validation
post.save(skip_callbacks: true)   # Skip callbacks
```

### Bulk Creation

```crystal
# insert_all -- single SQL INSERT, no validations/callbacks
User.insert_all([
  {name: "Alice", email: "alice@example.com"},
  {name: "Bob", email: "bob@example.com"}
])

# With timestamps
User.insert_all(data, record_timestamps: true)

# With RETURNING (PostgreSQL/SQLite 3.35+)
created = User.insert_all(data, returning: [:id, :name, :email])
```

## Read Operations

### Finding by Primary Key

```crystal
user = User.find(1)       # => User? (nil if not found)
user = User.find!(1)      # Raises Grant::RecordNotFound
users = User.find([1, 2, 3])  # Array of found records
```

### Finding by Attributes

```crystal
user = User.find_by(email: "john@example.com")
user = User.find_by!(email: "john@example.com")  # Raises if not found
post = Post.find_by(author_id: 1, published: true, category: "tech")
```

### Find or Create / Find or Initialize

```crystal
user = User.find_or_create_by(email: "new@example.com") do |u|
  u.name = "New User"
end

user = User.find_or_initialize_by(email: "test@example.com")
user.new_record?  # => true if not found
```

### First, Last, All

```crystal
User.first            # => User?
User.first!           # Raises if empty
User.first(5)         # First 5 records
User.last             # => User?
User.last!            # Raises if empty
User.last(10)         # Last 10 records
User.all              # All records (iterable)
```

### Existence Checks

```crystal
User.any?                               # => true if any records
User.none?                              # => true if no records
User.exists?(1)                         # By ID
User.exists?(email: "test@example.com") # By attributes
User.where(published: true).exists?     # With query builder
```

### Sole / Find Sole By

Find exactly one record (raises if zero or multiple match):

```crystal
admin = User.where(role: "admin").sole
user = User.find_sole_by(email: "john@example.com")
# Raises Grant::Querying::NotFound or Grant::Querying::NotUnique
```

### Reload

```crystal
user = User.find(1)
user.name = "Changed"
user.reload            # Discards unsaved changes, re-fetches from DB
user.name              # => Original name
```

### Pluck and Pick

```crystal
# Extract column values without instantiating models
names = User.pluck(:name)              # => [["Alice"], ["Bob"]]
data = User.pluck(:id, :name, :email)  # => [[1, "Alice", "alice@..."], ...]

# Pick first result only
first_name = User.pick(:name)          # => "Alice"
first_data = User.where(active: true).pick(:id, :name)  # => [1, "Alice"]
```

### Selecting Specific Columns

```crystal
users = User.select(:id, :name, :email)
```

## Update Operations

### Individual Updates

```crystal
user = User.find(1)
user.name = "Updated Name"
user.save

user.update(name: "New Name", email: "new@example.com")
user.update!(name: "Must Work")       # Raises on failure

# Skip validation
user.update_attribute(:last_login, Time.utc)

# Direct SQL, skips callbacks/validation
user.update_columns(name: "Direct Update", updated_at: Time.utc)
```

### Mass Updates

```crystal
User.where(active: false).update_all(status: "inactive", deactivated_at: Time.utc)
Post.where(published: true).update_all("view_count = view_count + 1")
```

### Increment, Decrement, Toggle

```crystal
post.increment(:view_count)        # +1 (does not save)
post.increment(:view_count, 5)     # +5
post.increment!(:view_count)       # +1 and save

post.decrement!(:stock_quantity, 10)

user.toggle(:active)               # true <-> false
user.toggle!(:email_verified)      # Toggle and save
```

### Touch

```crystal
post.touch                          # Updates updated_at
post.touch(:published_at)           # Updates specific timestamp
comment.touch(include_parent: true) # Also touches parent
User.where(active: true).touch_all  # Touch all matching
```

### Upsert (Insert or Update)

```crystal
User.upsert(
  {email: "john@example.com", name: "John Doe", age: 30},
  unique_by: [:email]
)

User.upsert_all([
  {email: "alice@example.com", name: "Alice"},
  {email: "bob@example.com", name: "Bob"}
], unique_by: [:email])

Product.upsert_all(data, unique_by: [:sku], update_only: [:price, :stock])
```

### Update Counters

```crystal
Post.update_counters(post_id, {:views => 1, :comments_count => 2, :shares => -1})
```

## Delete Operations

### Individual Deletion

```crystal
user.destroy       # => true/false (runs callbacks)
user.destroy!      # Raises if fails
user.destroyed?    # => true

User.delete(1)           # By ID, skips callbacks
User.delete([1, 2, 3])   # Multiple IDs
```

### Mass Deletion

```crystal
User.where(active: false).delete_all     # Skips callbacks
User.where(spam: true).destroy_all       # Runs callbacks
Post.clear                               # Truncate table
```

### Destroy By / Delete By

```crystal
User.destroy_by(active: false)              # Find and destroy all matching
User.delete_by(spam: true)                  # Find and delete (no callbacks)
User.delete_by(role: "guest", last_login: ..1.year.ago)
```

## Batch Processing

```crystal
# Process records in batches (avoids loading all into memory)
User.find_in_batches(batch_size: 1000) do |users|
  users.each { |user| process(user) }
end

# With query methods available on batch
User.in_batches(of: 1000) do |batch|
  batch.update_all(processed: true)
end

# With start/finish constraints
User.in_batches(of: 500, start: 1000, finish: 5000) do |batch|
  # Process IDs 1000-5000
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

## Database Compatibility Notes

- **PostgreSQL 9.5+**: Full RETURNING clause, native ON CONFLICT DO UPDATE
- **MySQL 5.6+**: No RETURNING, uses INSERT ON DUPLICATE KEY UPDATE
- **SQLite 3.24.0+**: Required minimum for upsert; limited RETURNING (3.35+)
