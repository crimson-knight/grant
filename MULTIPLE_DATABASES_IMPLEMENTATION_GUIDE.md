# Grant Multiple Databases Implementation Guide

## Overview

This guide provides a step-by-step implementation plan for adding Rails-like multiple database support to Grant, focusing on practical implementation details and maintaining backward compatibility.

## Phase 1: Refactor Connection Infrastructure

### 1.1 Create New Connection Pool Implementation

```crystal
# src/granite/connection_pool.cr
module Granite
  class ConnectionPool(T)
    property max_pool_size : Int32
    property checkout_timeout : Time::Span
    property max_idle_pool_size : Int32
    
    @available = Deque(T).new
    @in_use = Set(T).new
    @mutex = Mutex.new
    @resource : Proc(T)
    @total_connections = 0
    
    def initialize(@max_pool_size = 5, 
                   @checkout_timeout = 5.seconds,
                   @max_idle_pool_size = 2,
                   &@resource : -> T)
    end
    
    def checkout : T
      @mutex.synchronize do
        loop do
          # Return existing connection if available
          if conn = @available.shift?
            @in_use << conn
            return conn
          end
          
          # Create new connection if under limit
          if @total_connections < @max_pool_size
            conn = @resource.call
            @total_connections += 1
            @in_use << conn
            return conn
          end
          
          # Wait for connection to be available
          wait_for_connection
        end
      end
    end
    
    def checkin(connection : T)
      @mutex.synchronize do
        @in_use.delete(connection)
        
        # Only keep up to max_idle connections
        if @available.size < @max_idle_pool_size
          @available << connection
        else
          close_connection(connection)
          @total_connections -= 1
        end
      end
    end
    
    def with_connection(&)
      conn = checkout
      yield conn
    ensure
      checkin(conn) if conn
    end
    
    private def wait_for_connection
      # Implementation depends on Crystal's concurrency primitives
      sleep 0.01 # Simple implementation
    end
    
    private def close_connection(conn : T)
      conn.close if conn.responds_to?(:close)
    end
  end
end
```

### 1.2 Enhanced Connection Specification

```crystal
# src/granite/connection_specification.cr
module Granite
  struct ConnectionSpecification
    getter adapter_class : Adapter::Base.class
    getter database : String
    getter url : String
    getter role : Symbol
    getter shard : Symbol?
    getter pool_config : PoolConfig
    
    struct PoolConfig
      property size : Int32 = 5
      property timeout : Time::Span = 5.seconds
      property idle_size : Int32 = 2
      
      def initialize(@size = 5, @timeout = 5.seconds, @idle_size = 2)
      end
    end
    
    def initialize(@adapter_class, @database, @url, @role, @shard = nil, @pool_config = PoolConfig.new)
    end
    
    def connection_key : String
      if shard
        "#{database}:#{role}:#{shard}"
      else
        "#{database}:#{role}"
      end
    end
    
    def create_adapter
      @adapter_class.new(name: connection_key, url: @url)
    end
  end
end
```

### 1.3 New Connection Handler

