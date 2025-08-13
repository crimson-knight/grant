---
title: "Async Operations and Concurrency"
category: "infrastructure"
subcategory: "performance"
tags: ["async", "concurrency", "fibers", "channels", "non-blocking", "parallel-processing"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../core-features/querying-and-scopes.md", "../core-features/crud-operations.md"]
related_docs: ["database-scaling.md", "monitoring-and-performance.md", "../advanced/performance/query-optimization.md"]
last_updated: "2025-01-13"
estimated_read_time: "20 minutes"
use_cases: ["background-jobs", "bulk-operations", "real-time-updates", "high-concurrency", "streaming"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Async Operations and Concurrency

Comprehensive guide to implementing asynchronous database operations and managing concurrency in Grant applications using Crystal's fibers, channels, and non-blocking I/O.

## Overview

Crystal's concurrency model, based on fibers and channels, enables efficient async operations. This guide covers:
- Async query execution
- Fiber-based concurrency
- Channel communication patterns
- Connection pool management
- Parallel bulk operations
- Real-time streaming
- Race condition prevention

## Async Query Fundamentals

### Basic Async Operations

```crystal
class AsyncQuery
  def self.execute_async(query : String, params = [] of DB::Any)
    channel = Channel(DB::ResultSet | Exception).new
    
    spawn do
      begin
        result = Grant.connection.query(query, params)
        channel.send(result)
      rescue ex
        channel.send(ex)
      end
    end
    
    channel
  end
  
  def self.execute_many_async(queries : Array(String))
    channels = queries.map do |query|
      execute_async(query)
    end
    
    # Wait for all results
    channels.map do |ch|
      case result = ch.receive
      when Exception
        raise result
      else
        result
      end
    end
  end
end

# Usage
channel = AsyncQuery.execute_async("SELECT * FROM users WHERE active = true")
# Do other work...
result = channel.receive  # Block until ready
```

### Async Model Operations

```crystal
module AsyncOperations
  macro included
    def self.find_async(id : Int64)
      channel = Channel(self | Nil).new
      
      spawn do
        channel.send(find?(id))
      end
      
      channel
    end
    
    def self.where_async(**conditions)
      channel = Channel(Array(self)).new
      
      spawn do
        channel.send(where(**conditions).to_a)
      end
      
      channel
    end
    
    def save_async
      channel = Channel(Bool).new
      
      spawn do
        channel.send(save)
      end
      
      channel
    end
  end
end

class User < Grant::Base
  include AsyncOperations
  
  column id : Int64, primary: true
  column email : String
  column name : String
end

# Parallel user lookups
user_ids = [1, 2, 3, 4, 5]
channels = user_ids.map { |id| User.find_async(id) }
users = channels.map(&.receive).compact
```

## Fiber-Based Concurrency

### Fiber Pool Management

```crystal
class FiberPool
  def initialize(@size : Int32 = 100)
    @tasks = Channel(-> Nil).new(@size * 2)
    @running = Atomic(Int32).new(0)
    
    @size.times { spawn worker_loop }
  end
  
  def submit(&block : -> Nil)
    @tasks.send(block)
  end
  
  def submit_with_result(result_channel : Channel(T), &block : -> T) forall T
    submit do
      result = block.call
      result_channel.send(result)
    end
  end
  
  def shutdown
    @size.times { @tasks.send(->{ raise "shutdown" }) }
  end
  
  def active_count
    @running.get
  end
  
  private def worker_loop
    loop do
      task = @tasks.receive
      @running.add(1)
      
      begin
        task.call
      rescue ex
        Log.error(exception: ex) { "Fiber pool task failed" }
      ensure
        @running.sub(1)
      end
    end
  rescue
    # Shutdown signal
  end
end

# Global fiber pool
FIBER_POOL = FiberPool.new(50)

# Usage
results = Channel(String).new(100)

100.times do |i|
  FIBER_POOL.submit_with_result(results) do
    # Expensive operation
    User.where("created_at > ?", i.days.ago).count.to_s
  end
end

# Collect results
100.times { puts results.receive }
```

### Structured Concurrency

```crystal
class ConcurrentExecutor
  def self.parallel_map(items : Array(T), &block : T -> R) : Array(R) forall T, R
    return [] of R if items.empty?
    
    channel = Channel(Tuple(Int32, R)).new(items.size)
    
    items.each_with_index do |item, index|
      spawn do
        result = block.call(item)
        channel.send({index, result})
      end
    end
    
    # Collect and reorder results
    results = Array(R?).new(items.size, nil)
    items.size.times do
      index, result = channel.receive
      results[index] = result
    end
    
    results.compact
  end
  
  def self.parallel_each(items : Array(T), &block : T -> Nil) forall T
    done = Channel(Nil).new(items.size)
    
    items.each do |item|
      spawn do
        block.call(item)
        done.send(nil)
      end
    end
    
    items.size.times { done.receive }
  end
  
  def self.race(tasks : Array(Proc(T))) : T forall T
    channel = Channel(T).new(tasks.size)
    
    tasks.each do |task|
      spawn { channel.send(task.call) }
    end
    
    # Return first result
    result = channel.receive
    
    # Optionally cancel other tasks
    result
  end
end

# Parallel processing example
user_ids = (1..1000).to_a
user_names = ConcurrentExecutor.parallel_map(user_ids) do |id|
  User.find?(id).try(&.name) || "Unknown"
end
```

## Channel Patterns

### Producer-Consumer Pattern

```crystal
class WorkQueue(T)
  def initialize(@capacity : Int32 = 100)
    @items = Channel(T).new(@capacity)
    @done = Channel(Nil).new
    @consumers = [] of Fiber
  end
  
  def produce(item : T)
    @items.send(item)
  end
  
  def start_consumers(count : Int32, &block : T -> Nil)
    count.times do
      @consumers << spawn do
        loop do
          select
          when item = @items.receive
            block.call(item)
          when @done.receive
            break
          end
        end
      end
    end
  end
  
  def stop
    @consumers.size.times { @done.send(nil) }
  end
end

# Email processing queue
email_queue = WorkQueue(Int64).new(1000)

email_queue.start_consumers(10) do |user_id|
  user = User.find?(user_id)
  if user
    EmailService.send_newsletter(user)
  end
end

# Producer
User.where(subscribed: true).each do |user|
  email_queue.produce(user.id)
end
```

### Fan-Out/Fan-In Pattern

```crystal
class FanOutFanIn
  def self.process(input : Array(T), workers : Int32, &block : T -> R) : Array(R) forall T, R
    work_channel = Channel(T).new(input.size)
    result_channel = Channel(R).new(input.size)
    
    # Fan-out: distribute work
    spawn do
      input.each { |item| work_channel.send(item) }
      work_channel.close
    end
    
    # Workers
    workers.times do
      spawn do
        while item = work_channel.receive?
          result = block.call(item)
          result_channel.send(result)
        end
      end
    end
    
    # Fan-in: collect results
    results = [] of R
    input.size.times do
      results << result_channel.receive
    end
    
    results
  end
end

# Process large dataset
data = (1..10000).to_a
results = FanOutFanIn.process(data, workers: 20) do |n|
  # Expensive computation
  Math.sqrt(n.to_f)
end
```

### Pipeline Pattern

```crystal
class Pipeline(T)
  struct Stage(I, O)
    getter name : String
    getter processor : Proc(I, O)
    
    def initialize(@name, &@processor : I -> O)
    end
  end
  
  def initialize(@input : Channel(T))
    @stages = [] of Stage
  end
  
  def add_stage(name : String, &block : T -> R) : Pipeline(R) forall R
    output = Channel(R).new(100)
    
    spawn do
      while item = @input.receive?
        result = block.call(item)
        output.send(result)
      end
      output.close
    end
    
    Pipeline(R).new(output)
  end
  
  def collect : Array(T)
    results = [] of T
    while item = @input.receive?
      results << item
    end
    results
  end
end

# Data processing pipeline
input = Channel(String).new(100)

results = Pipeline.new(input)
  .add_stage("parse") { |text| JSON.parse(text) }
  .add_stage("validate") { |json| validate_data(json) }
  .add_stage("transform") { |data| transform_to_model(data) }
  .add_stage("save") { |model| model.save! }
  .collect

# Feed the pipeline
File.each_line("data.jsonl") do |line|
  input.send(line)
end
input.close
```

## Bulk Operations

### Parallel Bulk Insert

```crystal
class BulkInserter
  def self.insert_parallel(model_class : Grant::Base.class, 
                           records : Array(Hash(String, DB::Any)),
                           batch_size : Int32 = 1000,
                           workers : Int32 = 4)
    batches = records.in_groups_of(batch_size, reuse: false)
    insert_channels = [] of Channel(Int32)
    
    batches.each do |batch|
      channel = Channel(Int32).new
      insert_channels << channel
      
      spawn do
        count = insert_batch(model_class, batch.compact)
        channel.send(count)
      end
    end
    
    # Wait for all batches
    total = insert_channels.sum { |ch| ch.receive }
    total
  end
  
  private def self.insert_batch(model_class, batch : Array(Hash(String, DB::Any)))
    return 0 if batch.empty?
    
    table = model_class.table_name
    columns = batch.first.keys
    
    values_sql = batch.map { |_| 
      "(#{columns.map { "?" }.join(", ")})"
    }.join(", ")
    
    sql = "INSERT INTO #{table} (#{columns.join(", ")}) VALUES #{values_sql}"
    
    values = batch.flat_map { |record| 
      columns.map { |col| record[col] }
    }
    
    Grant.connection.exec(sql, args: values)
    batch.size
  end
end

# Usage
records = Array(Hash(String, DB::Any)).new
10000.times do |i|
  records << {
    "name" => "User #{i}",
    "email" => "user#{i}@example.com",
    "created_at" => Time.utc
  }
end

count = BulkInserter.insert_parallel(User, records)
puts "Inserted #{count} records"
```

### Concurrent Updates

```crystal
class ConcurrentUpdater
  def self.update_where(model_class : Grant::Base.class,
                        conditions : Hash(String, DB::Any),
                        updates : Hash(String, DB::Any),
                        batch_size : Int32 = 100)
    # Find IDs to update
    ids = model_class.where(**conditions).pluck(:id)
    
    # Process in parallel batches
    id_batches = ids.in_groups_of(batch_size, reuse: false)
    update_channels = [] of Channel(Int32)
    
    id_batches.each do |batch|
      channel = Channel(Int32).new
      update_channels << channel
      
      spawn do
        count = update_batch(model_class, batch.compact, updates)
        channel.send(count)
      end
    end
    
    # Wait for completion
    total = update_channels.sum { |ch| ch.receive }
    total
  end
  
  private def self.update_batch(model_class, ids : Array(Int64), updates)
    return 0 if ids.empty?
    
    set_clause = updates.map { |col, _| "#{col} = ?" }.join(", ")
    sql = <<-SQL
      UPDATE #{model_class.table_name}
      SET #{set_clause}
      WHERE id IN (#{ids.map { "?" }.join(", ")})
    SQL
    
    values = updates.values + ids
    Grant.connection.exec(sql, args: values)
    ids.size
  end
end

# Update all inactive users
count = ConcurrentUpdater.update_where(
  User,
  {"last_login" => 30.days.ago},
  {"status" => "inactive", "updated_at" => Time.utc}
)
```

## Stream Processing

### Database Cursor Streaming

```crystal
class StreamProcessor
  def self.stream_query(sql : String, params = [] of DB::Any, &block : DB::ResultSet -> Nil)
    Grant.connection.query(sql, params) do |rs|
      while rs.move_next
        spawn { block.call(rs) }
      end
    end
  end
  
  def self.stream_in_batches(model_class : Grant::Base.class, 
                             batch_size : Int32 = 100,
                             &block : Array(Grant::Base) -> Nil)
    offset = 0
    
    loop do
      batch = model_class.limit(batch_size).offset(offset).to_a
      break if batch.empty?
      
      spawn { block.call(batch) }
      offset += batch_size
      
      # Throttle if needed
      sleep 10.milliseconds if offset % 1000 == 0
    end
  end
end

# Stream large result set
StreamProcessor.stream_query(
  "SELECT * FROM events WHERE created_at > ?",
  [7.days.ago]
) do |rs|
  event = Event.new(rs)
  EventProcessor.process(event)
end
```

### Real-Time Change Streaming

```crystal
class ChangeStream
  def initialize(@model_class : Grant::Base.class)
    @listeners = [] of Channel(ChangeEvent)
    @running = false
  end
  
  struct ChangeEvent
    enum Type
      Insert
      Update
      Delete
    end
    
    property type : Type
    property id : Int64
    property data : JSON::Any?
    property timestamp : Time
  end
  
  def subscribe : Channel(ChangeEvent)
    channel = Channel(ChangeEvent).new(100)
    @listeners << channel
    channel
  end
  
  def start
    return if @running
    @running = true
    
    spawn monitor_changes
  end
  
  def stop
    @running = false
  end
  
  private def monitor_changes
    # PostgreSQL LISTEN/NOTIFY
    Grant.connection.exec("LISTEN #{@model_class.table_name}_changes")
    
    while @running
      Grant.connection.exec("SELECT 1")  # Keep connection alive
      
      # Check for notifications
      if notification = check_notification
        event = parse_notification(notification)
        broadcast(event)
      end
      
      sleep 100.milliseconds
    end
  end
  
  private def broadcast(event : ChangeEvent)
    @listeners.each do |channel|
      channel.send(event) unless channel.closed?
    end
  end
end

# Usage
stream = ChangeStream.new(User)
channel = stream.subscribe
stream.start

spawn do
  while event = channel.receive?
    case event.type
    when .insert?
      puts "New user created: #{event.id}"
    when .update?
      puts "User updated: #{event.id}"
    when .delete?
      puts "User deleted: #{event.id}"
    end
  end
end
```

## Concurrency Control

### Optimistic Locking

```crystal
module OptimisticLocking
  macro included
    column lock_version : Int32 = 0
    
    before_update :check_lock_version
    after_update :increment_lock_version
    
    class StaleObjectError < Exception
    end
    
    private def check_lock_version
      if lock_version_changed?
        current = self.class.find!(id).lock_version
        if current != lock_version_was
          raise StaleObjectError.new(
            "Attempted to update stale #{self.class.name} with id=#{id}"
          )
        end
      end
    end
    
    private def increment_lock_version
      self.lock_version += 1
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

# Concurrent update handling
def update_product_stock(product_id : Int64, quantity : Int32)
  max_retries = 3
  retry_count = 0
  
  loop do
    product = Product.find!(product_id)
    product.stock -= quantity
    
    begin
      product.save!
      break
    rescue Product::StaleObjectError
      retry_count += 1
      raise if retry_count >= max_retries
      
      # Exponential backoff
      sleep (2 ** retry_count).milliseconds
    end
  end
end
```

### Pessimistic Locking

```crystal
class PessimisticLock
  def self.with_lock(model_class : Grant::Base.class, id : Int64, &block)
    Grant.transaction do
      # Lock record for update
      sql = "SELECT * FROM #{model_class.table_name} WHERE id = ? FOR UPDATE"
      Grant.connection.exec(sql, id)
      
      record = model_class.find!(id)
      yield record
    end
  end
  
  def self.with_advisory_lock(key : Int64, &block)
    # PostgreSQL advisory lock
    Grant.connection.exec("SELECT pg_advisory_lock(?)", key)
    
    begin
      yield
    ensure
      Grant.connection.exec("SELECT pg_advisory_unlock(?)", key)
    end
  end
end

# Usage
PessimisticLock.with_lock(BankAccount, account_id) do |account|
  account.balance -= amount
  account.save!
end
```

### Semaphore for Rate Limiting

```crystal
class Semaphore
  def initialize(@capacity : Int32)
    @available = Channel(Nil).new(@capacity)
    @capacity.times { @available.send(nil) }
  end
  
  def acquire
    @available.receive
  end
  
  def release
    @available.send(nil)
  end
  
  def with_lock(&block)
    acquire
    begin
      yield
    ensure
      release
    end
  end
end

# Rate limit database operations
DB_SEMAPHORE = Semaphore.new(10)  # Max 10 concurrent DB operations

def process_user(user_id : Int64)
  DB_SEMAPHORE.with_lock do
    user = User.find!(user_id)
    # Process user...
  end
end
```

## Performance Patterns

### Connection Multiplexing

```crystal
class ConnectionMultiplexer
  def initialize(@pool_size : Int32 = 10)
    @connections = Array(DB::Database).new(@pool_size) do
      DB.open(ENV["DATABASE_URL"])
    end
    @current = Atomic(Int32).new(0)
  end
  
  def execute(query : String, params = [] of DB::Any)
    connection = next_connection
    connection.exec(query, params)
  end
  
  def parallel_execute(queries : Array(String))
    channels = queries.map_with_index do |query, index|
      channel = Channel(DB::ResultSet).new
      
      spawn do
        connection = @connections[index % @pool_size]
        result = connection.query(query)
        channel.send(result)
      end
      
      channel
    end
    
    channels.map(&.receive)
  end
  
  private def next_connection
    index = @current.add(1) % @pool_size
    @connections[index]
  end
end
```

### Async Cache Warming

```crystal
class AsyncCacheWarmer
  def self.warm_cache(keys : Array(String))
    warming_channels = [] of Channel(Nil)
    
    keys.each_slice(100) do |key_batch|
      channel = Channel(Nil).new
      warming_channels << channel
      
      spawn do
        key_batch.each do |key|
          # Warm cache entry
          value = expensive_computation(key)
          Cache.set(key, value, expires_in: 1.hour)
        end
        channel.send(nil)
      end
    end
    
    # Wait for all warming to complete
    warming_channels.each(&.receive)
  end
  
  private def self.expensive_computation(key : String)
    # Simulate expensive operation
    result = Grant.connection.scalar(
      "SELECT COUNT(*) FROM large_table WHERE category = ?",
      key
    )
    result.to_s
  end
end

# Warm cache on startup
spawn do
  categories = Category.pluck(:name)
  AsyncCacheWarmer.warm_cache(categories)
  Log.info { "Cache warming complete" }
end
```

## Error Handling

### Retry with Backoff

```crystal
class RetryableOperation
  def self.with_retry(max_attempts : Int32 = 3, 
                      backoff : Time::Span = 100.milliseconds,
                      &block)
    attempt = 0
    
    loop do
      attempt += 1
      
      begin
        return yield
      rescue ex
        if attempt >= max_attempts
          Log.error { "Operation failed after #{max_attempts} attempts" }
          raise ex
        end
        
        wait_time = backoff * (2 ** (attempt - 1))
        Log.warn { "Attempt #{attempt} failed, retrying in #{wait_time}" }
        sleep wait_time
      end
    end
  end
end

# Usage
result = RetryableOperation.with_retry do
  User.find!(id)  # May fail due to connection issues
end
```

### Timeout Protection

```crystal
class TimeoutProtection
  def self.with_timeout(duration : Time::Span, &block)
    channel = Channel(Exception | Nil).new
    
    spawn do
      begin
        yield
        channel.send(nil)
      rescue ex
        channel.send(ex)
      end
    end
    
    select
    when result = channel.receive
      raise result if result.is_a?(Exception)
    when timeout(duration)
      raise "Operation timed out after #{duration}"
    end
  end
end

# Protect against slow queries
TimeoutProtection.with_timeout(5.seconds) do
  Report.generate_complex_analytics
end
```

## Testing Async Code

```crystal
describe "Async Operations" do
  it "processes queries in parallel" do
    start = Time.monotonic
    
    results = ConcurrentExecutor.parallel_map([1, 2, 3]) do |n|
      sleep 100.milliseconds  # Simulate work
      n * 2
    end
    
    duration = Time.monotonic - start
    
    results.should eq([2, 4, 6])
    duration.should be < 200.milliseconds  # Should run in parallel
  end
  
  it "handles concurrent updates correctly" do
    product = Product.create!(name: "Test", stock: 100)
    
    # Simulate concurrent stock updates
    fibers = 10.times.map do
      spawn do
        p = Product.find!(product.id)
        p.stock -= 1
        p.save!
      end
    end.to_a
    
    # Wait for all fibers
    fibers.each(&.wait)
    
    product.reload
    product.stock.should eq(90)
  end
end
```

## Best Practices

### 1. Use Channels for Communication
```crystal
# Good: Channel-based communication
channel = Channel(Result).new
spawn { channel.send(compute_result) }
result = channel.receive

# Avoid: Shared mutable state
# @@result = nil
# spawn { @@result = compute_result }
```

### 2. Limit Concurrent Operations
```crystal
# Prevent resource exhaustion
MAX_CONCURRENT = 50
semaphore = Channel(Nil).new(MAX_CONCURRENT)

items.each do |item|
  semaphore.send(nil)
  spawn do
    process(item)
    semaphore.receive
  end
end
```

### 3. Handle Fiber Failures
```crystal
spawn do
  begin
    risky_operation
  rescue ex
    Log.error(exception: ex) { "Fiber failed" }
    ErrorReporter.report(ex)
  end
end
```

## Next Steps

- [Database Scaling](database-scaling.md)
- [Monitoring and Performance](monitoring-and-performance.md)
- [Transactions and Locking](transactions-and-locking.md)
- [Query Optimization](../advanced/performance/query-optimization.md)