# Grant Multiple Databases & Sharding Research

## Executive Summary

This document outlines a comprehensive plan to implement Rails-like multiple database support in Grant, including vertical scaling (read/write splitting), horizontal sharding, and improved connection management.

## Current State Analysis

### Grant's Current Implementation

Grant currently has basic multiple database support with these features:

1. **Connection Registry**: `Grant::Connections` stores database connections
2. **Read/Write Splitting**: Basic support for reader/writer separation
3. **Connection Switching**: Time-based switching after writes (default 2000ms)
4. **Per-Model Connection**: Models specify connection via `connection` macro

### Limitations of Current Approach

1. **No Horizontal Sharding**: Cannot split data across multiple databases
2. **Limited Connection Control**: No block-based connection switching
3. **No Role-Based Connections**: Only reader/writer roles supported
4. **Global Switch Timer**: All models share same connection switch delay
5. **No Migration Support**: Migrations don't target specific databases
6. **Manual Configuration**: Requires explicit connection registration

## Rails Multiple Database Architecture

### Key Concepts from Rails

1. **Three-Tier Configuration**:
   - Database specification (adapter, host, etc.)
   - Role specification (writing, reading, custom roles)
   - Shard specification (for horizontal scaling)

2. **Abstract Base Classes**:
   - Models inherit from abstract classes that define connections
   - Allows grouping models by database

3. **Connection Switching**:
   - Automatic based on HTTP verb and recent writes
   - Manual via `connected_to` blocks
   - Supports both role and shard switching

4. **Horizontal Sharding**:
   - Split data across multiple database servers
   - Shard key determines which database to use
   - Manual and automatic shard switching

5. **Migration Management**:
   - Separate migration directories per database
   - Generators support database targeting
   - Database-specific schema files

## Proposed Architecture for Grant

### 1. Enhanced Connection Registry

```crystal
module Grant
  class DatabaseConfig
    property name : String
    property adapter_type : Adapter::Base.class
    property pool_size : Int32 = 5
    property timeout : Time::Span = 5.seconds
    
    def initialize(@name, @adapter_type, @pool_size = 5, @timeout = 5.seconds)
    end
  end
  
  class ConnectionSpecification
    property config : DatabaseConfig
    property url : String
    property role : Symbol
    property shard : Symbol?
    
    def initialize(@config, @url, @role = :primary, @shard = nil)
    end
  end
  
  class ConnectionRegistry
    @@specifications = {} of String => Hash(Symbol, ConnectionSpecification)
    @@pools = {} of String => ConnectionPool
    
    # Register a database configuration
    def self.register_database(name : String, config : DatabaseConfig)
      @@specifications[name] = {} of Symbol => ConnectionSpecification
    end
    
    # Add a connection specification
    def self.add_connection(database : String, role : Symbol, url : String, shard : Symbol? = nil)
      spec = ConnectionSpecification.new(
        @@specifications[database][:config],
        url,
        role,
        shard
      )
      @@specifications[database][role] = spec
    end
    
    # Get connection pool for specification
    def self.pool_for(database : String, role : Symbol, shard : Symbol? = nil) : ConnectionPool
      key = "#{database}:#{role}:#{shard}"
      @@pools[key] ||= create_pool(@@specifications[database][role])
    end
  end
end
```

### 2. Enhanced Base Class with connects_to

```crystal
module Grant
  abstract class Base
    # Class-level connection configuration
    class_property current_role : Symbol = :writing
    class_property current_shard : Symbol? = nil
    
    # Define database connections
    macro connects_to(database : NamedTuple? = nil, shards : NamedTuple? = nil)
      {% if database %}
        {% for role, db_name in database %}
          class_property {{role.id}}_connection : String = {{db_name.stringify}}
        {% end %}
        
        def self.connection_for_role(role : Symbol) : String
          case role
          {% for role, db_name in database %}
          when {{role.symbolize}}
            {{role.id}}_connection
          {% end %}
          else
            raise "Unknown role: #{role}"
          end
        end
      {% end %}
      
      {% if shards %}
        class_property shard_specifications = {
          {% for shard_name, shard_config in shards %}
            {{shard_name.symbolize}} => {
              {% for role, db_name in shard_config %}
                {{role.symbolize}} => {{db_name.stringify}},
              {% end %}
            },
          {% end %}
        }
        
        def self.connection_for_shard(shard : Symbol, role : Symbol) : String
          shard_specifications[shard][role]
        end
      {% end %}
    end
    
    # Switch connections for a block
    def self.connected_to(role : Symbol? = nil, shard : Symbol? = nil, &)
      previous_role = current_role
      previous_shard = current_shard
      
      self.current_role = role if role
      self.current_shard = shard if shard
      
      yield
    ensure
      self.current_role = previous_role
      self.current_shard = previous_shard
    end
    
    # Get current adapter based on role and shard
    def self.adapter
      if shard = current_shard
        connection_name = connection_for_shard(shard, current_role)
      else
        connection_name = connection_for_role(current_role)
      end
      
      ConnectionRegistry.pool_for(connection_name, current_role, current_shard)
    end
  end
end
```

