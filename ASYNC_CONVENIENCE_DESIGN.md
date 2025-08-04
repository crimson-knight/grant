# Async Convenience Features Design

## Overview

This document outlines the design and implementation of async convenience features for Grant ORM, leveraging Crystal's native concurrency model with fibers and the WaitGroup synchronization primitive.

## Goals

1. Provide non-blocking async versions of common database operations
2. Enable parallel execution of queries across multiple shards
3. Maintain consistency with existing Grant API patterns
4. Ensure proper error handling and resource management
5. Optimize for performance while maintaining safety

## Architecture

### Core Components

#### 1. AsyncResult<T>
A wrapper that represents a pending async operation result.

```crystal
class AsyncResult(T)
  @promise : Promise(T)
  @fiber : Fiber?
  @completed : Atomic(Bool)
  
  def initialize(&block : -> T)
    @completed = Atomic(Bool).new(false)
    @promise = Promise(T).new
    @fiber = spawn do
      begin
        result = block.call
        @promise.resolve(result)
      rescue e
        @promise.reject(e)
      ensure
        @completed.set(true)
      end
    end
  end
  
  def wait : T
    @promise.get
  end
  
  def completed? : Bool
    @completed.get
  end
end
```

#### 2. AsyncCoordinator
Manages multiple async operations using WaitGroup.

```crystal
class AsyncCoordinator
  @wait_group : WaitGroup
  @results : Array(AsyncResult)
  
  def initialize
    @wait_group = WaitGroup.new
    @results = [] of AsyncResult
  end
  
  def add(result : AsyncResult)
    @wait_group.add(1)
    @results << result
    spawn do
      result.wait
      @wait_group.done
    end
  end
  
  def wait_all
    @wait_group.wait
  end
end
```

#### 3. Promise<T>
A simple promise implementation for async results.

```crystal
class Promise(T)
  @channel : Channel(T | Exception)
  @resolved : Atomic(Bool)
  
  def initialize
    @channel = Channel(T | Exception).new(1)
    @resolved = Atomic(Bool).new(false)
  end
  
  def resolve(value : T)
    return if @resolved.get
    @resolved.set(true)
    @channel.send(value)
  end
  
  def reject(error : Exception)
    return if @resolved.get
    @resolved.set(true)
    @channel.send(error)
  end
  
  def get : T
    result = @channel.receive
    case result
    when Exception
      raise result
    else
      result.as(T)
    end
  end
end
```

## API Design

### Async Aggregations

```crystal
class User < Granite::Base
  # Async count
  def self.async_count : AsyncResult(Int64)
    AsyncResult.new { count }
  end
  
  # Async sum
  def self.async_sum(column : Symbol | String) : AsyncResult(Float64)
    AsyncResult.new { sum(column) }
  end
  
  # Async average
  def self.async_avg(column : Symbol | String) : AsyncResult(Float64?)
    AsyncResult.new { avg(column) }
  end
  
  # Async min/max
  def self.async_min(column : Symbol | String) : AsyncResult(Granite::Columns::Type)
    AsyncResult.new { min(column) }
  end
  
  def self.async_max(column : Symbol | String) : AsyncResult(Granite::Columns::Type)
    AsyncResult.new { max(column) }
  end
end
```

### Async Queries

```crystal
# Async pluck
def self.async_pluck(column : Symbol | String) : AsyncResult(Array(Granite::Columns::Type))
  AsyncResult.new { pluck(column) }
end

# Async pick (first value)
def self.async_pick(column : Symbol | String) : AsyncResult(Granite::Columns::Type?)
  AsyncResult.new { pick(column) }
end

# Async find
def self.async_find(id) : AsyncResult(self?)
  AsyncResult.new { find(id) }
end

# Async find_by
def self.async_find_by(**args) : AsyncResult(self?)
  AsyncResult.new { find_by(**args) }
end

# Async all
def self.async_all : AsyncResult(Array(self))
  AsyncResult.new { all }
end

# Async where
def async_select : AsyncResult(Array(Model))
  AsyncResult.new { select }
end
```

### Async Bulk Operations

```crystal
# Async update_all
def async_update : AsyncResult(Int64)
  AsyncResult.new { update }
end

# Async delete
def async_delete : AsyncResult(Int64)
  AsyncResult.new { delete }
end

# Async touch_all
def async_touch_all(*fields : Symbol) : AsyncResult(Int64)
  time = Time.utc
  AsyncResult.new { touch_all(fields, time) }
end
```

### Parallel Execution with WaitGroup

```crystal
# Execute multiple async operations in parallel
def self.parallel_execute
  coordinator = AsyncCoordinator.new
  
  # Add multiple async operations
  coordinator.add(User.async_count)
  coordinator.add(Order.where(status: "pending").async_count)
  coordinator.add(Product.async_avg(:price))
  
  # Wait for all to complete
  coordinator.wait_all
end
```

## Sharding Integration

### Parallel Shard Queries

