# Transaction Support Analysis

## Current State in Grant

Grant currently has:
- Implicit transactions for single model operations
- Transaction callbacks (`after_commit`, `after_rollback`)
- Basic rollback on errors

## What's Missing

### 1. Explicit Transaction Blocks

**Rails**:
```ruby
ActiveRecord::Base.transaction do
  user.save!
  account.withdraw!(100)
  other_account.deposit!(100)
end
```

**Needed in Grant**:
```crystal
Grant::Base.transaction do
  user.save!
  account.withdraw!(100)
  other_account.deposit!(100)
end
```

### 2. Nested Transactions (Savepoints)

**Rails**:
```ruby
User.transaction do
  User.create!(name: "John")
  
  User.transaction(requires_new: true) do
    User.create!(name: "Jane")
    raise ActiveRecord::Rollback # Only rolls back Jane
  end
  
  User.create!(name: "Jack") # This still saves
end
```

**Needed in Grant**:
```crystal
User.transaction do
  User.create!(name: "John")
  
  User.transaction(requires_new: true) do
    User.create!(name: "Jane")
    raise Grant::Rollback # Only rolls back Jane
  end
  
  User.create!(name: "Jack") # This still saves
end
```

### 3. Transaction Isolation Levels

**Rails**:
```ruby
User.transaction(isolation: :serializable) do
  # Highest isolation level
end

User.transaction(isolation: :read_committed) do
  # Default for many databases
end
```

**Needed in Grant**:
```crystal
User.transaction(isolation: :serializable) do
  # Highest isolation level
end
```

### 4. Manual Transaction Control

**Rails**:
```ruby
User.connection.begin_db_transaction
# ... operations ...
User.connection.commit_db_transaction
# or
User.connection.rollback_db_transaction
```

### 5. Transaction Options

**Rails**:
```ruby
User.transaction(joinable: false) do
  # Don't join existing transaction
end

User.transaction(requires_new: true) do
  # Force new transaction/savepoint
end
```

## Implementation Considerations

### Database Differences

**PostgreSQL**:
- Full savepoint support
- All isolation levels
- Deadlock detection

**MySQL**:
- Savepoint support varies by engine
- Limited isolation levels
- Different deadlock handling

**SQLite**:
- Limited transaction support
- No true savepoints
- Different isolation behavior

### Crystal Considerations

1. **Fiber Safety**: Transactions must be fiber-aware
2. **Connection Pooling**: Transaction must stay on same connection
3. **Error Handling**: Crystal's exception model differs from Ruby
4. **Resource Management**: Ensure connections are released

## Proposed Implementation

```crystal
module Grant
  module Transactions
    class Transaction
      property connection : Adapter::Base
      property isolation : Symbol?
      property requires_new : Bool
      property parent : Transaction?
      
      def initialize(@connection, @isolation = nil, @requires_new = false, @parent = nil)
      end
      
      def execute(&)
        if requires_new || parent.nil?
          start_transaction
        else
          create_savepoint if parent
        end
        
        yield
        
        commit
      rescue e
        rollback
        raise e
      ensure
        cleanup
      end
      
      private def start_transaction
        sql = "BEGIN"
        sql += " ISOLATION LEVEL #{isolation.to_s.upcase}" if isolation
        connection.execute(sql)
      end
      
      private def create_savepoint
        @savepoint_name = "sp_#{Random.rand(1000000)}"
        connection.execute("SAVEPOINT #{@savepoint_name}")
      end
      
      private def commit
        if @savepoint_name
          connection.execute("RELEASE SAVEPOINT #{@savepoint_name}")
        else
          connection.execute("COMMIT")
        end
      end
      
      private def rollback
        if @savepoint_name
          connection.execute("ROLLBACK TO SAVEPOINT #{@savepoint_name}")
        else
          connection.execute("ROLLBACK")
        end
      end
    end
    
    module ClassMethods
      def transaction(isolation : Symbol? = nil, requires_new : Bool = false, &)
        current_transaction = Thread.current[:current_transaction]?
        
        transaction = Transaction.new(
          connection,
          isolation,
          requires_new,
          current_transaction
        )
        
        Thread.current[:current_transaction] = transaction
        
        transaction.execute do
          yield
        end
      ensure
        Thread.current[:current_transaction] = current_transaction
      end
    end
  end
end
```

## Priority: CRITICAL

Transactions are fundamental for data integrity. Without proper transaction support, Grant cannot be used for serious applications that require ACID guarantees. This should be one of the first features implemented.