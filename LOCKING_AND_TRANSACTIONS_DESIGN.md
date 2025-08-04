# Locking and Transactions Design Document

This document outlines the design for implementing type-safe locking mechanisms and transaction support in Grant, leveraging Crystal's strong type system.

## Overview

We're implementing two critical features for data integrity:
1. **Locking Mechanisms** (Issue #9): Both optimistic and pessimistic locking
2. **Transaction Support** (Issue #10): Explicit transactions with isolation levels

## Design Principles

1. **Type Safety First**: Use Crystal's type system to prevent runtime errors
2. **Database Agnostic**: Abstract differences between PostgreSQL, MySQL, and SQLite
3. **Composable API**: Small, focused modules that work together
4. **Clear Semantics**: Method names and types that clearly express intent
5. **Performance**: Minimal overhead when features aren't used

## 1. Pessimistic Locking

### Type-Safe Lock Modes

Instead of allowing arbitrary SQL strings, we'll use an enum to represent lock modes:

```crystal
module Granite::Locking
  enum LockMode
    # Standard SQL locks
    Update       # FOR UPDATE
    Share        # FOR SHARE
    
    # PostgreSQL-specific
    UpdateNoWait # FOR UPDATE NOWAIT
    UpdateSkipLocked # FOR UPDATE SKIP LOCKED
    ShareNoWait  # FOR SHARE NOWAIT
    ShareSkipLocked # FOR SHARE SKIP LOCKED
    
    # MySQL-specific
    UpdateNowait # FOR UPDATE NOWAIT (MySQL syntax)
    ShareNowait  # LOCK IN SHARE MODE
    
    def to_sql(adapter_type : Symbol) : String
      case adapter_type
      when :postgres
        postgres_sql
      when :mysql
        mysql_sql
      when :sqlite
        sqlite_sql
      else
        raise "Unsupported adapter: #{adapter_type}"
      end
    end
    
    private def postgres_sql : String
      case self
      when Update then "FOR UPDATE"
      when Share then "FOR SHARE"
      when UpdateNoWait then "FOR UPDATE NOWAIT"
      when UpdateSkipLocked then "FOR UPDATE SKIP LOCKED"
      when ShareNoWait then "FOR SHARE NOWAIT"
      when ShareSkipLocked then "FOR SHARE SKIP LOCKED"
      else
        raise "Lock mode #{self} not supported in PostgreSQL"
      end
    end
    
    private def mysql_sql : String
      case self
      when Update, UpdateNowait then "FOR UPDATE"
      when Share, ShareNowait then "LOCK IN SHARE MODE"
      when UpdateNoWait then "FOR UPDATE NOWAIT"
      else
        raise "Lock mode #{self} not supported in MySQL"
      end
    end
    
    private def sqlite_sql : String
      # SQLite doesn't support row-level locking
      ""
    end
  end
end
```

### Pessimistic Locking API

```crystal
module Granite::Locking::Pessimistic
  # Add locking to query builder
  def lock(mode : LockMode = LockMode::Update) : self
    @lock_mode = mode
    self
  end
  
  # Block-based locking with automatic transaction
  def with_lock(mode : LockMode = LockMode::Update, &block : T -> U) : U forall U
    transaction do
      record = lock(mode).first!
      yield record
    end
  end
  
  # Lock multiple records
  def lock_all(mode : LockMode = LockMode::Update) : Array(T)
    lock(mode).to_a
  end
end
```

### Usage Examples

```crystal
# Basic lock
user = User.where(id: 1).lock.first!

# With specific lock mode
user = User.where(id: 1).lock(LockMode::UpdateNoWait).first!

# Block-based locking
User.where(id: 1).with_lock do |user|
  user.balance -= 100
  user.save!
end

# Lock multiple records
users = User.where(active: true).lock_all(LockMode::Share)
```

## 2. Optimistic Locking

### Implementation

```crystal
module Granite::Locking::Optimistic
  macro included
    column lock_version : Int32 = 0
    
    before_update :check_lock_version
    after_update :increment_lock_version
  end
  
  class StaleObjectError < Exception
    def initialize(record : Granite::Base)
      super("Attempted to update a stale object: #{record.class.name}")
    end
  end
  
  private def check_lock_version
    return unless lock_version_changed?
    
    # Build WHERE clause including lock version
    where_clause = "#{self.class.primary_name} = ? AND lock_version = ?"
    params = [id, lock_version_was]
    
    # Check if record still exists with expected version
    unless self.class.exists?(where_clause, params)
      raise StaleObjectError.new(self)
    end
  end
  
  private def increment_lock_version
    @lock_version = lock_version + 1
  end
end
```

## 3. Transaction Support

### Type-Safe Isolation Levels

```crystal
module Granite::Transaction
  enum IsolationLevel
    ReadUncommitted
    ReadCommitted
    RepeatableRead
    Serializable
    
    def to_sql : String
      case self
      when ReadUncommitted then "READ UNCOMMITTED"
      when ReadCommitted then "READ COMMITTED"
      when RepeatableRead then "REPEATABLE READ"
      when Serializable then "SERIALIZABLE"
      end
    end
  end
  
  # Transaction options
  record Options,
    isolation : IsolationLevel? = nil,
    readonly : Bool = false,
    requires_new : Bool = false
end
```

### Transaction API

```crystal
module Granite::Transaction
  class Rollback < Exception; end
  
  module ClassMethods
    # Thread-local storage for transaction state
    @[ThreadLocal]
    class_property transaction_stack = [] of TransactionState
    
    # Basic transaction
    def transaction(&block) : Nil
      transaction(Transaction::Options.new) { yield }
    end
    
    # Transaction with options
    def transaction(options : Transaction::Options, &block) : Nil
      if options.requires_new || transaction_stack.empty?
        execute_transaction(options, &block)
      else
        # Nested transaction without requires_new uses savepoint
        execute_savepoint(&block)
      end
    end
    
    # Check if in transaction
    def transaction_open? : Bool
      !transaction_stack.empty?
    end
    
    private def execute_transaction(options : Transaction::Options, &block)
      adapter.open do |db|
        begin
          # Start transaction with options
          start_transaction(db, options)
          transaction_stack.push(TransactionState.new(db, options))
          
          yield
          
          # Commit if no exception
          db.exec("COMMIT")
          transaction_stack.pop
        rescue ex : Rollback
          db.exec("ROLLBACK")
          transaction_stack.pop
          # Don't re-raise Rollback exceptions
        rescue ex
          db.exec("ROLLBACK")
          transaction_stack.pop
          raise ex
        end
      end
    end
    
    private def execute_savepoint(&block)
      savepoint_name = "sp_#{Random::Secure.hex(8)}"
      current_transaction = transaction_stack.last
      
      begin
        current_transaction.db.exec("SAVEPOINT #{savepoint_name}")
        yield
        current_transaction.db.exec("RELEASE SAVEPOINT #{savepoint_name}")
      rescue ex : Rollback
        current_transaction.db.exec("ROLLBACK TO SAVEPOINT #{savepoint_name}")
        # Don't re-raise Rollback exceptions
      rescue ex
        current_transaction.db.exec("ROLLBACK TO SAVEPOINT #{savepoint_name}")
        raise ex
      end
    end
    
    private def start_transaction(db : DB::Connection, options : Transaction::Options)
      case adapter
      when Granite::Adapter::Pg
        start_pg_transaction(db, options)
      when Granite::Adapter::Mysql
        start_mysql_transaction(db, options)
      when Granite::Adapter::Sqlite
        start_sqlite_transaction(db, options)
      end
    end
  end
  
  # Instance method for convenience
  def transaction(&block)
    self.class.transaction { yield }
  end
end
```

### Usage Examples

```crystal
# Basic transaction
User.transaction do
  user.save!
  order.save!
end

# With isolation level
User.transaction(isolation: :serializable) do
  # Critical operations
end

# Nested transactions
User.transaction do
  user.save!
  
  User.transaction(requires_new: true) do
    # This runs in a separate transaction
    audit_log.save!
  end
  
  # Savepoint-based nesting
  User.transaction do
    # This uses a savepoint
    temporary_record.save!
    raise Granite::Transaction::Rollback.new if condition
  end
end

# Read-only transaction
User.transaction(readonly: true) do
  # Only SELECT queries allowed
  users = User.all
end
```

## 4. Integration with Query Builder

```crystal
# Extension to Granite::Query::Builder
module Granite::Query::Builder(T)
  property lock_mode : Granite::Locking::LockMode? = nil
  
  def to_sql
    sql = super
    if lock_mode
      sql += " #{lock_mode.to_sql(T.adapter.class.adapter_type)}"
    end
    sql
  end
end
```

## 5. Database-Specific Implementations

### Adapter Extensions

```crystal
# Base adapter extension
abstract class Granite::Adapter::Base
  abstract def supports_lock_mode?(mode : Granite::Locking::LockMode) : Bool
  abstract def supports_isolation_level?(level : Granite::Transaction::IsolationLevel) : Bool
  abstract def supports_savepoints? : Bool
end

class Granite::Adapter::Pg < Granite::Adapter::Base
  def supports_lock_mode?(mode : Granite::Locking::LockMode) : Bool
    true # PostgreSQL supports all lock modes
  end
  
  def supports_isolation_level?(level : Granite::Transaction::IsolationLevel) : Bool
    true # PostgreSQL supports all isolation levels
  end
  
  def supports_savepoints? : Bool
    true
  end
end

class Granite::Adapter::Mysql < Granite::Adapter::Base
  def supports_lock_mode?(mode : Granite::Locking::LockMode) : Bool
    case mode
    when .update?, .share?, .update_no_wait?
      true
    else
      false
    end
  end
  
  def supports_isolation_level?(level : Granite::Transaction::IsolationLevel) : Bool
    true # MySQL supports all standard isolation levels
  end
  
  def supports_savepoints? : Bool
    true
  end
end

class Granite::Adapter::Sqlite < Granite::Adapter::Base
  def supports_lock_mode?(mode : Granite::Locking::LockMode) : Bool
    false # SQLite uses database-level locking
  end
  
  def supports_isolation_level?(level : Granite::Transaction::IsolationLevel) : Bool
    false # SQLite has limited transaction control
  end
  
  def supports_savepoints? : Bool
    true
  end
end
```

## 6. Error Handling

```crystal
module Granite::Locking
  class LockWaitTimeoutError < Exception; end
  class LockNotAvailableError < Exception; end
  class DeadlockError < Exception; end
end

module Granite::Transaction
  class SerializationError < Exception; end
  class ReadOnlyError < Exception; end
end
```

## 7. Testing Strategy

1. Unit tests for each lock mode and isolation level
2. Integration tests with all three databases
3. Concurrency tests using fibers
4. Performance benchmarks
5. Error condition tests (deadlocks, timeouts)

## 8. Migration Helpers

```crystal
module Granite::Migration
  def add_lock_version(table_name : String)
    add_column table_name, :lock_version, :integer, default: 0, null: false
    add_index table_name, :lock_version
  end
  
  def remove_lock_version(table_name : String)
    remove_column table_name, :lock_version
  end
end
```

## Implementation Plan

1. Implement core transaction support in base adapter
2. Add database-specific transaction implementations
3. Implement pessimistic locking with type-safe lock modes
4. Implement optimistic locking module
5. Add query builder integration
6. Create comprehensive test suite
7. Add documentation and examples
8. Performance optimization

## Benefits of This Design

1. **Type Safety**: Enums prevent invalid lock modes and isolation levels
2. **Clear Intent**: Methods like `with_lock` clearly express what's happening
3. **Database Abstraction**: Differences handled internally, not by users
4. **Composability**: Locking and transactions work together seamlessly
5. **Error Prevention**: Compile-time checks prevent many runtime errors
6. **Performance**: Zero overhead when features aren't used