```crystal
# src/granite/connection_handler.cr
module Granite
  class ConnectionHandler
    @@specifications = {} of String => ConnectionSpecification
    @@connection_pools = {} of String => ConnectionPool(Adapter::Base)
    @@mutex = Mutex.new
    
    # Register a connection specification
    def self.establish_connection(
      database : String,
      adapter : Adapter::Base.class,
      url : String,
      role : Symbol = :primary,
      shard : Symbol? = nil,
      pool : ConnectionSpecification::PoolConfig = ConnectionSpecification::PoolConfig.new
    )
      spec = ConnectionSpecification.new(adapter, database, url, role, shard, pool)
      key = spec.connection_key
      
      @@mutex.synchronize do
        @@specifications[key] = spec
        # Don't create pool until first use (lazy loading)
      end
    end
    
    # Retrieve connection from pool
    def self.retrieve_connection(database : String, role : Symbol, shard : Symbol? = nil) : Adapter::Base
      key = ConnectionSpecification.new(
        Adapter::Base, database, "", role, shard
      ).connection_key
      
      pool = @@mutex.synchronize do
        @@connection_pools[key] ||= create_pool(key)
      end
      
      pool.checkout
    end
    
    # Execute with connection
    def self.with_connection(database : String, role : Symbol, shard : Symbol? = nil, &)
      key = ConnectionSpecification.new(
        Adapter::Base, database, "", role, shard
      ).connection_key
      
      pool = @@mutex.synchronize do
        @@connection_pools[key] ||= create_pool(key)
      end
      
      pool.with_connection do |conn|
        yield conn
      end
    end
    
    # Clear all connections (for testing)
    def self.clear_all_connections!
      @@mutex.synchronize do
        @@connection_pools.each_value(&.clear)
        @@connection_pools.clear
        @@specifications.clear
      end
    end
    
    private def self.create_pool(key : String) : ConnectionPool(Adapter::Base)
      spec = @@specifications[key]? || raise "No connection specification found for #{key}"
      
      ConnectionPool.new(
        max_pool_size: spec.pool_config.size,
        checkout_timeout: spec.pool_config.timeout,
        max_idle_pool_size: spec.pool_config.idle_size
      ) do
        spec.create_adapter
      end
    end
  end
end
```

## Phase 2: Implement connects_to DSL

### 2.1 Enhanced Base Class

```crystal
# src/granite/base.cr (additions)
abstract class Granite::Base
  # Connection configuration
  class_property database_name : String = "primary"
  class_property connection_roles : Hash(Symbol, String) = {} of Symbol => String
  class_property connection_shards : Hash(Symbol, Hash(Symbol, String)) = {} of Symbol => Hash(Symbol, String)
  class_property current_role : Symbol = :writing
  class_property current_shard : Symbol? = nil
  class_property connection_handler : ConnectionHandler.class = ConnectionHandler
  
  # Thread-local storage for connection context
  @[ThreadLocal]
  class_property connection_context : ConnectionContext?
  
  struct ConnectionContext
    property role : Symbol
    property shard : Symbol?
    property prevent_writes : Bool
    
    def initialize(@role, @shard = nil, @prevent_writes = false)
    end
  end
  
  # DSL for connection configuration
  macro connects_to(database = nil, shards = nil)
    {% if database %}
      {% if database.is_a?(NamedTuple) %}
        self.connection_roles = {
          {% for role, db in database %}
            {{role.id.symbolize}} => {{db.id.stringify}},
          {% end %}
        } of Symbol => String
      {% elsif database.is_a?(StringLiteral) || database.is_a?(SymbolLiteral) %}
        self.database_name = {{database.id.stringify}}
      {% end %}
    {% end %}
    
    {% if shards %}
      self.connection_shards = {
        {% for shard_name, shard_config in shards %}
          {{shard_name.id.symbolize}} => {
            {% for role, db in shard_config %}
              {{role.id.symbolize}} => {{db.id.stringify}},
            {% end %}
          } of Symbol => String,
        {% end %}
      } of Symbol => Hash(Symbol, String)
    {% end %}
  end
  
  # Connection switching
  def self.connected_to(database : String? = nil, role : Symbol? = nil, shard : Symbol? = nil, prevent_writes : Bool = false, &)
    # Save current context
    previous_context = connection_context
    previous_database = database_name if database
    
    # Set new context
    self.connection_context = ConnectionContext.new(
      role || current_role,
      shard || current_shard,
      prevent_writes
    )
    self.database_name = database if database
    
    yield
  ensure
    # Restore context
    self.connection_context = previous_context
    self.database_name = previous_database if database && previous_database
  end
  
  # Get current connection
  def self.connection : Adapter::Base
    context = connection_context || ConnectionContext.new(:writing)
    
    # Determine database name
    db_name = if shard = context.shard
      connection_shards[shard]?[context.role]? || database_name
    elsif role_db = connection_roles[context.role]?
      role_db
    else
      database_name
    end
    
    connection_handler.retrieve_connection(db_name, context.role, context.shard)
  end
  
  # Override adapter method for backward compatibility
  def self.adapter
    connection
  end
  
  # Prevent writes
  def self.while_preventing_writes(&)
    connected_to(prevent_writes: true) do
      yield
    end
  end
  
  # Check if writes are prevented
  def self.preventing_writes? : Bool
    connection_context?.try(&.prevent_writes) || false
  end
end
```

