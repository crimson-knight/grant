# Granite Instrumentation

Granite provides built-in instrumentation for debugging, monitoring, and performance analysis using Crystal's native `Log` module. This lightweight approach avoids the overhead of pub-sub systems while providing rich insights into your application's database interactions.

## Overview

The instrumentation system provides:

- **SQL Query Logging** - Track all database queries with timing information
- **Model Lifecycle Logging** - Monitor create, update, and destroy operations
- **Association Loading Logs** - Detect inefficient association loading patterns
- **Query Analysis** - Identify N+1 queries and performance bottlenecks
- **Development Formatters** - Beautiful, colored output for development

## Quick Start

### Basic Setup

Configure logging in your application:

```crystal
# config/initializers/logging.cr
Log.setup do |c|
  backend = Log::IOBackend.new(formatter: Log::ShortFormat)
  
  # Log SQL queries at debug level
  c.bind "granite.sql", :debug, backend
  
  # Log model operations at info level
  c.bind "granite.model", :info, backend
  
  # Warn about slow queries
  c.bind "granite.sql", :warn, backend
end
```

### Development Mode

For beautiful colored output during development:

```crystal
# config/environments/development.cr
require "granite/logging"

# Enable all development formatters
Granite::Development.setup_logging
```

This gives you colored, formatted output for all Granite operations:

```
▸ User (5.2ms) → 10 rows
    SELECT * FROM users WHERE active = true

➕ User#123 - Creating record
✓ User#123 - Record created

↔ Post#comments → Comment (3.1ms) [5 records]
```

## Logging Components

### SQL Query Logging

All SQL queries are automatically logged with timing information:

```crystal
# Logged at debug level for all queries
Granite::Logs::SQL.debug &.emit("Query executed",
  sql: sql,
  model: "User",
  duration_ms: 5.2,
  row_count: 10
)

# Slow queries (>100ms) are logged as warnings
Granite::Logs::SQL.warn &.emit("Slow query detected",
  sql: sql,
  model: "User", 
  duration_ms: 250.5
)
```

### Model Lifecycle Events

Track record creation, updates, and deletions:

```crystal
# Creating records
user = User.create(name: "John")
# Logs: Creating record... Record created

# Updating records
user.name = "Jane"
user.save
# Logs: Updating record... Record updated

# Destroying records
user.destroy
# Logs: Destroying record... Record destroyed
```

### Association Loading

Monitor association access patterns:

```crystal
# Belongs-to associations
post.user
# Logs: Loaded belongs_to association Post#user → User

# Has-many associations
user.posts.all
# Logs: Loaded has_many association User#posts → Post (10 records)
```

## Query Analysis

### N+1 Detection

Detect and prevent N+1 query problems:

```crystal
# Wrap code blocks to detect N+1 queries
analysis = Granite::QueryAnalysis::N1Detector.detect do
  # This code triggers N+1 queries
  User.all.each do |user|
    puts user.posts.count  # Each user triggers a new query
  end
end

if analysis.has_issues?
  puts analysis
  # Output:
  # Query Analysis:
  #   Total queries: 101
  #   ⚠️  Potential N+1 issues found:
  #     - Post: 100 similar queries (523.1ms total)
end
```

### Query Statistics

Collect performance statistics:

```crystal
# Enable statistics collection
stats = Granite::QueryAnalysis::QueryStats.instance
stats.enable!

# Run your application code...

# Generate report
stats.report
# Output:
# Query Statistics Summary
#   User#select: 50 queries, avg 5.2ms, total 260ms
#   User#insert: 10 queries, avg 3.1ms, total 31ms
```

## Configuration

### Log Levels

Configure different log levels for different components:

```crystal
Log.setup do |c|
  backend = Log::IOBackend.new
  
  # Detailed SQL logging (including all queries)
  c.bind "granite.sql", :debug, backend
  
  # Model operations (creates, updates, deletes)
  c.bind "granite.model", :info, backend
  
  # Association loading (can be verbose)
  c.bind "granite.association", :warn, backend
  
  # Transaction operations
  c.bind "granite.transaction", :info, backend
  
  # Query builder operations
  c.bind "granite.query", :debug, backend
end
```

