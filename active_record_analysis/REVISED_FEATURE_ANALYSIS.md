# Revised Active Record Feature Analysis for Grant

## Important Corrections

### 1. Sanitization IS Needed ✅

You're absolutely right - when executing raw SQL, we need sanitization:

```crystal
# Unsafe - SQL injection risk
User.raw_query("SELECT * FROM users WHERE name = '#{params[:name]}'")

# Safe - need sanitization methods
User.raw_query("SELECT * FROM users WHERE name = ?", [params[:name]])

# Grant should provide
module Grant::Sanitization
  def self.quote(value : String) : String
    # Escape single quotes and other SQL special characters
    "'#{value.gsub("'", "''")}'"
  end
  
  def self.quote_column_name(name : String) : String
    # Quote identifiers
    %("#{name.gsub('"', '""')}")
  end
  
  def self.sanitize_sql_array(ary : Array) : String
    # Replace ? placeholders with quoted values
  end
  
  def self.sanitize_sql_for_conditions(condition) : String
    # Handle various condition formats
  end
end

# For raw queries
class Grant::RawQuery(T)
  def initialize(@sql : String, @params : Array(DB::Any) = [] of DB::Any)
  end
  
  def execute
    # Use crystal-db's parameterized queries
    T.adapter.open do |db|
      db.query(@sql, args: @params)
    end
  end
end
```

### 2. Async Convenience Methods ✅

Convenience wrappers for concurrent operations:

```crystal
module Grant::AsyncMethods
  # Async calculation methods
  def self.async_count(model : T.class, conditions = {} of String => DB::Any) : Channel(Int64) forall T
    channel = Channel(Int64).new
    
    spawn do
      count = model.where(conditions).count
      channel.send(count)
    rescue ex
      channel.close
      raise ex
    end
    
    channel
  end
  
  def self.async_sum(model : T.class, column : Symbol, conditions = {} of String => DB::Any) : Channel(Float64) forall T
    channel = Channel(Float64).new
    
    spawn do
      sum = model.where(conditions).sum(column)
      channel.send(sum)
    rescue ex
      channel.close
      raise ex
    end
    
    channel
  end
  
  # Multi-database concurrent queries
  def self.async_multi_db(&) : Channel(Array(DB::ResultSet))
    channel = Channel(Array(DB::ResultSet)).new
    wait_group = WaitGroup.new
    results = [] of DB::ResultSet
    mutex = Mutex.new
    
    yield wait_group, results, mutex
    
    spawn do
      wait_group.wait
      channel.send(results)
    end
    
    channel
  end
end

# Usage examples
# Simple async
count_channel = User.async_count
posts_channel = Post.async_count(published: true)

# Do other work...
total_users = count_channel.receive
published_posts = posts_channel.receive

# Multi-database queries
results = Grant::AsyncMethods.async_multi_db do |wg, results, mutex|
  wg.add
  spawn do
    User.connected_to(database: "primary") do
      data = User.all
      mutex.synchronize { results << data }
    end
    wg.done
  end
  
  wg.add
  spawn do
    Analytics.connected_to(database: "analytics") do
      data = PageView.where("created_at > ?", 1.day.ago).select
      mutex.synchronize { results << data }
    end
    wg.done
  end
end.receive
```

### 3. Multiple Databases & Sharding Integration ✅

Integrating the previous analysis into the main plan:

```crystal
# Enhanced connection management from previous analysis
module Grant
  class ConnectionHandler
    @@pools = {} of String => DB::Database
    
    def self.register(name : String, url : String, pool_size : Int32 = 25)
      @@pools[name] = DB.open(url, max_pool_size: pool_size)
    end
    
    def self.with_connection(name : String, &)
      pool = @@pools[name]? || raise "Unknown database: #{name}"
      pool.using_connection do |conn|
        yield conn
      end
    end
  end
end

# Model configuration
abstract class ApplicationRecord < Grant::Base
  connects_to database: {
    writing: :primary,
    reading: :primary_replica
  }
end

# Sharded model
class Order < ApplicationRecord
  include Grant::Sharding::ShardedModel
  
  connects_to shards: {
    shard_one: { writing: :shard1_primary, reading: :shard1_replica },
    shard_two: { writing: :shard2_primary, reading: :shard2_replica }
  }
  
  shard_by :customer_id, shards: [:shard_one, :shard_two]
end

# Automatic role switching
module Grant::Middleware
  class DatabaseSelector
    def call(context : HTTP::Server::Context)
      if read_request?(context)
        Grant::Base.connected_to(role: :reading) do
          call_next(context)
        end
      else
        Grant::Base.connected_to(role: :writing) do
          call_next(context)
        end
      end
    end
  end
end
```

