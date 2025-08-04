# Locking and Transactions Guide

Grant provides comprehensive support for database transactions and both optimistic and pessimistic locking strategies, ensuring data integrity in concurrent environments.

## Table of Contents

- [Transactions](#transactions)
  - [Basic Transactions](#basic-transactions)
  - [Nested Transactions](#nested-transactions)
  - [Isolation Levels](#isolation-levels)
  - [Read-Only Transactions](#read-only-transactions)
- [Pessimistic Locking](#pessimistic-locking)
  - [Lock Modes](#lock-modes)
  - [Block-Based Locking](#block-based-locking)
- [Optimistic Locking](#optimistic-locking)
  - [Setup](#setup)
  - [Handling Conflicts](#handling-conflicts)
  - [Automatic Retries](#automatic-retries)
- [Database Support](#database-support)

## Transactions

### Basic Transactions

Wrap multiple database operations in a transaction to ensure they all succeed or all fail together:

```crystal
User.transaction do
  user = User.create!(name: "Alice", email: "alice@example.com")
  Profile.create!(user_id: user.id, bio: "Software developer")
  # Both records are created, or neither if an error occurs
end
```

Transactions automatically roll back on any exception:

```crystal
User.transaction do
  user.save!
  account.save!
  raise "Something went wrong!"  # Transaction rolls back
end
```

### Nested Transactions

Grant supports nested transactions using savepoints:

```crystal
User.transaction do
  user.save!
  
  # Nested transaction with savepoint
  User.transaction do
    audit_log.save!
    raise Granite::Transaction::Rollback.new  # Only rolls back the nested transaction
  end
  
  # user.save! is still committed
end
```

For true nested transactions, use `requires_new`:

```crystal
User.transaction do
  outer_record.save!
  
  User.transaction(requires_new: true) do
    # This runs in a completely separate transaction
    independent_record.save!
  end
  
  raise "Error!"  # Only outer transaction rolls back
end
```

### Isolation Levels

Control transaction isolation to prevent various concurrency issues:

```crystal
# Specify isolation level
User.transaction(isolation: :serializable) do
  # Highest isolation - prevents all phenomena
  critical_operation
end

# Available isolation levels:
# - :read_uncommitted - Lowest isolation, highest performance
# - :read_committed - Default for most databases
# - :repeatable_read - Prevents non-repeatable reads
# - :serializable - Highest isolation, prevents all anomalies
```

### Read-Only Transactions

Optimize read-heavy operations:

```crystal
User.transaction(readonly: true) do
  # Only SELECT queries allowed
  users = User.all
  analytics = calculate_statistics(users)
end
```

## Pessimistic Locking

Pessimistic locking prevents other transactions from accessing locked records.

### Lock Modes

Grant provides type-safe lock modes instead of raw SQL strings:

```crystal
# Basic exclusive lock (FOR UPDATE)
user = User.where(id: 1).lock.first!

# Shared lock (FOR SHARE)
user = User.where(id: 1).lock(Granite::Locking::LockMode::Share).first!

# Non-waiting lock (fails immediately if locked)
user = User.where(id: 1).lock(Granite::Locking::LockMode::UpdateNoWait).first!

# Skip locked rows
users = User.where(active: true).lock(Granite::Locking::LockMode::UpdateSkipLocked).to_a
```

Available lock modes:
- `Update` - Exclusive lock (FOR UPDATE)
- `Share` - Shared lock (FOR SHARE)
- `UpdateNoWait` - Exclusive lock, fail if locked
- `UpdateSkipLocked` - Exclusive lock, skip locked rows
- `ShareNoWait` - Shared lock, fail if locked
- `ShareSkipLocked` - Shared lock, skip locked rows

### Block-Based Locking

Automatically handle transactions and locking:

```crystal
# Lock by ID
User.with_lock(user_id) do |user|
  user.balance -= 100
  user.save!
end

# Lock first matching record
User.where(email: "alice@example.com").with_lock do |user|
  user.last_login = Time.local
  user.save!
end

# Instance method
user.with_lock do |locked_user|
  locked_user.process_payment(amount)
end
```

## Optimistic Locking

Optimistic locking uses a version column to detect concurrent modifications.

### Setup

Include the `Granite::Locking::Optimistic` module in your model:

```crystal
class Product < Granite::Base
  include Granite::Locking::Optimistic
  
  column id : Int64, primary: true
  column name : String
  column price : Float64
  # lock_version column is automatically added
end
```

This adds a `lock_version` column that increments with each update.

### Handling Conflicts

When a conflict is detected, a `StaleObjectError` is raised:

```crystal
# Two users load the same product
user1_product = Product.find!(1)
user2_product = Product.find!(1)

# User 1 updates successfully
user1_product.price = 99.99
user1_product.save!

# User 2's update fails
user2_product.price = 89.99
begin
  user2_product.save!
rescue ex : Granite::Locking::Optimistic::StaleObjectError
  # Handle the conflict
  puts "Another user modified this record. Please reload and try again."
  user2_product.reload
  # Retry the operation
end
```

### Automatic Retries

Use `with_optimistic_retry` for automatic conflict resolution:

```crystal
product.with_optimistic_retry(max_retries: 3) do
  product.stock -= quantity
  product.save!
end
```

Configure default retry behavior:

```crystal
Product.lock_conflict_max_retries = 5

# Now all products will retry up to 5 times by default
product.with_optimistic_retry do
  # Complex update logic
end
```

## Database Support

### PostgreSQL
- Full support for all lock modes
- All isolation levels supported
- Savepoints for nested transactions

### MySQL
- Supports basic lock modes (Update, Share, UpdateNoWait, UpdateSkipLocked)
- All isolation levels supported
- Savepoints supported

### SQLite
- No row-level locking (uses database-level locking)
- Limited transaction control
- Savepoints supported

Check adapter capabilities:

```crystal
if User.adapter.supports_lock_mode?(Granite::Locking::LockMode::UpdateSkipLocked)
  # Use skip locked feature
end

if User.adapter.supports_isolation_level?(Granite::Transaction::IsolationLevel::Serializable)
  # Use serializable isolation
end

if User.adapter.supports_savepoints?
  # Use nested transactions
end
```

## Best Practices

1. **Choose the Right Strategy**
   - Use optimistic locking for low-contention scenarios
   - Use pessimistic locking for high-contention or critical sections
   
2. **Keep Transactions Short**
   - Minimize the time locks are held
   - Do computation outside transactions when possible
   
3. **Handle Errors Gracefully**
   - Always handle `StaleObjectError` for optimistic locking
   - Handle deadlocks and timeouts for pessimistic locking
   
4. **Test Concurrent Scenarios**
   - Write tests that simulate concurrent access
   - Use fibers or threads to test race conditions

## Migration Support

Add optimistic locking to existing tables:

```crystal
class AddOptimisticLocking < Granite::Migration
  def up
    add_column :products, :lock_version, :integer, default: 0, null: false
    add_index :products, :lock_version
  end
  
  def down
    remove_column :products, :lock_version
  end
end
```