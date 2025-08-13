# Grant Implementation Roadmap for Active Record Parity

## Overview

This roadmap integrates all analyses into a cohesive implementation plan, incorporating multiple databases, sharding, sanitization, and async convenience methods.

## Phase 1: Foundation & Infrastructure (3 months)

### 1.1 Connection Management (Month 1)
Using crystal-db as the foundation:

```crystal
# Week 1-2: Connection Pool Wrapper
module Grant
  class ConnectionPool
    @db : DB::Database
    @name : String
    @role : Symbol
    
    def initialize(@name, url : String, @role = :primary, pool_size = 25)
      @db = DB.open(url, 
        max_pool_size: pool_size,
        initial_pool_size: 2,
        max_idle_pool_size: 5,
        checkout_timeout: 5.seconds
      )
    end
  end
end

# Week 3-4: Connection Registry
module Grant
  class ConnectionRegistry
    @@pools = {} of String => ConnectionPool
    @@configurations = {} of String => NamedTuple(
      writing: String,
      reading: String?,
      pool_size: Int32
    )
    
    def self.establish_connection(name : String, config)
      @@configurations[name] = config
      
      # Create writer pool
      writer_key = "#{name}:writing"
      @@pools[writer_key] = ConnectionPool.new(
        writer_key,
        config[:writing],
        :writing,
        config[:pool_size]
      )
      
      # Create reader pool if specified
      if reader_url = config[:reading]
        reader_key = "#{name}:reading"
        @@pools[reader_key] = ConnectionPool.new(
          reader_key,
          reader_url,
          :reading,
          config[:pool_size]
        )
      end
    end
  end
end
```

### 1.2 Multiple Database Support (Month 1-2)

```crystal
# Week 5-6: connects_to DSL
abstract class Grant::Base
  macro connects_to(database = nil, shards = nil)
    {% if database %}
      class_property database_config = {
        {% for role, db_name in database %}
          {{role.id}}: {{db_name.stringify}},
        {% end %}
      }
    {% end %}
    
    {% if shards %}
      class_property shard_config = {
        {% for shard, config in shards %}
          {{shard.id}}: {
            {% for role, db_name in config %}
              {{role.id}}: {{db_name.stringify}},
            {% end %}
          },
        {% end %}
      }
    {% end %}
  end
  
  # Week 7-8: Connection switching
  def self.connected_to(role : Symbol? = nil, shard : Symbol? = nil, &)
    previous_context = current_connection_context
    
    self.current_connection_context = ConnectionContext.new(
      role: role || current_role,
      shard: shard || current_shard,
      database: database_name
    )
    
    yield
  ensure
    self.current_connection_context = previous_context
  end
end
```

### 1.3 Sharding Infrastructure (Month 2)

```crystal
# Week 9-10: Shard Resolution
module Grant::Sharding
  abstract class ShardResolver
    abstract def resolve(key : DB::Any) : Symbol
  end
  
  class ModuloResolver < ShardResolver
    def initialize(@shards : Array(Symbol))
    end
    
    def resolve(key : DB::Any) : Symbol
      index = key.hash.abs % @shards.size
      @shards[index]
    end
  end
  
  class RangeResolver < ShardResolver
    def initialize(@ranges : Hash(Range(Int64, Int64), Symbol))
    end
    
    def resolve(key : DB::Any) : Symbol
      numeric_key = key.to_s.to_i64
      @ranges.each do |range, shard|
        return shard if range.includes?(numeric_key)
      end
      raise "No shard for key: #{key}"
    end
  end
end

# Week 11-12: Sharded Model Support
module Grant::Sharding::ShardedModel
  macro included
    class_property shard_resolver : ShardResolver?
    class_property shard_key : Symbol = :id
    
    # Override queries to route to correct shard
    def self.find(id)
      if resolver = shard_resolver
        shard = resolver.resolve(id)
        connected_to(shard: shard) { super }
      else
        super
      end
    end
  end
end
```

### 1.4 Transactions (Month 2-3)

```crystal
# Week 13-14: Basic Transactions
module Grant::Transactions
  def self.transaction(isolation : Symbol? = nil, &)
    connection = current_connection
    
    isolation_sql = case isolation
    when :read_uncommitted then "READ UNCOMMITTED"
    when :read_committed then "READ COMMITTED"
    when :repeatable_read then "REPEATABLE READ"
    when :serializable then "SERIALIZABLE"
    else nil
    end
    
    connection.transaction do |tx|
      tx.connection.exec("SET TRANSACTION ISOLATION LEVEL #{isolation_sql}") if isolation_sql
      yield tx
    end
  end
end

# Week 15-16: Distributed Transactions (for sharding)
module Grant::DistributedTransaction
  def self.transaction(&)
    transactions = {} of Symbol => DB::Transaction
    
    begin
      # Start transaction on each shard
      shard_config.each do |shard, config|
        conn = connection_for_shard(shard)
        transactions[shard] = conn.begin_transaction
      end
      
      yield
      
      # Commit all
      transactions.each_value(&.commit)
    rescue ex
      # Rollback all on error
      transactions.each_value(&.rollback rescue nil)
      raise ex
    end
  end
end
```

## Phase 2: Security & Query Features (2 months)

### 2.1 Sanitization (Month 3-4)

