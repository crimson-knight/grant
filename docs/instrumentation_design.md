# Granite Instrumentation Design

## Overview

This document outlines a Crystal-native approach to instrumenting Granite ORM operations using Crystal's built-in logging capabilities rather than attempting to replicate Rails' ActiveSupport::Notifications.

## Design Philosophy

Instead of creating a pub-sub notification system, we leverage Crystal's `Log` module which provides:
- Structured logging with context
- Multiple backends (file, stdout, syslog, etc.)
- Log levels and filtering
- High performance with minimal overhead
- Native Crystal patterns

## Implementation Approach

### 1. Create Granite-Specific Log Source

```crystal
module Granite
  Log = ::Log.for("granite")
  
  # Sub-loggers for different components
  module Logs
    SQL = ::Log.for("granite.sql")
    Model = ::Log.for("granite.model")
    Transaction = ::Log.for("granite.transaction")
    Association = ::Log.for("granite.association")
  end
end
```

### 2. Instrument Operations with Structured Logging

```crystal
# In query executor
def run
  start_time = Time.monotonic
  
  begin
    result = adapter.open do |db|
      db.query(raw_sql, args: params)
    end
    
    duration = Time.monotonic - start_time
    
    Granite::Logs::SQL.debug &.emit("Query executed",
      sql: raw_sql,
      model: Model.name,
      duration_ms: duration.total_milliseconds,
      row_count: result.size,
      cached: false
    )
    
    result
  rescue e
    duration = Time.monotonic - start_time
    
    Granite::Logs::SQL.error &.emit("Query failed",
      sql: raw_sql,
      model: Model.name,
      duration_ms: duration.total_milliseconds,
      error: e.message
    )
    
    raise e
  end
end
```

### 3. Model Operations Logging

```crystal
# In model save method
def save
  operation = new_record? ? "create" : "update"
  
  Granite::Logs::Model.debug &.emit("Model #{operation}",
    model: self.class.name,
    id: id,
    operation: operation,
    attributes: attributes_hash
  )
  
  # Actual save logic...
end
```

### 4. User Configuration

Users can configure logging behavior using Crystal's standard Log configuration:

```crystal
# In application startup
Log.setup do |c|
  # Console backend for development
  backend = Log::IOBackend.new(formatter: Log::ShortFormat)
  
  # Only show SQL queries in development
  c.bind "granite.sql", :debug, backend
  
  # Show warnings and above for models
  c.bind "granite.model", :warn, backend
  
  # Silence transaction logs
  c.bind "granite.transaction", :none, backend
end

# Or use JSON formatting for production
Log.setup do |c|
  backend = Log::IOBackend.new(formatter: Log::JSONFormatter.new)
  c.bind "granite.*", :info, backend
end
```

### 5. Custom Backends for Instrumentation

Instrumentation libraries can provide custom log backends:

```crystal
class DataDogBackend < Log::Backend
  def write(entry : Log::Entry)
    if entry.source == "granite.sql"
      # Send metrics to DataDog
      StatsD.timing("database.query.duration", entry.data[:duration_ms])
      StatsD.increment("database.query.count")
    end
  end
end

# Users can add this backend
Log.setup do |c|
  c.bind "granite.*", :debug, DataDogBackend.new
end
```

### 6. Development Helpers

```crystal
module Granite
  module Development
    # Pretty print SQL queries in development
    def self.setup_query_logging
      Log.setup do |c|
        backend = Log::IOBackend.new
        backend.formatter = SQLFormatter.new
        c.bind "granite.sql", :debug, backend
      end
    end
    
    class SQLFormatter < Log::StaticFormatter
      def format(entry : Log::Entry, io : IO)
        io << "  #{entry.data[:model]} Load (#{entry.data[:duration_ms].round(2)}ms)\n"
        io << "  #{entry.data[:sql]}\n"
      end
    end
  end
end
```

## Benefits of This Approach

1. **Native Crystal** - Uses standard Crystal patterns and libraries
2. **Performance** - Log blocks are lazy-evaluated, zero cost when disabled
3. **Flexible** - Users can use any Log backend (file, syslog, custom)
4. **Familiar** - Crystal developers already know how to use Log
5. **Composable** - Easy to integrate with existing logging infrastructure
6. **Type Safe** - Structured data with compile-time checks

## Implementation Phases

### Phase 1: Core Infrastructure
- Set up Granite::Log and sub-loggers
- Add basic SQL query logging
- Document configuration examples

### Phase 2: Comprehensive Coverage
- Add logging to all database operations
- Include model lifecycle events
- Add association loading logs
- Transaction logging

### Phase 3: Developer Experience
- Development mode formatters
- Query analysis helpers
- Performance warnings (N+1, slow queries)

### Phase 4: Integration Examples
- APM backend examples (DataDog, New Relic)
- Metrics collection patterns
- Production configuration guides

## Migration from ActiveSupport::Notifications

For Rails developers, we can provide a migration guide showing the equivalent patterns:

| Rails Pattern | Granite Pattern |
|--------------|-----------------|
| `ActiveSupport::Notifications.instrument` | `Granite::Log.debug &.emit` |
| `ActiveSupport::Notifications.subscribe` | Custom Log::Backend |
| Event payloads | Structured log data |
| Event names | Log sources (granite.sql, etc.) |

## Example Usage

```crystal
# Development setup
Granite::Development.setup_query_logging if Amber.env.development?

# Production with metrics
if Amber.env.production?
  Log.setup do |c|
    # JSON logs to stdout
    json_backend = Log::IOBackend.new(formatter: Log::JSONFormatter.new)
    c.bind "granite.*", :info, json_backend
    
    # Metrics to monitoring service
    c.bind "granite.sql", :debug, MetricsBackend.new
  end
end

# Debugging specific issues
Log.setup do |c|
  # Temporarily enable association logging
  c.bind "granite.association", :debug, Log::IOBackend.new
end
```

This approach provides all the benefits of ActiveSupport::Notifications while being more idiomatic to Crystal and easier to integrate with existing Crystal applications.