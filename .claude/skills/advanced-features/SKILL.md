---
name: grant-advanced-features
description: Grant ORM advanced features including enum attributes, dirty tracking, serialized columns, value objects, horizontal sharding, and async operations.
user-invocable: false
---

# Grant Advanced Features

## Enum Attributes

Grant provides Rails-style enum attributes that generate helper methods, scopes, and validations.

### Defining Enums

```crystal
class Article < Grant::Base
  connection postgres
  table articles
  column id : Int64, primary: true
  column title : String

  enum Status
    Draft
    Published
    Archived
  end

  enum_attribute status : Status = :draft
end
```

### Generated Methods

```crystal
article = Article.new(title: "My Article")

# Predicate methods
article.draft?       # => true
article.published?   # => false

# Bang methods (set and persist conceptually)
article.published!
article.published?   # => true
article.status       # => Article::Status::Published

# Direct assignment
article.status = Article::Status::Archived
```

### Auto-Generated Scopes

```crystal
Article.draft.each { |a| puts a.title }
Article.published.where("created_at > ?", 30.days.ago).order(created_at: :desc)
Article.draft.count   # => 5
```

### Integer Storage

```crystal
class User < Grant::Base
  enum Role
    Guest = 0
    Member = 1
    Admin = 2
  end

  enum_attribute role : Role = :member, column_type: Int32
end
```

### Multiple Enum Attributes

```crystal
class Task < Grant::Base
  enum Status
    Pending
    InProgress
    Completed
    Cancelled
  end

  enum Priority
    Low
    Medium
    High
    Urgent
  end

  enum_attributes status: {type: Status, default: :pending},
                  priority: {type: Priority, default: :medium}
end
```

### Optional (Nilable) Enums

```crystal
enum_attribute category : Category?   # No default, can be nil
```

### Class Methods

```crystal
Article.statuses       # => [Status::Draft, Status::Published, Status::Archived]
Article.status_mapping # => {"draft" => Status::Draft, "published" => Status::Published, ...}
```

---

## Dirty Tracking

Grant tracks changes to model attributes, inspired by Rails ActiveRecord dirty tracking.

### Basic Usage

```crystal
user = User.find!(1)
user.changed?  # => false

user.name = "New Name"
user.changed?  # => true

user.save
user.changed?  # => false
```

### Per-Attribute Methods

For each column, Grant generates:

```crystal
user.name = "Jane"

user.name_changed?           # => true
user.name_was                # => "John" (original value)
user.name_change             # => {"John", "Jane"} (tuple)
user.email_changed?          # => false
user.email_change            # => nil
```

### Viewing All Changes

```crystal
user.name = "Jane"
user.email = "jane@example.com"

user.changed_attributes  # => ["name", "email"]
user.changes             # => {"name" => {"John", "Jane"}, "email" => {"john@...", "jane@..."}}
```

### After Save

```crystal
user.name = "Jane"
user.save

user.changed?              # => false
user.previous_changes      # => {"name" => {"John", "Jane"}}
user.saved_changes         # => {"name" => {"John", "Jane"}} (alias)
user.saved_change_to_attribute?("name")  # => true
user.attribute_before_last_save("name")  # => "John"
user.name_before_last_save               # => "John"
```

### Restoring Changes

```crystal
user.name = "Jane"
user.email = "jane@example.com"

user.restore_attributes(["name"])  # Restore only name
user.name   # => "John"
user.email  # => "jane@example.com" (still changed)

user.restore_attributes  # Restore all
```

### Edge Cases

```crystal
# Setting same value = not changed
user.name = user.name
user.name_changed?  # => false

# Reverting to original = not changed
user.name = "Jane"
user.name = "John"  # Back to original
user.name_changed?  # => false

# New records don't track changes until after first save
user = User.new(name: "John")
user.name_changed?  # => false
```

### Use in Callbacks

```crystal
before_save :unverify_email_if_changed

private def unverify_email_if_changed
  self.email_verified = false if email_changed?
end

after_save :send_verification_if_needed

private def send_verification_if_needed
  EmailService.send_verification(self) if saved_change_to_attribute?("email")
end
```

---

## Serialized Columns

Store structured data (JSON/YAML) in database columns with full type safety and dirty tracking.

### Setup

```crystal
class UserSettings
  include JSON::Serializable
  include Grant::SerializedObject  # For dirty tracking

  property theme : String = "light"
  property notifications_enabled : Bool = true
  property items_per_page : Int32 = 20
end

class User < Grant::Base
  column id : Int64, primary: true
  column name : String

  serialized_column :settings, UserSettings, format: :json
end
```

### Usage

```crystal
user = User.new(name: "John")
user.settings = UserSettings.new
user.settings.theme = "dark"
user.save

user.settings.theme  # => "dark"
user.settings_changed?  # => false (just saved)

user.settings.items_per_page = 50
user.settings_changed?  # => true
user.settings.changes   # => {"items_per_page" => {20, 50}}
user.save
```

### Format Options

```crystal
serialized_column :settings, MyType, format: :json    # JSON
serialized_column :preferences, MyType, format: :jsonb # JSONB (PostgreSQL)
serialized_column :config, MyType, format: :yaml       # YAML
```

### Requirements