### 3. Connection Switching Strategy

```crystal
module Grant
  # Abstract resolver for connection switching
  abstract class ConnectionResolver
    abstract def reading_request?(operation : Symbol) : Bool
    abstract def can_read_from_replica?(last_write_time : Time) : Bool
  end
  
  class DefaultResolver < ConnectionResolver
    property delay : Time::Span
    
    def initialize(@delay : Time::Span = 2.seconds)
    end
    
    def reading_request?(operation : Symbol) : Bool
      [:select, :find, :first, :last, :exists?, :count].includes?(operation)
    end
    
    def can_read_from_replica?(last_write_time : Time) : Bool
      Time.utc - last_write_time > delay
    end
  end
  
  # Middleware for automatic switching
  class DatabaseSelector
    property resolver : ConnectionResolver
    
    def initialize(@resolver : ConnectionResolver = DefaultResolver.new)
    end
    
    def call(context : HTTP::Server::Context, &)
      if resolver.reading_request?(context.request.method)
        Grant::Base.connected_to(role: :reading) do
          yield
        end
      else
        Grant::Base.connected_to(role: :writing) do
          yield
        end
      end
    end
  end
end
```

### 4. Horizontal Sharding Support

```crystal
module Grant
  module Sharding
    # Shard selector determines which shard to use
    abstract class ShardSelector
      abstract def shard_for(key : String | Int32 | Int64) : Symbol
    end
    
    class HashShardSelector < ShardSelector
      property shards : Array(Symbol)
      
      def initialize(@shards)
      end
      
      def shard_for(key : String | Int32 | Int64) : Symbol
        hash = key.hash
        index = hash % shards.size
        shards[index]
      end
    end
    
    class RangeShardSelector < ShardSelector
      property ranges : Hash(Range(Int32, Int32), Symbol)
      
      def initialize(@ranges)
      end
      
      def shard_for(key : String | Int32 | Int64) : Symbol
        numeric_key = key.to_i
        ranges.each do |range, shard|
          return shard if range.includes?(numeric_key)
        end
        raise "No shard found for key: #{key}"
      end
    end
    
    # Module to include in sharded models
    module ShardedModel
      macro included
        class_property shard_selector : Grant::Sharding::ShardSelector?
        class_property shard_key : Symbol = :id
        
        # Override find to use sharding
        def self.find(id)
          if selector = shard_selector
            shard = selector.shard_for(id)
            connected_to(shard: shard) do
              super(id)
            end
          else
            super(id)
          end
        end
        
        # Set shard based on attribute
        def determine_shard
          if selector = self.class.shard_selector
            key_value = attributes[self.class.shard_key]
            @current_shard = selector.shard_for(key_value)
          end
        end
        
        before_save :determine_shard
      end
    end
  end
end
```

### 5. Migration Support for Multiple Databases

```crystal
module Grant
  module Migrations
    class Migration
      property database : String = "primary"
      
      # Specify target database
      macro database(name)
        @database = {{name.stringify}}
      end
      
      def up
        Grant::Base.connected_to(database: @database, role: :writing) do
          execute_migration
        end
      end
      
      def down
        Grant::Base.connected_to(database: @database, role: :writing) do
          rollback_migration
        end
      end
    end
    
    class Migrator
      # Run migrations for specific database
      def self.run(database : String? = nil)
        migrations = load_migrations(database)
        
        migrations.each do |migration|
          migration.up unless migration.executed?
        end
      end
      
      private def self.load_migrations(database : String?)
        if database
          Dir.glob("db/migrate/#{database}/*.cr")
        else
          Dir.glob("db/migrate/**/*.cr")
        end
      end
    end
  end
end
```