### Custom Formatters

Create custom formatters for specific needs:

```crystal
class MyCustomFormatter < Log::StaticFormatter
  def format(entry : Log::Entry, io : IO)
    # Extract relevant data
    model = entry.data[:model]?
    duration = entry.data[:duration_ms]?
    
    # Format as JSON for structured logging
    io << {
      timestamp: entry.timestamp,
      level: entry.severity.to_s,
      model: model,
      duration: duration,
      message: entry.message
    }.to_json
  end
end

# Use custom formatter
Log.setup do |c|
  backend = Log::IOBackend.new(formatter: MyCustomFormatter.new)
  c.bind "granite.*", :debug, backend
end
```

## Performance Considerations

The instrumentation system is designed to have minimal overhead:

1. **Lazy Evaluation**: Log blocks use `&.emit` syntax for lazy evaluation
2. **Level Filtering**: Logs are filtered at the source based on configured levels
3. **No Allocation**: When logs are disabled, no allocations occur
4. **Compile-time Optimization**: Crystal optimizes away disabled log calls

### Production Configuration

For production, configure minimal logging:

```crystal
# config/environments/production.cr
Log.setup do |c|
  # Only log warnings and errors
  backend = Log::IOBackend.new(formatter: Log::ShortFormat)
  
  # Only slow queries and errors
  c.bind "granite.sql", :warn, backend
  c.bind "granite.model", :error, backend
  
  # Disable association and query builder logs
  c.bind "granite.association", :none, backend
  c.bind "granite.query", :none, backend
end
```

## Integration with Monitoring

The structured logging format makes it easy to integrate with monitoring tools:

```crystal
# Send to external monitoring service
class MonitoringBackend < Log::Backend
  def write(entry : Log::Entry)
    # Send to DataDog, New Relic, etc.
    if entry.source.starts_with?("granite.sql") && entry.severity.warn?
      Monitoring.track_slow_query(
        model: entry.data[:model],
        duration: entry.data[:duration_ms],
        sql: entry.data[:sql]
      )
    end
  end
end
```

## Examples

### Finding Slow Queries

```crystal
# Enable SQL logging with timing
Log.setup do |c|
  backend = Log::IOBackend.new
  c.bind "granite.sql", :debug, backend
end

# All queries will be logged with timing
users = User.where(active: true).limit(100)
# Logs: User (5.2ms) → 100 rows
#       SELECT * FROM users WHERE active = true LIMIT 100

# Slow queries trigger warnings
complex_report = User.complex_aggregation
# Logs: ⚠ User (523.1ms) → 1 rows
#       Slow query detected
```

### Debugging Association Loading

```crystal
# Enable association logging
Log.setup do |c|
  backend = Log::IOBackend.new
  c.bind "granite.association", :debug, backend
end

# Track association access
user = User.find(1)
posts = user.posts.all
# Logs: ↔ User#posts → Post (3.1ms) [10 records]

# Detect N+1 patterns
User.all.each do |user|
  user.posts.count  # Logs each association access
end
```

### Performance Profiling

```crystal
# Profile a specific operation
Granite::QueryAnalysis::N1Detector.detect do
  # Your application code
  render_user_dashboard(user)
end
# Automatically logs any N+1 issues found
```

## Best Practices

1. **Development**: Use full logging with pretty formatters
2. **Testing**: Enable N+1 detection in test suite
3. **Staging**: Use same configuration as production
4. **Production**: Log only warnings and errors
5. **Debugging**: Temporarily enable debug logging for specific components

## Troubleshooting

### No Logs Appearing

Check your log level configuration:

```crystal
# Ensure the source and level match
Log.builder.bind "granite.sql", :debug, backend
```

### Too Many Logs

Filter by source or increase log level:

```crystal
# Only log specific components
c.bind "granite.sql", :warn, backend  # Only slow queries
c.bind "granite.association", :none, backend  # Disable association logs
```

### Performance Impact

If you notice performance impact from logging:

1. Increase log levels (debug → info → warn)
2. Use sampling for high-frequency operations
3. Disable formatting in production
4. Use async log backends for I/O