```crystal
# Week 17-18: SQL Sanitization
module Grant::Sanitization
  extend self
  
  def quote(value : Nil) : String
    "NULL"
  end
  
  def quote(value : String) : String
    "'#{value.gsub("'", "''")}'"
  end
  
  def quote(value : Number) : String
    value.to_s
  end
  
  def quote(value : Bool) : String
    value ? "TRUE" : "FALSE"
  end
  
  def quote(value : Time) : String
    "'#{value.to_s("%Y-%m-%d %H:%M:%S")}'"
  end
  
  def quote_identifier(name : String) : String
    # Database-specific implementation
    case adapter_type
    when .postgres? then %("#{name.gsub('"', '""')}")
    when .mysql? then "`#{name.gsub('`', '``')}`"
    when .sqlite? then %("#{name.gsub('"', '""')}")
    end
  end
  
  def sanitize_sql_array(ary : Array) : String
    sql = ary[0].as(String)
    values = ary[1..-1]
    
    # Replace ? placeholders
    values.each do |value|
      sql = sql.sub("?", quote(value))
    end
    
    sql
  end
  
  # For hash conditions
  def sanitize_sql_hash(hash : Hash) : String
    conditions = hash.map do |key, value|
      "#{quote_identifier(key.to_s)} = #{quote(value)}"
    end
    
    conditions.join(" AND ")
  end
end

# Week 19-20: Raw Query Interface
class Grant::RawQuery
  def self.select_all(sql : String, *args)
    query = prepare_query(sql, args.to_a)
    
    Base.connection.query_all(query.sql, args: query.args) do |rs|
      yield rs
    end
  end
  
  def self.execute(sql : String, *args)
    query = prepare_query(sql, args.to_a)
    Base.connection.exec(query.sql, args: query.args)
  end
  
  private def self.prepare_query(sql : String, args : Array)
    if sql.includes?("?")
      # Parameterized query
      {sql: sql, args: args}
    else
      # Need to sanitize
      {sql: Sanitization.sanitize_sql_array([sql] + args), args: [] of DB::Any}
    end
  end
end
```

### 2.2 Async Methods (Month 4)

```crystal
# Week 21-22: Async Calculations
module Grant::AsyncMethods
  macro define_async_method(name, return_type)
    def self.async_{{name.id}}(*args, **options) : Channel({{return_type}})
      channel = Channel({{return_type}}).new
      
      spawn do
        result = {{name.id}}(*args, **options)
        channel.send(result)
      rescue ex
        channel.close
        raise ex
      end
      
      channel
    end
  end
  
  define_async_method count, Int64
  define_async_method sum, Float64
  define_async_method average, Float64
  define_async_method minimum, DB::Any
  define_async_method maximum, DB::Any
  define_async_method pluck, Array(DB::Any)
  define_async_method pick, Array(DB::Any)?
end

# Week 23-24: Multi-DB Async Queries
module Grant::AsyncMethods
  def self.gather(**queries)
    channels = {} of Symbol => Channel(DB::Any)
    
    queries.each do |name, block|
      channels[name] = Channel(DB::Any).new
      
      spawn do
        result = block.call
        channels[name].send(result)
      rescue ex
        channels[name].close
        raise ex
      end
    end
    
    # Return a waitable result
    AsyncResult.new(channels)
  end
  
  class AsyncResult
    def initialize(@channels : Hash(Symbol, Channel(DB::Any)))
    end
    
    def wait : Hash(Symbol, DB::Any)
      results = {} of Symbol => DB::Any
      
      @channels.each do |name, channel|
        results[name] = channel.receive
      end
      
      results
    end
  end
end

# Usage
results = Grant::AsyncMethods.gather(
  users: -> { User.count },
  posts: -> { Post.where(published: true).count },
  analytics: -> {
    Analytics.connected_to(database: "analytics") do
      PageView.where("created_at > ?", 1.day.ago).count
    end
  }
).wait
```

### 2.3 Locking (Month 4)

```crystal
# Week 23-24: Locking Implementation
module Grant::Locking
  module Optimistic
    macro included
      column lock_version : Int32 = 0
      
      before_save :check_stale_object
      after_save :increment_lock_version
      
      def check_stale_object
        return if new_record?
        return unless lock_version_changed?
        
        current = self.class.where(id: id, lock_version: lock_version_was).exists?
        unless current
          raise StaleObjectError.new(self.class.name, id)
        end
      end
      
      def increment_lock_version
        @lock_version = lock_version + 1
      end
    end
  end
  
  module Pessimistic
    def with_lock(lock_type = "FOR UPDATE", &)
      self.class.transaction do
        reload(lock: lock_type)
        yield self
      end
    end
    
    def lock!(lock_type = "FOR UPDATE")
      reload(lock: lock_type)
    end
  end
end
```

## Phase 3: Advanced Features (2 months)

### 3.1 Encryption (Month 5)
- Attribute encryption with configurable ciphers
- Key rotation support
- Deterministic encryption for searchable fields

### 3.2 Nested Attributes (Month 5)
- accepts_nested_attributes_for macro
- Validation propagation
- Transaction wrapping

### 3.3 Advanced Query Methods (Month 6)
- OR queries
- UNION support
- Subqueries
- Query merging

### 3.4 Query Cache (Month 6)
- Request-level caching
- Cache key generation
- Invalidation strategies

## Timeline Summary

```
Month 1: Connection Management & Multi-DB basics
Month 2: Sharding & Transaction infrastructure  
Month 3: Sanitization & Security features
Month 4: Async methods & Locking
Month 5: Encryption & Nested Attributes
Month 6: Advanced Queries & Caching
```

## Success Metrics

1. **All critical features implemented** (transactions, locking, sanitization)
2. **Multi-database queries work seamlessly** with role switching
3. **Sharding is transparent** to application code
4. **Async methods provide 2-3x speedup** for parallel queries
5. **Zero security vulnerabilities** in raw SQL handling
6. **Performance on par or better** than Active Record

## Next Steps

1. Review and approve this roadmap
2. Set up development environment with multiple databases
3. Create comprehensive test suite structure
4. Begin Phase 1 implementation
5. Weekly progress reviews

This roadmap provides a clear path to Active Record feature parity while leveraging Crystal's strengths and the crystal-db ecosystem.