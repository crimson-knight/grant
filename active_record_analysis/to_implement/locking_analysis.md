# Locking Implementation Analysis

## Overview

Grant currently has no locking support. This is a critical gap for applications with concurrent access.

## Two Types of Locking

### 1. Optimistic Locking

**Purpose**: Prevent lost updates without blocking reads

**How it works**:
- Add a `lock_version` column (integer, default 0)
- Increment on every update
- Check version hasn't changed before updating
- Raise error if version changed (someone else updated)

**Rails Implementation**:
```ruby
class Product < ActiveRecord::Base
  # Just need lock_version column, Rails handles the rest
end

product = Product.find(1)
product.name = "New Name"
# Meanwhile, someone else updates the same product
product.save! # Raises ActiveRecord::StaleObjectError
```

**Proposed Grant Implementation**:
```crystal
module Grant::Locking::Optimistic
  macro included
    column lock_version : Int32 = 0
    
    before_update :check_lock_version
    after_update :increment_lock_version
    
    private def check_lock_version
      if lock_version_changed?
        current = self.class.find(id).lock_version
        if current != lock_version_was
          raise Grant::StaleObjectError.new(
            "Attempted to update stale #{self.class.name} object"
          )
        end
      end
    end
    
    private def increment_lock_version
      @lock_version += 1
    end
  end
end

class Product < Grant::Base
  include Grant::Locking::Optimistic
end
```

### 2. Pessimistic Locking

**Purpose**: Prevent concurrent access with database locks

**Types**:
- `FOR UPDATE` - Exclusive lock, prevents reads and writes
- `FOR SHARE` - Shared lock, allows reads but prevents writes
- `FOR UPDATE NOWAIT` - Fails immediately if locked
- `FOR UPDATE SKIP LOCKED` - Skips locked rows

**Rails Implementation**:
```ruby
# Basic lock
user = User.lock.find(1)
# SELECT * FROM users WHERE id = 1 FOR UPDATE

# Lock with block
user.with_lock do
  user.balance -= 100
  user.save!
end

# Custom lock type
User.lock("FOR UPDATE NOWAIT").find(1)
```

**Proposed Grant Implementation**:
```crystal
module Grant::Locking::Pessimistic
  module ClassMethods
    def lock(lock_type : String = "FOR UPDATE")
      where("1=1").lock(lock_type)
    end
    
    def find_with_lock(id, lock_type : String = "FOR UPDATE")
      connection.transaction do
        find_by!(id: id, lock: lock_type)
      end
    end
  end
  
  def lock!(lock_type : String = "FOR UPDATE")
    self.class.connection.transaction do
      reloaded = self.class.find_by!(id: id, lock: lock_type)
      set_attributes(reloaded.attributes)
      self
    end
  end
  
  def with_lock(lock_type : String = "FOR UPDATE", &)
    self.class.connection.transaction do
      lock!(lock_type)
      yield self
    end
  end
end

# Usage
user = User.find(1)
user.with_lock do
  user.balance -= 100
  user.save!
end
```

## Query Builder Integration

Need to add lock support to query builder:

```crystal
module Grant::Query::Builder
  property lock_type : String?
  
  def lock(type : String = "FOR UPDATE")
    @lock_type = type
    self
  end
  
  # In SQL generation
  private def build_sql
    sql = "SELECT * FROM #{table}"
    sql += " WHERE #{where_clause}" if where_clause
    sql += " #{@lock_type}" if @lock_type
    sql
  end
end

# Usage
User.where(active: true).lock.first
User.where(role: "admin").lock("FOR SHARE").select
```

## Database-Specific Considerations

### PostgreSQL
```sql
-- All lock types supported
FOR UPDATE
FOR NO KEY UPDATE
FOR SHARE
FOR KEY SHARE
-- With options
FOR UPDATE NOWAIT
FOR UPDATE SKIP LOCKED
```

### MySQL
```sql
-- Basic locks
FOR UPDATE
FOR SHARE -- (LOCK IN SHARE MODE in older versions)
-- With options (MySQL 8.0+)
FOR UPDATE NOWAIT
FOR UPDATE SKIP LOCKED
```

### SQLite
```sql
-- Limited support
-- No row-level locking
-- Only transaction-level locking
BEGIN IMMEDIATE; -- Write lock
BEGIN EXCLUSIVE; -- Exclusive lock
```

## Implementation Priority

### Phase 1: Optimistic Locking (High Priority)
- Simple to implement
- No database-specific code
- Handles most concurrent update scenarios
- Low performance impact

### Phase 2: Basic Pessimistic Locking (High Priority)
- `lock` query method
- `with_lock` instance method
- Basic `FOR UPDATE` support

### Phase 3: Advanced Locking (Medium Priority)
- Lock timeout handling
- NOWAIT and SKIP LOCKED options
- Database-specific lock types
- Deadlock retry logic

## Error Handling

```crystal
module Grant
  class StaleObjectError < Exception
    getter object_class : String
    getter object_id : Int64?
    
    def initialize(@object_class, @object_id = nil)
      super("Attempted to update stale #{object_class} object")
    end
  end
  
  class LockWaitTimeout < Exception
    def initialize(message = "Lock wait timeout exceeded")
      super(message)
    end
  end
  
  class Deadlock < Exception
    def initialize(message = "Deadlock detected")
      super(message)
    end
  end
end
```

## Testing Considerations

Testing locking requires:
1. Concurrent connections
2. Transaction isolation
3. Timeout handling
4. Database-specific behavior

```crystal
describe "Optimistic Locking" do
  it "detects stale objects" do
    product1 = Product.find(1)
    product2 = Product.find(1)
    
    product1.update(name: "New Name")
    
    expect_raises(Grant::StaleObjectError) do
      product2.update(name: "Another Name")
    end
  end
end

describe "Pessimistic Locking" do
  it "prevents concurrent updates" do
    channel = Channel(Nil).new
    
    spawn do
      Product.find(1).with_lock do |p|
        p.quantity -= 1
        sleep 0.1 # Hold lock
        p.save!
      end
      channel.send(nil)
    end
    
    sleep 0.05 # Let first fiber acquire lock
    
    # This should wait for lock
    Product.find(1).with_lock do |p|
      # First update should be complete
      p.quantity.should eq(original_quantity - 1)
    end
    
    channel.receive
  end
end
```

## Conclusion

Locking is essential for data integrity in concurrent environments. Optimistic locking should be implemented first as it's simpler and covers many use cases. Pessimistic locking is more complex but necessary for financial and inventory systems where conflicts must be prevented rather than detected.