### 2.2 Query Execution Updates

```crystal
# src/granite/querying.cr (modifications)
module Granite::Querying
  macro included
    def self.first(**args)
      connected_to(role: :reading) do
        # Existing first implementation
        super(**args)
      end
    end
    
    def self.all(**args)
      connected_to(role: :reading) do
        # Existing all implementation
        super(**args)
      end
    end
    
    def self.find(id)
      connected_to(role: :reading) do
        # Existing find implementation
        super(id)
      end
    end
    
    # ... similar updates for other read methods
  end
end

# src/granite/transactions.cr (modifications)
module Granite::Transactions
  private def __create(**args)
    self.class.connected_to(role: :writing) do
      if self.class.preventing_writes?
        raise ReadOnlyError.new("Cannot create records while preventing writes")
      end
      # Existing create implementation
      super(**args)
    end
  end
  
  # ... similar updates for update and destroy
end
```

## Phase 3: Horizontal Sharding Implementation

### 3.1 Shard Resolution

```crystal
# src/granite/sharding/shard_resolver.cr
module Granite::Sharding
  abstract class ShardResolver
    abstract def resolve(key : Granite::Columns::Type) : Symbol
  end
  
  class ModuloShardResolver < ShardResolver
    getter shards : Array(Symbol)
    
    def initialize(@shards : Array(Symbol))
      raise ArgumentError.new("Must have at least one shard") if @shards.empty?
    end
    
    def resolve(key : Granite::Columns::Type) : Symbol
      numeric_key = case key
      when Int32, Int64
        key.to_i64
      when String
        key.hash.to_i64
      else
        key.to_s.hash.to_i64
      end
      
      index = numeric_key.abs % @shards.size
      @shards[index]
    end
  end
  
  class RangeShardResolver < ShardResolver
    getter ranges : Array({Range(Int64, Int64), Symbol})
    
    def initialize(@ranges : Array({Range(Int64, Int64), Symbol}))
    end
    
    def resolve(key : Granite::Columns::Type) : Symbol
      numeric_key = key.to_s.to_i64
      
      @ranges.each do |(range, shard)|
        return shard if range.includes?(numeric_key)
      end
      
      raise "No shard found for key #{key}"
    end
  end
  
  class CustomShardResolver < ShardResolver
    def initialize(&@resolver : Granite::Columns::Type -> Symbol)
    end
    
    def resolve(key : Granite::Columns::Type) : Symbol
      @resolver.call(key)
    end
  end
end
```

### 3.2 Sharded Model Support

```crystal
# src/granite/sharding/sharded_model.cr
module Granite::Sharding
  module ShardedModel
    macro included
      class_property shard_resolver : ShardResolver?
      class_property shard_key_column : Symbol = :id
      
      # Configure sharding
      macro shard_by(column, resolver = nil, shards = nil)
        self.shard_key_column = {{column.id.symbolize}}
        
        {% if resolver %}
          self.shard_resolver = {{resolver}}
        {% elsif shards %}
          self.shard_resolver = ModuloShardResolver.new({{shards}})
        {% else %}
          raise "Must provide either resolver or shards array"
        {% end %}
      end
      
      # Override find to route to correct shard
      def self.find(id)
        if resolver = shard_resolver
          shard = resolver.resolve(id)
          connected_to(shard: shard) do
            super(id)
          end
        else
          super(id)
        end
      end
      
      # Override save to ensure record goes to correct shard
      def save(**args)
        if resolver = self.class.shard_resolver
          key_value = @{{shard_key_column.id}}
          shard = resolver.resolve(key_value) if key_value
          
          self.class.connected_to(shard: shard) do
            super(**args)
          end
        else
          super(**args)
        end
      end
      
      # Helper to query specific shard
      def self.on_shard(shard : Symbol)
        connected_to(shard: shard) do
          yield
        end
      end
      
      # Query all shards
      def self.on_all_shards(&)
        return yield unless connection_shards.any?
        
        results = [] of self
        connection_shards.each_key do |shard|
          connected_to(shard: shard) do
            results.concat(yield)
          end
        end
        results
      end
    end
  end
end
```

