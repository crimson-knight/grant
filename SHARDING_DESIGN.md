# Sharding Design for Grant ORM

## Overview

This document outlines the design for a Crystal-native sharding system that leverages Crystal's type system to create a beautiful and type-safe DSL.

## Core Concepts

### 1. Shard Keys

Shard keys can be:
- Single attributes (e.g., user_id)
- Composite keys (e.g., tenant_id + user_id)
- Computed values (e.g., hash of email)
- Time-based (e.g., created_at)

### 2. Shard Resolvers

Abstract interface for determining which shard to use:

```crystal
abstract class Granite::ShardResolver
  abstract def resolve(model : Granite::Base) : Symbol
  abstract def resolve_for_key(**keys) : Symbol
end
```

## Proposed DSL

### Basic Hash Sharding

```crystal
class User < Granite::Base
  # Simple hash sharding on single key
  shards_by :id, strategy: :hash, count: 4
  
  # This generates shards: :shard_0, :shard_1, :shard_2, :shard_3
  
  connects_to shards: {
    shard_0: {
      writing: "postgres://shard0-primary/users",
      reading: "postgres://shard0-replica/users"
    },
    shard_1: {
      writing: "postgres://shard1-primary/users",
      reading: "postgres://shard1-replica/users"
    },
    shard_2: {
      writing: "postgres://shard2-primary/users",
      reading: "postgres://shard2-replica/users"
    },
    shard_3: {
      writing: "postgres://shard3-primary/users",
      reading: "postgres://shard3-replica/users"
    }
  }
end
```

### Composite Key Sharding

```crystal
class Order < Granite::Base
  # Composite key sharding
  shards_by :tenant_id, :user_id, strategy: :hash, count: 8
  
  # Or with a block for custom logic
  shards_by do |order|
    # Custom sharding logic
    key = "#{order.tenant_id}:#{order.user_id}"
    shard_num = key.hash % 8
    :"shard_#{shard_num}"
  end
end
```

### Range-Based Sharding

```crystal
class Event < Granite::Base
  shards_by :created_at, strategy: :range do
    # Define ranges
    range Time.utc(2023, 1, 1)..Time.utc(2023, 12, 31), shard: :shard_2023
    range Time.utc(2024, 1, 1)..Time.utc(2024, 12, 31), shard: :shard_2024
    range Time.utc(2025, 1, 1)..Time::UNIX_EPOCH.max, shard: :shard_current
  end
end
```

### Geographic Sharding

```crystal
class Customer < Granite::Base
  shards_by :country_code, strategy: :lookup do
    # Regional sharding
    map "US", "CA", "MX" => :north_america
    map "GB", "FR", "DE", "IT", "ES" => :europe
    map "JP", "CN", "KR", "SG" => :asia_pacific
    default :global
  end
end
```

### Advanced: Multi-Level Sharding

```crystal
class Document < Granite::Base
  # First level: by organization
  shards_by :org_id, strategy: :hash, count: 4, prefix: :org
  
  # Second level: by time within organization
  shards_by :created_at, strategy: :monthly, within: :org_id
  
  # Results in shards like: :org_0_2024_01, :org_0_2024_02, etc.
end
```

## Implementation Components

### 1. Shard Key Definition

```crystal
module Granite::Sharding
  # Represents a shard key configuration
  struct ShardKey
    property attributes : Array(Symbol)
    property strategy : ShardStrategy
    property resolver : ShardResolver
    
    def resolve(model : Granite::Base) : Symbol
      resolver.resolve(model)
    end
  end
end
```

### 2. Built-in Strategies

```crystal
module Granite::Sharding::Strategies
  class HashStrategy < ShardResolver
    def initialize(@count : Int32, @prefix : String = "shard")
    end
    
    def resolve(model : Granite::Base) : Symbol
      values = @attributes.map { |attr| model.read_attribute(attr) }
      key = values.join(":")
      shard_num = key.hash % @count
      :"#{@prefix}_#{shard_num}"
    end
  end
  
  class RangeStrategy < ShardResolver
    def initialize(@ranges : Array(Tuple(Range, Symbol)))
    end
    
    def resolve(model : Granite::Base) : Symbol
      value = model.read_attribute(@attributes.first)
      @ranges.each do |(range, shard)|
        return shard if range.includes?(value)
      end
      raise "No shard found for value: #{value}"
    end
  end
  
  class LookupStrategy < ShardResolver
    def initialize(@mappings : Hash(Array(String), Symbol), @default : Symbol?)
    end
    
    def resolve(model : Granite::Base) : Symbol
      value = model.read_attribute(@attributes.first).to_s
      @mappings.each do |keys, shard|
        return shard if keys.includes?(value)
      end
      @default || raise "No shard found for value: #{value}"
    end
  end
  
  class ConsistentHashStrategy < ShardResolver
    def initialize(@nodes : Array(Symbol))
      @ring = ConsistentHashRing.new(@nodes)
    end
    
    def resolve(model : Granite::Base) : Symbol
      values = @attributes.map { |attr| model.read_attribute(attr) }
      key = values.join(":")
      @ring.get_node(key)
    end
  end
end
```

### 3. Query Integration

```crystal
# Automatic shard routing for queries
user = User.find(123) # Automatically routes to correct shard

# Explicit shard specification
User.on_shard(:shard_2).find(456)

# Cross-shard queries
User.on_all_shards.where(active: true).select # Returns results from all shards

# Shard-aware aggregations
User.on_all_shards.count # Sums counts from all shards
User.on_all_shards.group_by(:country).count # Merges results

# Parallel shard queries
results = User.on_shards(:shard_0, :shard_1, :shard_2).async do |shard|
  where(created_at: 30.days.ago..).count
end
```

### 4. Composite Key Support

Since Grant doesn't currently support composite primary keys, we need to add:

```crystal
class Order < Granite::Base
  # Composite primary key
  primary_key :tenant_id, :order_id
  
  # This would generate:
  # - Find by composite key: Order.find(tenant_id: 1, order_id: 123)
  # - Automatic shard resolution based on composite key
  # - Proper unique constraints
  
  shards_by_primary_key strategy: :hash, count: 8
end
```

## Benefits of This Design

1. **Type Safety**: Crystal's compile-time checks ensure shard keys exist
2. **Flexibility**: Multiple strategies with custom resolvers
3. **Performance**: Compile-time shard key resolution where possible
4. **Clarity**: DSL clearly expresses sharding intent
5. **Testability**: Easy to test shard resolution logic

## Migration Considerations

```crystal
class User < Granite::Base
  # Support for resharding
  shards_by :id, strategy: :consistent_hash, nodes: [
    :shard_0, :shard_1, :shard_2, :shard_3
  ]
  
  # Add new shards dynamically
  def self.add_shard(name : Symbol, connection_config)
    shard_resolver.add_node(name)
    connects_to shards: {name => connection_config}
  end
end
```

## Cross-Shard Transactions

```crystal
# Distributed transaction support (2PC)
Granite.distributed_transaction do
  user = User.find(123) # On shard_0
  order = Order.create(user_id: user.id, amount: 100) # On shard_2
  
  # Both operations succeed or both rollback
end
```

## Next Steps

1. Implement composite primary key support
2. Create base ShardResolver class and built-in strategies
3. Integrate shard resolution into query methods
4. Add cross-shard query capabilities
5. Implement distributed transaction coordinator