```crystal
class ShardedAsyncExecutor
  def self.execute_across_shards(shards : Array(Symbol), &block : Symbol -> AsyncResult)
    coordinator = AsyncCoordinator.new
    results = {} of Symbol => AsyncResult
    
    shards.each do |shard|
      result = Grant::ShardManager.with_shard(shard) do
        block.call(shard)
      end
      results[shard] = result
      coordinator.add(result)
    end
    
    coordinator.wait_all
    results
  end
end

# Example usage
results = ShardedAsyncExecutor.execute_across_shards([:shard1, :shard2, :shard3]) do |shard|
  User.async_count
end

# Get individual results
shard1_count = results[:shard1].wait
```

### Async Shard Resolver

```crystal
class AsyncShardResolver
  def resolve_async(key : String) : AsyncResult(Symbol)
    AsyncResult.new do
      # Potentially expensive shard resolution
      sleep 0.1  # Simulate network lookup
      :shard1
    end
  end
end
```

## Error Handling

### Custom Error Types

```crystal
class AsyncExecutionError < Exception
  getter operation : String
  getter original_error : Exception
  
  def initialize(@operation : String, @original_error : Exception)
    super("Async operation '#{@operation}' failed: #{@original_error.message}")
  end
end

class AsyncTimeoutError < Exception
  getter operation : String
  getter timeout : Time::Span
  
  def initialize(@operation : String, @timeout : Time::Span)
    super("Async operation '#{@operation}' timed out after #{@timeout}")
  end
end
```

### Error Recovery

```crystal
class AsyncResult(T)
  def wait_with_timeout(timeout : Time::Span) : T
    select
    when result = @promise.get_channel.receive
      handle_result(result)
    when timeout(timeout)
      raise AsyncTimeoutError.new("async operation", timeout)
    end
  end
  
  def on_error(&block : Exception -> T) : T
    begin
      wait
    rescue e
      block.call(e)
    end
  end
end
```

## Connection Pool Management

### Async-aware Pool

```crystal
module Grant
  class AsyncConnectionPool
    @semaphore : Semaphore
    
    def initialize(size : Int32)
      @semaphore = Semaphore.new(size)
    end
    
    def with_connection(&block)
      @semaphore.acquire
      begin
        yield
      ensure
        @semaphore.release
      end
    end
  end
end
```

## Performance Considerations

1. **Fiber Pool**: Reuse fibers for better performance
2. **Batching**: Group small queries to reduce overhead
3. **Circuit Breaker**: Prevent cascading failures
4. **Metrics**: Track async operation performance

```crystal
class AsyncMetrics
  class_property total_operations = Atomic(Int64).new(0)
  class_property active_operations = Atomic(Int64).new(0)
  class_property failed_operations = Atomic(Int64).new(0)
  
  def self.track_operation(&block)
    active_operations.add(1)
    total_operations.add(1)
    
    begin
      yield
    rescue e
      failed_operations.add(1)
      raise e
    ensure
      active_operations.sub(1)
    end
  end
end
```

## Testing Strategy

### Unit Tests
- Test AsyncResult behavior
- Test Promise resolution/rejection
- Test AsyncCoordinator with WaitGroup
- Test error handling

### Integration Tests
- Test async database operations
- Test parallel shard execution
- Test connection pool behavior
- Test timeout handling

### Performance Tests
- Benchmark async vs sync operations
- Test concurrent operation limits
- Measure memory usage
- Stress test with many fibers

## Implementation Phases

1. **Phase 1**: Core async infrastructure (AsyncResult, Promise, AsyncCoordinator)
2. **Phase 2**: Async query methods (count, sum, find, etc.)
3. **Phase 3**: Sharding integration
4. **Phase 4**: Advanced features (timeout, retry, circuit breaker)
5. **Phase 5**: Performance optimization and metrics

## Example Usage

```crystal
# Simple async count
count_result = User.async_count
puts "Doing other work..."
user_count = count_result.wait

# Parallel aggregations
coordinator = AsyncCoordinator.new
count_async = User.async_count
sum_async = Order.async_sum(:total)
avg_async = Product.async_avg(:rating)

coordinator.add(count_async)
coordinator.add(sum_async)
coordinator.add(avg_async)

coordinator.wait_all

puts "Users: #{count_async.wait}"
puts "Order total: #{sum_async.wait}"
puts "Avg rating: #{avg_async.wait}"

# Async with sharding
shard_counts = ShardedAsyncExecutor.execute_across_shards([:us_east, :us_west, :eu]) do |shard|
  User.where(active: true).async_count
end

total = shard_counts.values.sum { |result| result.wait }
puts "Total active users across all shards: #{total}"

# Error handling
result = User.async_find(999).on_error do |e|
  puts "User not found: #{e.message}"
  nil
end
```

## Backward Compatibility

The async features are additive and don't break existing synchronous APIs. All async methods follow the pattern of prefixing with `async_` to clearly distinguish them from synchronous counterparts.

## Future Enhancements

1. **Streaming Results**: Support for streaming large result sets
2. **Reactive Patterns**: Observable/Subject patterns for real-time updates
3. **Async Transactions**: Support for distributed transactions
4. **Query Pipelining**: Batch multiple queries in a single round trip
5. **Async Migrations**: Run migrations in parallel across shards