## Implementation Plan

### Phase 1: Foundation (Week 1-2)
1. Create new connection registry with pools
2. Implement basic `connects_to` macro
3. Add `connected_to` method for block-based switching
4. Maintain backward compatibility

### Phase 2: Vertical Scaling (Week 3-4)
1. Implement role-based connections (reading/writing)
2. Create connection resolver interface
3. Add automatic switching middleware
4. Enhance read replica support

### Phase 3: Horizontal Sharding (Week 5-6)
1. Implement shard specifications
2. Create shard selector strategies
3. Add sharded model support
4. Override query methods for sharding

### Phase 4: Tooling & Polish (Week 7-8)
1. Migration support for multiple databases
2. Database-specific tasks
3. Connection pool monitoring
4. Performance optimizations

## Example Usage

### Basic Multiple Database Setup

```crystal
# config/database.cr
Grant::ConnectionRegistry.register_database("primary", 
  Grant::DatabaseConfig.new("primary", Grant::Adapter::Pg, pool_size: 25)
)
Grant::ConnectionRegistry.add_connection("primary", :writing, ENV["PRIMARY_DATABASE_URL"])
Grant::ConnectionRegistry.add_connection("primary", :reading, ENV["PRIMARY_REPLICA_URL"])

Grant::ConnectionRegistry.register_database("analytics",
  Grant::DatabaseConfig.new("analytics", Grant::Adapter::Pg, pool_size: 10)
)
Grant::ConnectionRegistry.add_connection("analytics", :writing, ENV["ANALYTICS_DATABASE_URL"])
```

### Model Configuration

```crystal
# Primary database models
abstract class ApplicationRecord < Grant::Base
  connects_to database: { writing: :primary, reading: :primary_replica }
end

class User < ApplicationRecord
  # Uses primary database
end

# Analytics database models
abstract class AnalyticsRecord < Grant::Base
  connects_to database: { writing: :analytics, reading: :analytics }
end

class PageView < AnalyticsRecord
  # Uses analytics database
end

# Sharded model
class Order < ApplicationRecord
  include Grant::Sharding::ShardedModel
  
  connects_to shards: {
    shard_one: { writing: :shard1_primary, reading: :shard1_replica },
    shard_two: { writing: :shard2_primary, reading: :shard2_replica }
  }
  
  self.shard_selector = Grant::Sharding::HashShardSelector.new([:shard_one, :shard_two])
  self.shard_key = :user_id
end
```

### Usage Examples

```crystal
# Automatic connection switching
users = User.all  # Uses reading connection if no recent writes

# Manual connection control
User.connected_to(role: :writing) do
  User.create(name: "John")  # Forces writing connection
end

# Shard switching
Order.connected_to(shard: :shard_one) do
  Order.where(status: "pending").select  # Query specific shard
end

# Cross-database queries (be careful!)
ApplicationRecord.connected_to(role: :reading) do
  AnalyticsRecord.connected_to(role: :reading) do
    # Both use reading connections
    users = User.all
    page_views = PageView.where(user_id: users.map(&.id))
  end
end
```

## Benefits of This Approach

1. **Flexibility**: Support for any number of databases, roles, and shards
2. **Performance**: Connection pooling and intelligent switching
3. **Compatibility**: Maintains backward compatibility with existing code
4. **Safety**: Prevents accidental cross-database joins
5. **Scalability**: Easy to add new databases or shards
6. **Developer Experience**: Clean API similar to Rails

## Challenges & Considerations

1. **Connection Pool Management**: Need efficient pool implementation
2. **Thread Safety**: Crystal's concurrency model requires careful design
3. **Performance Overhead**: Minimize connection switching cost
4. **Configuration Complexity**: Balance flexibility with simplicity
5. **Testing**: Need to test various connection scenarios

## Conclusion

This architecture provides Grant with enterprise-grade multiple database support, enabling:
- Vertical scaling through read replicas
- Horizontal scaling through sharding
- Flexible connection management
- Clean, Rails-like API

The implementation maintains Grant's Crystal-native performance while adding the flexibility needed for modern applications.