# Async Convenience Features

Grant provides async convenience features for non-blocking database operations using Crystal's fiber-based concurrency. These features allow you to execute multiple database queries concurrently, improving performance for I/O-bound operations.

## Overview

The async API is built on Crystal's native concurrency primitives:
- **Fibers**: Lightweight threads of execution
- **Channels**: Communication between fibers
- **WaitGroup**: Synchronization for multiple concurrent operations

## Basic Usage

### Simple Async Operations

All async methods return an `AsyncResult` object that wraps the operation:

```crystal
# Find a user asynchronously
result = User.async_find(1)
user = result.await  # Blocks until complete

# Find by attributes
result = User.async_find_by(email: "user@example.com")
user = result.await
```

### Concurrent Operations

Execute multiple queries concurrently using the `Coordinator`:

```crystal
coordinator = Grant::Async::Coordinator.new

# Add multiple async operations
coordinator.add(User.async_count)
coordinator.add(Post.async_count)
coordinator.add(Comment.async_count)

# Wait for all to complete
results = coordinator.await_all

user_count = results[0]
post_count = results[1]
comment_count = results[2]
```

### Type-Safe Result Handling

For operations returning different types, use `ResultCoordinator`:

```crystal
coordinator = Grant::Async::ResultCoordinator(User).new

# Add operations returning User instances
coordinator.add(User.async_find(1))
coordinator.add(User.async_find_by(email: "admin@example.com"))
coordinator.add(User.async_first)

# Get all results as Array(User?)
users = coordinator.await_all
```

## Available Async Methods

### Query Methods

- `async_find(id)` - Find by primary key
- `async_find!(id)` - Find by primary key, raises if not found
- `async_find_by(**args)` - Find by attributes
- `async_find_by!(**args)` - Find by attributes, raises if not found
- `async_first` - Get first record
- `async_first!` - Get first record, raises if not found
- `async_last` - Get last record
- `async_last!` - Get last record, raises if not found
- `async_all` - Get all records
- `async_exists?(**args)` - Check if record exists

### Aggregation Methods

- `async_count` - Count records
- `async_sum(column)` - Sum column values
- `async_avg(column)` - Average column values
- `async_min(column)` - Minimum column value
- `async_max(column)` - Maximum column value
- `async_pluck(column)` - Extract column values
- `async_pick(column)` - Extract first column value

### Bulk Operations

- `async_update_all(**args)` - Update all matching records
- `async_delete_all` - Delete all matching records

### Instance Methods

- `async_save` - Save record
- `async_save!` - Save record, raises on failure
- `async_update(**args)` - Update attributes
- `async_update!(**args)` - Update attributes, raises on failure
- `async_destroy` - Delete record

## Query Builder Integration

Async methods work seamlessly with query builders:

```crystal
# Chain query methods before async execution
active_users = User.where(active: true)
                  .order(created_at: :desc)
                  .limit(10)
                  .async_all
                  .await

# Async aggregations with conditions
total_spend = Order.where(user_id: user.id)
                   .async_sum(:total)
                   .await

# Complex queries
result = Post.joins(:comments)
             .where("comments.created_at > ?", 1.week.ago)
             .group(:id)
             .having("COUNT(comments.id) > ?", 5)
             .async_count
             .await
```

## Sharding Support

Async operations fully support database sharding:

```crystal
# Async operation on specific shard
result = User.shard("shard_1").async_find(user_id)
user = result.await

# Concurrent operations across shards
coordinator = Grant::Async::Coordinator.new

["shard_1", "shard_2", "shard_3"].each do |shard|
  coordinator.add(User.shard(shard).async_count)
end

shard_counts = coordinator.await_all
total_users = shard_counts.sum
```

## Error Handling

Async operations capture and propagate errors:

```crystal
begin
  user = User.async_find!(999999).await
rescue Grant::Querying::NotFound
  puts "User not found"
end

# Check for errors without raising
result = User.async_find(999999)
begin
  user = result.await
rescue ex
  puts "Error: #{ex.message}"
end
```

### Coordinator Error Handling

The Coordinator provides access to all errors:

```crystal
coordinator = Grant::Async::Coordinator.new

coordinator.add(User.async_find!(1))
coordinator.add(User.async_find!(999999))  # Will fail
coordinator.add(User.async_find!(3))

results = coordinator.await_all
errors = coordinator.errors

errors.each_with_index do |error, index|
  if error
    puts "Operation #{index} failed: #{error.message}"
  end
end
```

## Performance Considerations

### When to Use Async

Async operations are beneficial when:
- Executing multiple independent queries
- Queries have high latency (network I/O)
- The application can handle concurrent load
- You need to aggregate data from multiple sources

### When Not to Use Async

Avoid async operations when:
- Queries are simple and fast
- Operations must be executed sequentially
- Transaction consistency is required
- System resources are limited

### Example: Efficient Dashboard Loading

```crystal
# Inefficient: Sequential execution
def load_dashboard_data_sync
  user_count = User.count
  post_count = Post.count
  comment_count = Comment.count
  recent_users = User.order(created_at: :desc).limit(5).select
  popular_posts = Post.order(views: :desc).limit(10).select
  
  # Total time: sum of all query times
end

# Efficient: Concurrent execution
def load_dashboard_data_async
  coordinator = Grant::Async::Coordinator.new
  
  coordinator.add(User.async_count)
  coordinator.add(Post.async_count)
  coordinator.add(Comment.async_count)
  coordinator.add(User.order(created_at: :desc).limit(5).async_all)
  coordinator.add(Post.order(views: :desc).limit(10).async_all)
  
  results = coordinator.await_all
  
  # Total time: approximately the slowest query time
  {
    user_count: results[0],
    post_count: results[1],
    comment_count: results[2],
    recent_users: results[3],
    popular_posts: results[4]
  }
end
```

## Implementation Details

### AsyncResult

The `AsyncResult` class wraps async operations:

```crystal
class AsyncResult(T)
  # Start the async operation
  def start : self
  
  # Wait for completion and return result
  def await : T
  
  # Check if completed without blocking
  def completed? : Bool
  
  # Get the underlying promise
  def promise : Promise(T)
end
```

### Promise

A simple promise implementation for single-value resolution:

```crystal
class Promise(T)
  # Resolve with a value
  def resolve(value : T)
  
  # Reject with an error
  def reject(error : Exception)
  
  # Get the value (blocks if not resolved)
  def get : T
end
```

### Connection Pool Integration

Async operations efficiently use the connection pool:
- Each fiber gets its own connection from the pool
- Connections are returned immediately after query completion
- Pool size limits concurrent operations automatically

## Best Practices

1. **Group Related Operations**: Use Coordinator for related queries that can run concurrently

2. **Handle Errors Gracefully**: Always consider error cases when using async operations

3. **Monitor Performance**: Async operations add overhead; measure to ensure benefits

4. **Respect Connection Limits**: Don't spawn more concurrent operations than your connection pool can handle

5. **Use Type-Safe Coordinators**: When working with homogeneous results, use `ResultCoordinator<T>`

## Future Enhancements

Planned improvements include:
- Streaming result sets for large queries
- Async transaction support
- Circuit breaker pattern for failing queries
- Automatic retry with backoff
- Query result caching integration