## Phase 4: Migration Support

### 4.1 Database-Specific Migrations

```crystal
# src/granite/migrations/database_migration.cr
module Granite::Migrations
  abstract class DatabaseMigration < Migration
    class_property target_database : String = "primary"
    
    macro database(name)
      self.target_database = {{name.stringify}}
    end
    
    def up
      Granite::Base.connected_to(database: self.class.target_database, role: :writing) do
        execute_up
      end
    end
    
    def down
      Granite::Base.connected_to(database: self.class.target_database, role: :writing) do
        execute_down
      end
    end
    
    abstract def execute_up
    abstract def execute_down
  end
  
  # Migration generator updates
  class MigrationGenerator
    def self.generate(name : String, database : String = "primary")
      timestamp = Time.utc.to_s("%Y%m%d%H%M%S")
      filename = "#{timestamp}_#{name.underscore}.cr"
      filepath = "db/migrate/#{database}/#{filename}"
      
      Dir.mkdir_p("db/migrate/#{database}")
      
      File.write(filepath, <<-MIGRATION)
      class #{name.camelcase} < Granite::Migrations::DatabaseMigration
        database "#{database}"
        
        def execute_up
          # Add your migration code here
        end
        
        def execute_down
          # Add your rollback code here
        end
      end
      MIGRATION
    end
  end
end
```

### 4.2 Migration Runner Updates

```crystal
# src/granite/migrations/runner.cr
module Granite::Migrations
  class Runner
    def self.migrate(database : String? = nil, version : String? = nil)
      migrations = if database
        load_migrations_for_database(database)
      else
        load_all_migrations
      end
      
      migrations = filter_pending(migrations)
      migrations = filter_up_to_version(migrations, version) if version
      
      migrations.each do |migration|
        puts "Migrating #{migration.class.name} on #{migration.target_database}"
        migration.up
        record_migration(migration)
      end
    end
    
    def self.rollback(database : String? = nil, steps : Int32 = 1)
      migrations = if database
        executed_migrations_for_database(database)
      else
        all_executed_migrations
      end
      
      migrations.last(steps).reverse.each do |migration|
        puts "Rolling back #{migration.class.name} on #{migration.target_database}"
        migration.down
        remove_migration_record(migration)
      end
    end
    
    private def self.load_migrations_for_database(database : String)
      Dir.glob("db/migrate/#{database}/*.cr").map do |file|
        load_migration_file(file)
      end
    end
    
    private def self.load_all_migrations
      Dir.glob("db/migrate/**/*.cr").map do |file|
        load_migration_file(file)
      end
    end
  end
end
```

## Usage Examples

### Configuration

```crystal
# config/database.cr
require "granite"

# Configure primary database with read replica
Granite::ConnectionHandler.establish_connection(
  database: "primary",
  adapter: Granite::Adapter::Pg,
  url: ENV["DATABASE_URL"],
  role: :writing,
  pool: Granite::ConnectionSpecification::PoolConfig.new(size: 25)
)

Granite::ConnectionHandler.establish_connection(
  database: "primary_replica", 
  adapter: Granite::Adapter::Pg,
  url: ENV["DATABASE_REPLICA_URL"],
  role: :reading,
  pool: Granite::ConnectionSpecification::PoolConfig.new(size: 15)
)

# Configure analytics database
Granite::ConnectionHandler.establish_connection(
  database: "analytics",
  adapter: Granite::Adapter::Pg,
  url: ENV["ANALYTICS_DATABASE_URL"],
  role: :writing
)

# Configure sharded databases
["shard1", "shard2", "shard3"].each do |shard|
  Granite::ConnectionHandler.establish_connection(
    database: "orders_#{shard}",
    adapter: Granite::Adapter::Pg,
    url: ENV["ORDERS_#{shard.upcase}_URL"],
    role: :writing,
    shard: shard.to_sym
  )
end
```

