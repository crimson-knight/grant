---
title: "Transactions and Locking Strategies"
category: "infrastructure"
subcategory: "data-integrity"
tags: ["transactions", "locking", "acid", "isolation", "deadlocks", "concurrency-control"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../core-features/crud-operations.md", "async-concurrency.md"]
related_docs: ["database-scaling.md", "async-concurrency.md", "../advanced/data-management/migrations.md"]
last_updated: "2025-01-13"
estimated_read_time: "18 minutes"
use_cases: ["financial-transactions", "inventory-management", "concurrent-updates", "data-consistency"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Transactions and Locking Strategies

Comprehensive guide to implementing robust transaction management and locking strategies in Grant applications for maintaining data integrity and handling concurrent access.

## Overview

Proper transaction management and locking are essential for data integrity. This guide covers:
- ACID transaction properties
- Transaction isolation levels
- Optimistic and pessimistic locking
- Deadlock detection and prevention
- Distributed transactions
- Transaction patterns and best practices

## Transaction Fundamentals

### Basic Transactions

```crystal
class Transaction
  def self.execute(&block)
    Grant.connection.transaction do |tx|
      yield tx
    end
  rescue ex : DB::Rollback
    Log.info { "Transaction rolled back: #{ex.message}" }
    raise ex
  rescue ex
    Log.error(exception: ex) { "Transaction failed" }
    raise ex
  end
  
  def self.with_retry(max_attempts : Int32 = 3, &block)
    attempt = 0
    
    loop do
      attempt += 1
      
      begin
        return execute { yield }
      rescue ex : DB::ConnectionLost
        raise ex if attempt >= max_attempts
        Log.warn { "Connection lost, retrying transaction (attempt #{attempt})" }
        sleep (2 ** attempt).milliseconds
      rescue ex : DeadlockError
        raise ex if attempt >= max_attempts
        Log.warn { "Deadlock detected, retrying transaction (attempt #{attempt})" }
        sleep Random.rand(10..100).milliseconds
      end
    end
  end
end

# Usage
Transaction.execute do |tx|
  user = User.find!(1)
  user.balance -= 100
  user.save!
  
  transaction = Transaction.create!(
    user_id: user.id,
    amount: -100,
    type: "withdrawal"
  )
  
  # Automatic rollback on exception
  raise DB::Rollback.new("Insufficient funds") if user.balance < 0
end
```

### Nested Transactions with Savepoints

```crystal
class NestedTransaction
  def self.execute(name : String? = nil, &block)
    if Grant.connection.in_transaction?
      # Use savepoint for nested transaction
      savepoint_name = name || "sp_#{Random::Secure.hex(4)}"
      
      Grant.connection.exec("SAVEPOINT #{savepoint_name}")
      
      begin
        result = yield
        Grant.connection.exec("RELEASE SAVEPOINT #{savepoint_name}")
        result
      rescue ex
        Grant.connection.exec("ROLLBACK TO SAVEPOINT #{savepoint_name}")
        raise ex
      end
    else
      # Start new transaction
      Grant.connection.transaction { yield }
    end
  end
end

# Usage with nested transactions
Transaction.execute do
  order = Order.create!(customer_id: 1, total: 0)
  
  items.each do |item_data|
    NestedTransaction.execute("item_#{item_data[:id]}") do
      item = OrderItem.create!(
        order_id: order.id,
        product_id: item_data[:product_id],
        quantity: item_data[:quantity]
      )
      
      # Update inventory
      product = Product.find!(item_data[:product_id])
      product.stock -= item_data[:quantity]
      
      # Rollback just this item if out of stock
      raise "Out of stock" if product.stock < 0
      
      product.save!
      order.total += item.subtotal
    end
  rescue
    # Skip item but continue with order
    Log.warn { "Skipping item #{item_data[:id]}" }
  end
  
  order.save!
end
```

## Isolation Levels

### Configurable Isolation

```crystal
enum IsolationLevel
  ReadUncommitted
  ReadCommitted
  RepeatableRead
  Serializable
  
  def to_sql : String
    case self
    when .read_uncommitted?
      "READ UNCOMMITTED"
    when .read_committed?
      "READ COMMITTED"
    when .repeatable_read?
      "REPEATABLE READ"
    when .serializable?
      "SERIALIZABLE"
    else
      "READ COMMITTED"
    end
  end
end

class IsolatedTransaction
  def self.execute(isolation : IsolationLevel, &block)
    Grant.connection.transaction do |tx|
      # Set isolation level
      tx.exec("SET TRANSACTION ISOLATION LEVEL #{isolation.to_sql}")
      
      yield tx
    end
  end
  
  def self.read_only(&block)
    Grant.connection.transaction do |tx|
      tx.exec("SET TRANSACTION READ ONLY")
      yield tx
    end
  end
  
  def self.deferrable(&block)
    Grant.connection.transaction do |tx|
      tx.exec("SET TRANSACTION DEFERRABLE")
      yield tx
    end
  end
end

# Usage examples
# Serializable for maximum consistency
IsolatedTransaction.execute(IsolationLevel::Serializable) do
  account1 = Account.find!(1)
  account2 = Account.find!(2)
  
  account1.balance -= 100
  account2.balance += 100
  
  account1.save!
  account2.save!
end

# Read committed for better performance
IsolatedTransaction.execute(IsolationLevel::ReadCommitted) do
  # Less strict isolation for read-heavy operations
  reports = Report.generate_all
end
```

### Isolation Level Testing

```crystal
class IsolationTester
  def self.test_dirty_read
    # Thread 1: Write without commit
    spawn do
      Grant.connection.transaction do
        User.find!(1).update!(status: "processing")
        sleep 2.seconds  # Hold transaction open
      end
    end
    
    sleep 100.milliseconds
    
    # Thread 2: Try to read
    IsolatedTransaction.execute(IsolationLevel::ReadUncommitted) do
      user = User.find!(1)
      puts "Dirty read: #{user.status}"  # May see "processing"
    end
    
    IsolatedTransaction.execute(IsolationLevel::ReadCommitted) do
      user = User.find!(1)
      puts "Clean read: #{user.status}"  # Won't see "processing"
    end
  end
  
  def self.test_phantom_read
    IsolatedTransaction.execute(IsolationLevel::RepeatableRead) do
      count1 = User.where(active: true).count
      
      # Another transaction inserts a user
      spawn do
        User.create!(name: "New", active: true)
      end
      
      sleep 100.milliseconds
      count2 = User.where(active: true).count
      
      puts "Phantom read prevented: #{count1 == count2}"  # True for REPEATABLE READ
    end
  end
end
```

## Pessimistic Locking

### Row-Level Locking

```crystal
module PessimisticLocking
  enum LockMode
    Update      # FOR UPDATE
    NoKeyUpdate # FOR NO KEY UPDATE (PostgreSQL)
    Share       # FOR SHARE
    KeyShare    # FOR KEY SHARE (PostgreSQL)
    
    def to_sql : String
      case self
      when .update?
        "FOR UPDATE"
      when .no_key_update?
        "FOR NO KEY UPDATE"
      when .share?
        "FOR SHARE"
      when .key_share?
        "FOR KEY SHARE"
      else
        "FOR UPDATE"
      end
    end
  end
  
  macro included
    def self.lock(mode : LockMode = LockMode::Update)
      sql = all.to_sql + " #{mode.to_sql}"
      query(sql)
    end
    
    def self.find_and_lock(id : Int64, mode : LockMode = LockMode::Update)
      sql = "SELECT * FROM #{table_name} WHERE id = ? #{mode.to_sql}"
      query_one(sql, id) { |rs| new(rs) }
    end
    
    def lock!(mode : LockMode = LockMode::Update)
      sql = "SELECT * FROM #{self.class.table_name} WHERE id = ? #{mode.to_sql}"
      Grant.connection.exec(sql, id)
      self
    end
    
    def with_lock(mode : LockMode = LockMode::Update, &block)
      Transaction.execute do
        lock!(mode)
        yield self
      end
    end
  end
end

class Account < Grant::Base
  include PessimisticLocking
  
  column id : Int64, primary: true
  column balance : Float64
  column locked : Bool = false
end

# Usage
Transaction.execute do
  # Lock account for update
  account = Account.find_and_lock(1)
  
  # No other transaction can modify this account
  account.balance -= 100
  account.save!
end

# Lock multiple rows
Transaction.execute do
  accounts = Account.where(user_id: 1).lock(LockMode::Update)
  accounts.each do |account|
    account.process_fees
  end
end
```

### Table-Level Locking

```crystal
class TableLock
  enum Mode
    AccessShare
    RowShare
    RowExclusive
    ShareUpdateExclusive
    Share
    ShareRowExclusive
    Exclusive
    AccessExclusive
    
    def to_sql : String
      case self
      when .access_share?
        "ACCESS SHARE"
      when .row_share?
        "ROW SHARE"
      when .row_exclusive?
        "ROW EXCLUSIVE"
      when .share_update_exclusive?
        "SHARE UPDATE EXCLUSIVE"
      when .share?
        "SHARE"
      when .share_row_exclusive?
        "SHARE ROW EXCLUSIVE"
      when .exclusive?
        "EXCLUSIVE"
      when .access_exclusive?
        "ACCESS EXCLUSIVE"
      else
        "ACCESS SHARE"
      end
    end
  end
  
  def self.acquire(table : String, mode : Mode, nowait : Bool = false)
    sql = "LOCK TABLE #{table} IN #{mode.to_sql} MODE"
    sql += " NOWAIT" if nowait
    
    Grant.connection.exec(sql)
  end
  
  def self.with_lock(table : String, mode : Mode, &block)
    Transaction.execute do
      acquire(table, mode)
      yield
    end
  end
end

# Usage for bulk operations
TableLock.with_lock("inventory", TableLock::Mode::ShareUpdateExclusive) do
  # Prevent schema changes during bulk update
  Inventory.update_all(status: "processing")
  # Perform complex inventory reconciliation
  Inventory.reconcile_all
end
```

### Advisory Locks

```crystal
class AdvisoryLock
  def self.acquire(key : Int64, shared : Bool = false) : Bool
    function = shared ? "pg_try_advisory_lock_shared" : "pg_try_advisory_lock"
    result = Grant.connection.scalar("SELECT #{function}(?)", key)
    result.as(Bool)
  end
  
  def self.acquire!(key : Int64, shared : Bool = false)
    function = shared ? "pg_advisory_lock_shared" : "pg_advisory_lock"
    Grant.connection.exec("SELECT #{function}(?)", key)
  end
  
  def self.release(key : Int64, shared : Bool = false) : Bool
    function = shared ? "pg_advisory_unlock_shared" : "pg_advisory_unlock"
    result = Grant.connection.scalar("SELECT #{function}(?)", key)
    result.as(Bool)
  end
  
  def self.with_lock(key : Int64, shared : Bool = false, &block)
    acquired = acquire(key, shared)
    raise "Could not acquire advisory lock #{key}" unless acquired
    
    begin
      yield
    ensure
      release(key, shared)
    end
  end
  
  def self.with_lock_wait(key : Int64, shared : Bool = false, &block)
    acquire!(key, shared)
    
    begin
      yield
    ensure
      release(key, shared)
    end
  end
end

# Usage for distributed operations
USER_PROCESSING_LOCK = 1000

AdvisoryLock.with_lock(USER_PROCESSING_LOCK + user.id) do
  # Only one process can run this for a specific user
  user.process_pending_tasks
end
```

## Optimistic Locking

### Version-Based Locking

```crystal
module OptimisticLocking
  class StaleRecordError < Exception
  end
  
  macro included
    column lock_version : Int32 = 0
    
    before_update :check_version_conflict
    after_update :increment_version
    
    @original_lock_version : Int32?
    
    def original_lock_version
      @original_lock_version ||= lock_version
    end
    
    private def check_version_conflict
      return if new_record?
      
      current_version = self.class.where(id: id).pluck(:lock_version).first
      
      if current_version != original_lock_version
        raise StaleRecordError.new(
          "Attempted to update stale #{self.class.name} id=#{id}. " +
          "Current version: #{current_version}, Your version: #{original_lock_version}"
        )
      end
    end
    
    private def increment_version
      self.lock_version += 1
      @original_lock_version = lock_version
    end
    
    def reload
      super
      @original_lock_version = lock_version
      self
    end
  end
end

class Product < Grant::Base
  include OptimisticLocking
  
  column id : Int64, primary: true
  column name : String
  column price : Float64
  column stock : Int32
end

# Retry logic for optimistic locking
def update_with_retry(product : Product, max_retries : Int32 = 3)
  retry_count = 0
  
  loop do
    begin
      yield product
      product.save!
      break
    rescue Product::StaleRecordError
      retry_count += 1
      raise if retry_count >= max_retries
      
      # Reload and retry
      product.reload
      Log.info { "Retrying update due to version conflict (attempt #{retry_count})" }
    end
  end
end

# Usage
update_with_retry(product) do |p|
  p.stock -= 1
  p.price *= 0.9 if p.stock < 10  # Discount low stock
end
```

### Timestamp-Based Locking

```crystal
module TimestampLocking
  macro included
    column updated_at : Time
    
    @original_updated_at : Time?
    
    before_update :check_timestamp_conflict
    
    def original_updated_at
      @original_updated_at ||= updated_at
    end
    
    private def check_timestamp_conflict
      return if new_record?
      
      current = self.class.where(id: id).pluck(:updated_at).first
      
      if current != original_updated_at
        raise StaleRecordError.new(
          "Record has been modified since it was loaded. " +
          "Current: #{current}, Loaded: #{original_updated_at}"
        )
      end
    end
  end
end
```

## Deadlock Detection and Prevention

### Deadlock Detection

```crystal
class DeadlockDetector
  struct LockInfo
    property transaction_id : Int64
    property table : String
    property lock_type : String
    property granted : Bool
    property waiting_for : Int64?
  end
  
  def self.detect_deadlocks : Array(LockInfo)
    # PostgreSQL lock monitoring
    sql = <<-SQL
      SELECT 
        l.pid as transaction_id,
        c.relname as table,
        l.mode as lock_type,
        l.granted,
        blocking.pid as waiting_for
      FROM pg_locks l
      JOIN pg_class c ON c.oid = l.relation
      LEFT JOIN pg_locks blocking ON 
        blocking.locktype = l.locktype AND
        blocking.relation = l.relation AND
        blocking.granted AND
        NOT l.granted
      WHERE NOT l.granted
    SQL
    
    locks = [] of LockInfo
    
    Grant.connection.query(sql) do |rs|
      while rs.move_next
        locks << LockInfo.new(
          transaction_id: rs.read(Int64),
          table: rs.read(String),
          lock_type: rs.read(String),
          granted: rs.read(Bool),
          waiting_for: rs.read(Int64?)
        )
      end
    end
    
    find_cycles(locks)
  end
  
  private def self.find_cycles(locks : Array(LockInfo)) : Array(LockInfo)
    # Detect circular wait conditions
    cycles = [] of LockInfo
    
    locks.each do |lock|
      next unless lock.waiting_for
      
      visited = Set(Int64).new
      current = lock
      
      while current.waiting_for
        if visited.includes?(current.transaction_id)
          # Found a cycle
          cycles << lock
          break
        end
        
        visited << current.transaction_id
        current = locks.find { |l| l.transaction_id == current.waiting_for }
        break unless current
      end
    end
    
    cycles
  end
end

class DeadlockPrevention
  # Always acquire locks in the same order
  def self.ordered_lock(ids : Array(Int64), &block)
    sorted_ids = ids.sort  # Consistent ordering
    
    Transaction.execute do
      sorted_ids.each do |id|
        Account.find_and_lock(id)
      end
      
      yield
    end
  end
  
  # Timeout-based prevention
  def self.with_timeout(duration : Time::Span, &block)
    Grant.connection.exec("SET LOCAL lock_timeout = '#{duration.total_milliseconds}ms'")
    
    begin
      yield
    rescue ex : DB::Error
      if ex.message.includes?("lock timeout")
        raise LockTimeoutError.new("Lock acquisition timed out after #{duration}")
      end
      raise ex
    ensure
      Grant.connection.exec("SET LOCAL lock_timeout = DEFAULT")
    end
  end
end

# Usage
DeadlockPrevention.ordered_lock([account1.id, account2.id]) do
  # Transfer funds between accounts
  account1.balance -= amount
  account2.balance += amount
  account1.save!
  account2.save!
end
```

## Distributed Transactions

### Two-Phase Commit

```crystal
class TwoPhaseCommit
  struct Participant
    property id : String
    property connection : DB::Database
    property prepared : Bool = false
  end
  
  def initialize
    @participants = [] of Participant
    @transaction_id = "tx_#{Random::Secure.hex(8)}"
  end
  
  def add_participant(id : String, connection : DB::Database)
    @participants << Participant.new(id, connection)
  end
  
  def execute(&block)
    # Phase 1: Prepare
    prepare_all
    
    begin
      # Execute transaction logic
      result = yield
      
      # Phase 2: Commit
      commit_all
      
      result
    rescue ex
      # Phase 2: Rollback
      rollback_all
      raise ex
    end
  end
  
  private def prepare_all
    @participants.each do |participant|
      begin
        participant.connection.exec("PREPARE TRANSACTION '#{@transaction_id}_#{participant.id}'")
        participant.prepared = true
      rescue ex
        # Rollback any prepared transactions
        rollback_all
        raise ex
      end
    end
  end
  
  private def commit_all
    @participants.each do |participant|
      next unless participant.prepared
      participant.connection.exec("COMMIT PREPARED '#{@transaction_id}_#{participant.id}'")
    end
  end
  
  private def rollback_all
    @participants.each do |participant|
      next unless participant.prepared
      
      begin
        participant.connection.exec("ROLLBACK PREPARED '#{@transaction_id}_#{participant.id}'")
      rescue
        # Log but continue rolling back others
        Log.error { "Failed to rollback participant #{participant.id}" }
      end
    end
  end
end

# Usage
tpc = TwoPhaseCommit.new
tpc.add_participant("db1", database1)
tpc.add_participant("db2", database2)

tpc.execute do
  # Operations across multiple databases
  database1.exec("UPDATE accounts SET balance = balance - 100 WHERE id = 1")
  database2.exec("UPDATE accounts SET balance = balance + 100 WHERE id = 2")
end
```

### Saga Pattern

```crystal
class Saga
  struct Step
    property name : String
    property execute : Proc(Nil)
    property compensate : Proc(Nil)
    property completed : Bool = false
  end
  
  def initialize(@name : String)
    @steps = [] of Step
    @completed_steps = [] of Step
  end
  
  def add_step(name : String, execute : Proc(Nil), compensate : Proc(Nil))
    @steps << Step.new(name, execute, compensate)
  end
  
  def execute
    Log.info { "Starting saga: #{@name}" }
    
    @steps.each do |step|
      begin
        Log.info { "Executing step: #{step.name}" }
        step.execute.call
        step.completed = true
        @completed_steps << step
      rescue ex
        Log.error { "Step #{step.name} failed: #{ex.message}" }
        compensate_all
        raise ex
      end
    end
    
    Log.info { "Saga completed: #{@name}" }
  end
  
  private def compensate_all
    Log.info { "Compensating saga: #{@name}" }
    
    @completed_steps.reverse_each do |step|
      begin
        Log.info { "Compensating step: #{step.name}" }
        step.compensate.call
      rescue ex
        Log.error { "Compensation failed for #{step.name}: #{ex.message}" }
        # Continue compensating other steps
      end
    end
  end
end

# Usage
order_saga = Saga.new("process_order")

order_saga.add_step(
  "reserve_inventory",
  -> { Inventory.reserve(product_id, quantity) },
  -> { Inventory.release(product_id, quantity) }
)

order_saga.add_step(
  "charge_payment",
  -> { Payment.charge(customer_id, amount) },
  -> { Payment.refund(customer_id, amount) }
)

order_saga.add_step(
  "create_shipment",
  -> { Shipment.create(order_id) },
  -> { Shipment.cancel(order_id) }
)

order_saga.execute
```

## Transaction Patterns

### Unit of Work

```crystal
class UnitOfWork
  def initialize
    @new_objects = [] of Grant::Base
    @dirty_objects = [] of Grant::Base
    @removed_objects = [] of Grant::Base
  end
  
  def register_new(object : Grant::Base)
    @new_objects << object unless @new_objects.includes?(object)
  end
  
  def register_dirty(object : Grant::Base)
    @dirty_objects << object unless @dirty_objects.includes?(object)
  end
  
  def register_removed(object : Grant::Base)
    @removed_objects << object unless @removed_objects.includes?(object)
  end
  
  def commit
    Transaction.execute do
      # Insert new objects
      @new_objects.each(&.save!)
      
      # Update dirty objects
      @dirty_objects.each(&.save!)
      
      # Delete removed objects
      @removed_objects.each(&.delete)
      
      clear
    end
  end
  
  def rollback
    clear
  end
  
  private def clear
    @new_objects.clear
    @dirty_objects.clear
    @removed_objects.clear
  end
end

# Usage
uow = UnitOfWork.new

# Register changes
new_user = User.new(name: "Alice")
uow.register_new(new_user)

existing_user = User.find!(1)
existing_user.email = "new@example.com"
uow.register_dirty(existing_user)

old_user = User.find!(2)
uow.register_removed(old_user)

# Commit all changes in a single transaction
uow.commit
```

### Transactional Outbox

```crystal
class OutboxEvent < Grant::Base
  column id : Int64, primary: true
  column aggregate_id : String
  column event_type : String
  column payload : JSON::Any
  column created_at : Time = Time.utc
  column processed_at : Time?
end

class TransactionalOutbox
  def self.with_event(event_type : String, payload : Hash, &block)
    Transaction.execute do
      # Execute business logic
      result = yield
      
      # Store event in same transaction
      OutboxEvent.create!(
        aggregate_id: result.id.to_s,
        event_type: event_type,
        payload: JSON.parse(payload.to_json)
      )
      
      result
    end
  end
  
  def self.process_events
    unprocessed = OutboxEvent.where(processed_at: nil)
                            .order(created_at: :asc)
                            .limit(100)
    
    unprocessed.each do |event|
      begin
        publish_event(event)
        event.update!(processed_at: Time.utc)
      rescue ex
        Log.error { "Failed to publish event #{event.id}: #{ex.message}" }
      end
    end
  end
  
  private def self.publish_event(event : OutboxEvent)
    # Publish to message queue
    MessageQueue.publish(
      topic: event.event_type,
      payload: event.payload,
      aggregate_id: event.aggregate_id
    )
  end
end

# Usage
order = TransactionalOutbox.with_event("order_created", {customer_id: 1, total: 99.99}) do
  Order.create!(customer_id: 1, total: 99.99)
end
```

## Performance Considerations

### Lock Monitoring

```crystal
class LockMonitor
  def self.current_locks
    sql = <<-SQL
      SELECT 
        pid,
        usename,
        application_name,
        state,
        query,
        wait_event_type,
        wait_event,
        pg_blocking_pids(pid) as blocking_pids
      FROM pg_stat_activity
      WHERE state != 'idle'
      ORDER BY backend_start
    SQL
    
    Grant.connection.query(sql)
  end
  
  def self.long_running_transactions(threshold : Time::Span = 5.minutes)
    sql = <<-SQL
      SELECT 
        pid,
        usename,
        NOW() - xact_start as duration,
        state,
        query
      FROM pg_stat_activity
      WHERE xact_start IS NOT NULL
        AND NOW() - xact_start > interval '#{threshold.total_seconds} seconds'
      ORDER BY xact_start
    SQL
    
    Grant.connection.query(sql)
  end
  
  def self.kill_long_transactions(threshold : Time::Span = 10.minutes)
    long_running_transactions(threshold).each do |tx|
      pid = tx["pid"].as(Int64)
      Log.warn { "Killing long-running transaction #{pid}" }
      Grant.connection.exec("SELECT pg_terminate_backend(?)", pid)
    end
  end
end
```

## Testing

```crystal
describe "Transactions and Locking" do
  it "rolls back on failure" do
    initial_count = User.count
    
    expect_raises(Exception) do
      Transaction.execute do
        User.create!(name: "Test1")
        User.create!(name: "Test2")
        raise "Rollback test"
      end
    end
    
    User.count.should eq(initial_count)
  end
  
  it "handles optimistic locking conflicts" do
    product = Product.create!(name: "Test", stock: 10)
    
    # Simulate concurrent updates
    product1 = Product.find!(product.id)
    product2 = Product.find!(product.id)
    
    product1.stock = 5
    product1.save!
    
    product2.stock = 3
    expect_raises(Product::StaleRecordError) do
      product2.save!
    end
  end
  
  it "prevents deadlocks with ordered locking" do
    account1 = Account.create!(balance: 100)
    account2 = Account.create!(balance: 200)
    
    # This should not deadlock
    spawn do
      DeadlockPrevention.ordered_lock([account1.id, account2.id]) do
        sleep 10.milliseconds
      end
    end
    
    spawn do
      DeadlockPrevention.ordered_lock([account2.id, account1.id]) do
        sleep 10.milliseconds
      end
    end
    
    sleep 50.milliseconds
    # Should complete without deadlock
  end
end
```

## Best Practices

### 1. Keep Transactions Short
```crystal
# Good: Short transaction
Transaction.execute do
  user.update!(status: "active")
end

# Bad: Long transaction
Transaction.execute do
  users = User.all.to_a  # Load everything
  users.each do |user|
    user.process_complex_logic  # Time-consuming
    user.save!
  end
end
```

### 2. Use Appropriate Isolation
```crystal
# Use serializable for critical financial operations
IsolatedTransaction.execute(IsolationLevel::Serializable) do
  transfer_funds(from, to, amount)
end

# Use read committed for reports
IsolatedTransaction.execute(IsolationLevel::ReadCommitted) do
  generate_report
end
```

### 3. Handle Lock Timeouts
```crystal
DeadlockPrevention.with_timeout(5.seconds) do
  # Attempt to acquire locks
  process_critical_section
rescue LockTimeoutError
  # Retry or handle gracefully
  Log.warn { "Lock timeout, retrying..." }
end
```

## Next Steps

- [Database Scaling](database-scaling.md)
- [Async and Concurrency](async-concurrency.md)
- [Monitoring and Performance](monitoring-and-performance.md)
- [Migrations](../advanced/data-management/migrations.md)