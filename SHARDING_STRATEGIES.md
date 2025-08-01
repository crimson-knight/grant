# Sharding Strategies Guide

## When to Use Each Strategy

### 1. Hash/Modulo Sharding
**Use when:**
- You need even data distribution
- Your shard key has high cardinality (many unique values)
- You don't need range queries across shards
- The number of shards is relatively stable

**Pros:**
- Simple to implement
- Even distribution
- Predictable performance

**Cons:**
- Difficult to add/remove shards (requires resharding)
- No locality of related data
- Range queries require hitting all shards

**Example:**
```crystal
class User < Granite::Base
  # Users distributed evenly across 8 shards
  shards_by :id, strategy: :hash, count: 8
end
```

### 2. Range-Based Sharding
**Use when:**
- You frequently query by ranges (dates, IDs, etc.)
- Data has natural ordering
- You need to archive old data easily

**Pros:**
- Efficient range queries
- Easy to add new shards for new ranges
- Natural data archival

**Cons:**
- Can create hotspots (recent data all goes to one shard)
- Uneven distribution if data isn't uniform

**Example:**
```crystal
class LogEntry < Granite::Base
  # Shard by month for easy archival
  shards_by :created_at, strategy: :range do
    range 1.month.ago..Time.utc => :current_month
    range 2.months.ago..1.month.ago => :last_month
    # Older data in archive shards
  end
end
```

### 3. Geographic Sharding
**Use when:**
- Data sovereignty/compliance requirements (GDPR)
- Reducing latency for regional users
- Legal requirements for data residency

**Pros:**
- Compliance with data regulations
- Lower latency for users
- Clear data boundaries

**Cons:**
- Uneven distribution by region
- Complex cross-region queries
- Requires geographic infrastructure

**Example:**
```crystal
class CustomerData < Granite::Base
  shards_by :country, strategy: :geographic do
    region :eu => ["DE", "FR", "IT", "ES"]
    region :us => ["US", "CA"]
    region :apac => ["JP", "AU", "SG"]
  end
end
```

### 4. Composite Key Sharding
**Use when:**
- You have multi-tenant applications
- Related data must stay together
- You need to query by multiple dimensions

**Pros:**
- Keeps related data together
- Enables efficient tenant isolation
- Good for multi-tenant SaaS

**Cons:**
- More complex key management
- Potential for uneven distribution

**Example:**
```crystal
class TenantResource < Granite::Base
  # All data for a tenant stays on same shard
  shards_by :tenant_id, :resource_type, strategy: :hash, count: 16
end
```

### 5. Consistent Hashing
**Use when:**
- You need to add/remove shards dynamically
- Minimizing data movement is critical
- Building distributed caches

**Pros:**
- Minimal data movement when scaling
- Better distribution with virtual nodes
- Gradual rebalancing

**Cons:**
- More complex implementation
- Slightly higher lookup overhead
- Requires careful tuning

**Example:**
```crystal
class CachedData < Granite::Base
  shards_by :key, strategy: :consistent_hash do
    virtual_nodes 200
    initial_shards [:cache_1, :cache_2, :cache_3]
  end
end
```

## Choosing a Shard Key

### Good Shard Keys:
1. **High Cardinality**: Many unique values
   - User ID, Order ID, Session ID
   
2. **Even Distribution**: Values spread evenly
   - UUIDs, Hash values
   
3. **Stable**: Doesn't change after creation
   - Created timestamp, Immutable IDs

### Bad Shard Keys:
1. **Low Cardinality**: Few unique values
   - Boolean flags, Status enums
   
2. **Skewed Distribution**: Some values much more common
   - Country (if most users from one country)
   - Popular category IDs
   
3. **Mutable**: Changes frequently
   - User status, Email addresses

## Composite Keys vs Single Keys

### When to use Composite Keys:
```crystal
# Multi-tenant application
class TenantData < Granite::Base
  # Composite key ensures tenant isolation
  shards_by :tenant_id, :year, strategy: :hash
  
  # All queries naturally include tenant_id
  default_scope { where(tenant_id: Current.tenant_id) }
end
```

### When to use Single Keys:
```crystal
# Simple user table
class User < Granite::Base
  # Single key is simpler and sufficient
  shards_by :id, strategy: :hash, count: 8
end
```

## Implementing Shard Resolution

### Basic Hash Resolution:
```crystal
module Granite::Sharding
  class HashResolver < ShardResolver
    def resolve_shard(key_values : Array)
      # Combine multiple values for composite keys
      combined_key = key_values.join(":")
      
      # Use CRC32 for better distribution than modulo
      hash_value = CRC32.checksum(combined_key)
      
      # Determine shard number
      shard_num = hash_value % @shard_count
      
      # Return shard symbol
      :"shard_#{shard_num}"
    end
  end
end
```

### Range Resolution with Binary Search:
```crystal
module Granite::Sharding
  class RangeResolver < ShardResolver
    def initialize(@ranges : Array({Range, Symbol}))
      # Sort ranges for binary search
      @ranges.sort_by! { |r, _| r.begin }
    end
    
    def resolve_shard(key_values : Array)
      value = key_values.first
      
      # Binary search for efficiency
      index = @ranges.bsearch_index { |r, _| r.begin > value } || @ranges.size
      
      return @ranges[index - 1][1] if index > 0
      raise "No shard for value: #{value}"
    end
  end
end
```

## Handling Cross-Shard Operations

### 1. Scatter-Gather Queries:
```crystal
# Get total count across all shards
total = User.on_all_shards.count

# Implementation
def on_all_shards
  results = parallel_map(all_shards) do |shard|
    on_shard(shard).count
  end
  results.sum
end
```

### 2. Ordered Cross-Shard Queries:
```crystal
# Get top 10 users by score across all shards
top_users = User.on_all_shards
  .order(score: :desc)
  .limit(10)
  .select

# Implementation merges sorted results from each shard
```

### 3. Cross-Shard Joins (Avoid!):
```crystal
# BAD: Requires data from multiple shards
orders = Order.joins(:user).where(users: {country: "US"})

# GOOD: Denormalize or use application-level joins
orders = Order.where(user_country: "US") # Denormalized
```

## Performance Considerations

1. **Connection Pool per Shard**: Each shard should have its own connection pool
2. **Parallel Execution**: Use fibers for concurrent shard queries
3. **Caching Shard Resolution**: Cache shard lookups for frequently accessed keys
4. **Monitor Shard Balance**: Track data distribution across shards

## Migration Strategies

### Adding Shards:
1. **Hash Sharding**: Requires resharding all data
2. **Range Sharding**: Just add new range for new data
3. **Consistent Hashing**: Minimal data movement

### Example Migration:
```crystal
class MigrationHelper
  def reshard_users(old_count : Int32, new_count : Int32)
    User.on_all_shards.find_in_batches do |batch|
      batch.each do |user|
        old_shard = hash_shard(user.id, old_count)
        new_shard = hash_shard(user.id, new_count)
        
        if old_shard != new_shard
          move_user_to_shard(user, new_shard)
        end
      end
    end
  end
end
```

## Best Practices

1. **Start Simple**: Begin with hash sharding, evolve as needed
2. **Plan for Growth**: Choose shard count as power of 2 for easier splitting
3. **Monitor Distribution**: Track data balance across shards
4. **Test Shard Failures**: Ensure app handles shard outages gracefully
5. **Document Strategy**: Make shard resolution logic clear and discoverable