### Model Definitions

```crystal
# Base classes for different databases
abstract class ApplicationRecord < Granite::Base
  connects_to database: {
    writing: "primary",
    reading: "primary_replica"
  }
end

abstract class AnalyticsRecord < Granite::Base
  connects_to database: "analytics"
end

# Regular models
class User < ApplicationRecord
  table users
  
  column id : Int64, primary: true
  column email : String
  column name : String
  
  has_many :orders
end

# Analytics models
class Event < AnalyticsRecord
  table events
  
  column id : Int64, primary: true
  column user_id : Int64
  column action : String
  column created_at : Time
end

# Sharded model
class Order < ApplicationRecord
  include Granite::Sharding::ShardedModel
  
  connects_to shards: {
    shard1: { writing: "orders_shard1", reading: "orders_shard1" },
    shard2: { writing: "orders_shard2", reading: "orders_shard2" },
    shard3: { writing: "orders_shard3", reading: "orders_shard3" }
  }
  
  shard_by :user_id, shards: [:shard1, :shard2, :shard3]
  
  table orders
  
  column id : Int64, primary: true
  column user_id : Int64
  column total : Float64
  column status : String
  
  belongs_to :user
end
```

### Usage Patterns

```crystal
# Automatic read/write splitting
users = User.all                    # Uses reading connection
user = User.create(name: "John")    # Uses writing connection

# Manual connection control
User.connected_to(role: :writing) do
  # Force writing connection for read
  user = User.find(1)
  user.update(name: "Jane")
end

# Cross-database operations
ApplicationRecord.connected_to(role: :reading) do
  users = User.all
  
  AnalyticsRecord.connected_to(role: :writing) do
    users.each do |user|
      Event.create(user_id: user.id, action: "login")
    end
  end
end

# Sharded operations
order = Order.find(12345)  # Automatically routes to correct shard

# Query specific shard
Order.on_shard(:shard1) do
  Order.where(status: "pending").select
end

# Query all shards
all_pending = Order.on_all_shards do
  Order.where(status: "pending").select
end

# Prevent writes (useful for maintenance)
Granite::Base.while_preventing_writes do
  user = User.find(1)
  user.name = "New Name"
  user.save  # Raises ReadOnlyError
end
```

## Backward Compatibility

The implementation maintains backward compatibility by:

1. **Default Behavior**: Models without `connects_to` use the first registered connection
2. **Legacy Methods**: `adapter` method continues to work
3. **Connection Macro**: Existing `connection` macro maps to new system
4. **Gradual Migration**: Can migrate models incrementally

```crystal
# Legacy code continues to work
class LegacyModel < Granite::Base
  connection "postgres"  # Maps to new system
  table legacy_models
end

# New code uses enhanced features
class NewModel < Granite::Base
  connects_to database: { writing: :primary, reading: :replica }
  table new_models
end
```

## Testing Considerations

```crystal
# spec_helper.cr
Spec.before_each do
  # Use single connection for tests
  Granite::ConnectionHandler.clear_all_connections!
  Granite::ConnectionHandler.establish_connection(
    database: "test",
    adapter: Granite::Adapter::Sqlite,
    url: "sqlite3::memory:",
    role: :writing
  )
  Granite::ConnectionHandler.establish_connection(
    database: "test",
    adapter: Granite::Adapter::Sqlite, 
    url: "sqlite3::memory:",
    role: :reading
  )
end

# Test specific behaviors
describe "Multiple Database Support" do
  it "routes reads to replica" do
    User.connected_to(role: :reading) do
      # Verify connection is reading replica
      User.connection.should eq(reading_connection)
    end
  end
  
  it "prevents writes when configured" do
    User.while_preventing_writes do
      expect_raises(Granite::ReadOnlyError) do
        User.create(name: "Test")
      end
    end
  end
end
```

This implementation provides a clean, performant, and flexible multiple database solution for Grant while maintaining the simplicity Crystal developers expect.