## Updated Feature Priority List

### Phase 1: Critical Infrastructure (2-3 months)

#### 1.1 Connection Management ✨
- **Connection pooling** using crystal-db
- **Multiple database support** with role-based connections
- **Automatic read/write splitting**
- **Connection health checks**

#### 1.2 Transactions
- **Explicit transaction blocks**
- **Nested transactions with savepoints**
- **Transaction isolation levels**
- **Distributed transactions** (for sharding)

#### 1.3 Sharding Support
- **Shard resolution strategies**
- **Cross-shard queries**
- **Shard-aware migrations**
- **Connection routing**

#### 1.4 Locking
- **Optimistic locking**
- **Pessimistic locking**
- **Advisory locks**

### Phase 2: Security & Data Integrity (1-2 months)

#### 2.1 Sanitization
- **SQL injection prevention for raw queries**
- **Identifier quoting**
- **Safe interpolation methods**
- **Query builder sanitization**

#### 2.2 Encryption
- **Transparent attribute encryption**
- **Key rotation support**
- **Deterministic vs random encryption**

#### 2.3 Security Tokens
- **Secure random tokens**
- **Signed IDs**
- **Temporary tokens with expiry**

### Phase 3: Developer Experience (2-3 months)

#### 3.1 Async Methods
- **async_count, async_sum, async_average**
- **async_pluck, async_pick**
- **Concurrent multi-database queries**
- **WaitGroup integration**

#### 3.2 Advanced Queries
- **OR queries**
- **UNION support**
- **Subqueries**
- **CTEs (Common Table Expressions)**

#### 3.3 Nested Attributes
- **accepts_nested_attributes_for**
- **Validation of nested data**
- **Transaction wrapping**

### Phase 4: Performance & Polish (1-2 months)

#### 4.1 Query Optimization
- **Query caching**
- **Prepared statement caching**
- **EXPLAIN integration**
- **Query analysis**

#### 4.2 Batch Operations
- **Efficient bulk inserts**
- **Parallel batch processing**
- **Cursor-based iteration**

## Removed from Plan ❌

Per your request, removing these metaprogramming-heavy features:
- DelegatedType
- Runtime reflection APIs
- Dynamic method definition
- Method missing handlers
- Runtime type discovery

## Implementation Example: Raw Query with Sanitization

```crystal
module Grant
  class RawQuery
    def self.execute(sql : String, *args) : DB::ResultSet
      sanitized_sql = Sanitization.sanitize_sql_array([sql] + args.to_a)
      
      Base.adapter.open do |db|
        db.query(sanitized_sql)
      end
    end
    
    def self.execute_command(sql : String, *args) : DB::ExecResult
      sanitized_sql = Sanitization.sanitize_sql_array([sql] + args.to_a)
      
      Base.adapter.open do |db|
        db.exec(sanitized_sql)
      end
    end
  end
end

# Safe usage
users = Grant::RawQuery.execute(
  "SELECT * FROM users WHERE age > ? AND role = ?",
  21,
  "admin"
)

# With model
class User < Grant::Base
  def self.adults_in_region(region : String)
    RawQuery.execute(
      "SELECT * FROM users WHERE age >= 18 AND region = ?",
      region
    ).map { |rs| User.from_rs(rs) }
  end
end
```

## Crystal-DB Integration

Leveraging crystal-db's features:

```crystal
module Grant
  class ConnectionPool
    @pool : DB::Database
    
    def initialize(url : String, pool_size : Int32 = 25)
      @pool = DB.open(url, 
        max_pool_size: pool_size,
        max_idle_pool_size: 5,
        checkout_timeout: 5.seconds
      )
    end
    
    def with_connection(&)
      @pool.using_connection do |conn|
        yield conn
      end
    end
    
    def stats
      {
        pool_size: @pool.pool_size,
        idle_connections: @pool.idle_connections,
        in_use_connections: @pool.in_use_connections
      }
    end
  end
end
```

## Summary

The revised plan:
1. **Includes sanitization** for raw SQL execution
2. **Adds async_ convenience methods** for better developer experience
3. **Removes metaprogramming features** that don't fit Crystal
4. **Integrates multiple database/sharding** as a core feature
5. **Leverages crystal-db** for connection pooling

This provides a more realistic and Crystal-idiomatic path to Active Record feature parity while maintaining security and performance.