- Include `JSON::Serializable` (for JSON/JSONB) or `YAML::Serializable` (for YAML)
- Include `Grant::SerializedObject` for dirty tracking
- Provide default constructor or default values for all properties
- Objects are deserialized lazily on first access

---

## Value Objects (Aggregations)

Map multiple database columns to cohesive, immutable structs following Domain-Driven Design patterns.

### Define Value Object

```crystal
struct Address
  getter street : String
  getter city : String
  getter zip : String

  def initialize(@street : String, @city : String, @zip : String)
  end

  def to_s(io)
    io << "#{street}, #{city} #{zip}"
  end
end
```

### Use in Model

```crystal
class Customer < Grant::Base
  connection pg
  table customers
  column id : Int64, primary: true
  column name : String

  aggregation :address, Address,
    mapping: {
      address_street: :street,
      address_city: :city,
      address_zip: :zip
    }
end
```

### Working with Value Objects

```crystal
customer = Customer.new(name: "John Doe")
customer.address = Address.new("123 Main St", "Boston", "02101")
customer.save

customer.address.city       # => "Boston"
customer.address_street     # => "123 Main St" (raw column)
customer.address_changed?   # => false

customer.address = Address.new("456 Elm St", "Cambridge", "02139")
customer.address_changed?   # => true
```

### Multiple Aggregations

```crystal
aggregation :home_address, Address, mapping: { home_street: :street, home_city: :city, home_zip: :zip }
aggregation :work_address, Address, mapping: { work_street: :street, work_city: :city, work_zip: :zip }
```

---

## Horizontal Sharding (Experimental)

Distribute data across multiple database instances.

### Hash-Based Sharding

```crystal
class User < Grant::Base
  include Grant::Sharding::Model

  shards_by :id, strategy: :hash, count: 4

  column id : Int64, primary: true
  column email : String
end
```

### Range-Based Sharding

```crystal
class Order < Grant::Base
  include Grant::Sharding::Model
  extend Grant::Sharding::CompositeId

  shards_by :id, strategy: :range, ranges: [
    {min: "2024_01", max: "2024_06_99", shard: :shard_2024_h1},
    {min: "2024_07", max: "2024_12_99", shard: :shard_2024_h2},
    {min: "2025_01", max: "2025_12_99", shard: :shard_current}
  ]
end
```

### Geographic Sharding

```crystal
class Customer < Grant::Base
  include Grant::Sharding::Model

  shards_by [:country, :state], strategy: :geo,
    regions: [
      {shard: :shard_us_west, countries: ["US"], states: ["CA", "OR", "WA"]},
      {shard: :shard_eu, countries: ["GB", "DE", "FR"]}
    ],
    default_shard: :shard_global
end
```

### Query Operations

```crystal
user = User.find(123)                              # Auto-routes to correct shard
User.on_shard(:shard_1).where(active: true).select # Force specific shard
User.on_all_shards { User.where("created_at < ?", 1.year.ago).delete_all }
```

### Limitations (Experimental)

- No distributed transactions
- No cross-shard joins
- Shard keys are immutable after creation
- Limited error handling

---

## Async Operations

Non-blocking database operations using Crystal's fiber-based concurrency.

### Basic Async

```crystal
result = User.async_find(1)
user = result.await  # Blocks until complete

result = User.async_find_by(email: "user@example.com")
user = result.await
```

### Concurrent Operations with Coordinator

```crystal
coordinator = Grant::Async::Coordinator.new
coordinator.add(User.async_count)
coordinator.add(Post.async_count)
coordinator.add(Comment.async_count)

results = coordinator.await_all
user_count, post_count, comment_count = results[0], results[1], results[2]
```

### Available Async Methods

**Query**: `async_find`, `async_find!`, `async_find_by`, `async_first`, `async_last`, `async_all`, `async_exists?`

**Aggregation**: `async_count`, `async_sum`, `async_avg`, `async_min`, `async_max`, `async_pluck`, `async_pick`

**Bulk**: `async_update_all`, `async_delete_all`

**Instance**: `async_save`, `async_save!`, `async_update`, `async_destroy`

### Query Builder Integration

```crystal
active_users = User.where(active: true)
                   .order(created_at: :desc)
                   .limit(10)
                   .async_all
                   .await
```

### Efficient Dashboard Loading

```crystal
def load_dashboard_data_async
  coordinator = Grant::Async::Coordinator.new
  coordinator.add(User.async_count)
  coordinator.add(Post.async_count)
  coordinator.add(User.order(created_at: :desc).limit(5).async_all)
  coordinator.add(Post.order(views: :desc).limit(10).async_all)

  results = coordinator.await_all
  # Total time: approximately the slowest query (not sum of all)
end
```

### Error Handling

```crystal
begin
  user = User.async_find!(999999).await
rescue Grant::Querying::NotFound
  puts "User not found"
end

# Coordinator error handling
coordinator = Grant::Async::Coordinator.new
coordinator.add(User.async_find!(1))
coordinator.add(User.async_find!(999999))
results = coordinator.await_all
coordinator.errors.each_with_index do |error, index|
  puts "Operation #{index} failed: #{error.message}" if error
end
```

### When to Use Async

- Multiple independent queries that can run concurrently
- High-latency network I/O
- Dashboard/report loading with many aggregations

### When NOT to Use Async

- Simple, fast queries
- Operations requiring sequential execution
- Transaction consistency requirements
