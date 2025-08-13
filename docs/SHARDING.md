# Horizontal Sharding in Grant (Grant)

> **⚠️ EXPERIMENTAL FEATURE**
> 
> Horizontal sharding support is currently **experimental** and subject to significant changes.
> - API may change in future releases
> - Not recommended for production use without extensive testing
> - Test coverage is incomplete
> - Please report issues and feedback

## Overview

Grant provides horizontal sharding capabilities to distribute data across multiple database instances. This feature enables applications to scale beyond the limits of a single database server.

## Current Status: Alpha

### What Works
- Basic sharding with hash, range, and geo strategies
- Query routing to appropriate shards
- Scatter-gather for cross-shard queries
- Virtual sharding for testing

### What's Missing
- Complete test coverage
- Production validation
- Real-world performance benchmarks
- Migration tooling
- Monitoring integration

### Known Limitations
- No distributed transactions
- No cross-shard joins
- Limited error handling
- Shard key updates not supported

## Basic Usage

### 1. Hash-Based Sharding

```crystal
class User < Grant::Base
  include Grant::Sharding::Model
  
  # Distribute users across 4 shards using ID hash
  shards_by :id, strategy: :hash, count: 4
  
  column id : Int64, primary: true
  column email : String
end
```

### 2. Range-Based Sharding

```crystal
class Order < Grant::Base
  include Grant::Sharding::Model
  extend Grant::Sharding::CompositeId
  
  # Shard by time ranges
  shards_by :id, strategy: :range, ranges: [
    {min: "2024_01", max: "2024_06_99", shard: :shard_2024_h1},
    {min: "2024_07", max: "2024_12_99", shard: :shard_2024_h2},
    {min: "2025_01", max: "2025_12_99", shard: :shard_current}
  ]
  
  column id : String, primary: true
  
  before_create :generate_id
  
  private def generate_id
    self.id ||= Order.generate_composite_id("ORD")
  end
end
```

### 3. Geographic Sharding

```crystal
class Customer < Grant::Base
  include Grant::Sharding::Model
  
  # Shard by location
  shards_by [:country, :state], strategy: :geo,
    regions: [
      {shard: :shard_us_west, countries: ["US"], states: ["CA", "OR", "WA"]},
      {shard: :shard_us_east, countries: ["US"], states: ["NY", "NJ", "FL"]},
      {shard: :shard_eu, countries: ["GB", "DE", "FR", "IT"]}
    ],
    default_shard: :shard_global
  
  column country : String
  column state : String?
end
```

## Query Operations

```crystal
# Automatic routing to correct shard
user = User.find(123)

# Query with shard key (optimized)
orders = Order.where(user_id: 456).select

# Query without shard key (scatter-gather)
active_users = User.where(active: true).select

# Force specific shard
User.on_shard(:shard_1).where(created_at: Time.utc - 1.day).select

# Maintenance across all shards
User.on_all_shards do
  User.where("created_at < ?", Time.utc - 1.year).delete_all
end
```

## Important Limitations

### 1. No Distributed Transactions
```crystal
# ❌ This will NOT work atomically across shards
DB.transaction do
  user1.balance -= 100  # shard_1
  user2.balance += 100  # shard_2
end
```

### 2. No Cross-Shard Joins
```crystal
# ❌ This will raise an error if orders and users are on different shards
Order.joins(:user).where("users.country = ?", "US")
```

### 3. Shard Keys Are Immutable
```crystal
# ❌ Cannot change shard key after creation
user.region = "EU"  # Was "US"
user.save  # Will raise error
```

## Best Practices

1. **Keep Related Data Together**
   - Shard orders by user_id to keep user's orders on same shard
   - Denormalize frequently joined data

2. **Design for Eventual Consistency**
   - Use events for cross-shard updates
   - Implement compensation logic for failures

3. **Test Thoroughly**
   - Use virtual sharding for unit tests
   - Test shard failures and network issues
   - Validate data distribution

## Configuration

### Database Setup

Each shard needs to be registered:

```crystal
# config/database.cr
Grant::ConnectionRegistry.establish_connection(
  database: "myapp",
  adapter: Grant::Adapter::Pg,
  url: ENV["SHARD_1_URL"],
  role: :primary,
  shard: :shard_1
)

Grant::ConnectionRegistry.establish_connection(
  database: "myapp",
  adapter: Grant::Adapter::Pg,
  url: ENV["SHARD_2_URL"],
  role: :primary,
  shard: :shard_2
)
```

## Testing

Use virtual sharding for tests:

```crystal
require "spec/support/simple_virtual_sharding"

describe "MyShardedModel" do
  include Grant::Testing::ShardingHelpers
  
  it "distributes data correctly" do
    with_virtual_shards(4) do
      # Your tests here
    end
  end
end
```

## Future Roadmap

### Phase 1 (Current)
- ✅ Basic sharding strategies
- ✅ Query routing
- ✅ Virtual testing
- ⏳ Production validation

### Phase 2 (Planned)
- Comprehensive test suite
- Migration utilities
- Monitoring hooks
- Performance optimizations

### Phase 3 (Future)
- Consistent hashing for elastic scaling
- Read replica support
- Cross-shard analytics helpers
- Admin UI for shard management

## Contributing

We need help with:
1. Testing in real applications
2. Performance benchmarks
3. Additional sharding strategies
4. Documentation improvements

Please report issues and share your use cases!

## References

- [Examples directory](../examples/) - Complete working examples
- [Design documents](../) - Architecture decisions
- [Test suite](../spec/grant/) - Current test coverage

Remember: **This is experimental software**. Test thoroughly before using in production!