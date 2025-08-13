# Test Coverage Gaps for Sharding Feature

## Critical Tests Needed

### 1. Query Execution Tests
```crystal
it "returns correct data from scatter-gather queries" do
  # Insert test data across shards
  # Query without shard key
  # Verify all data returned correctly
end

it "handles empty shards in scatter-gather" do
  # Some shards have data, others don't
  # Verify no errors, correct results
end
```

### 2. Error Handling Tests
```crystal
it "raises clear error for nil shard keys" do
  expect_raises(Grant::Sharding::MissingShardKeyError) do
    model = ModelWithNullableKey.new(shard_key: nil)
    model.save
  end
end

it "handles shard connection failures" do
  # Simulate one shard being down
  # Verify partial results or clear error
end
```

### 3. Concurrent Access Tests
```crystal
it "maintains shard isolation across fibers" do
  channel = Channel(Symbol).new
  
  spawn do
    Grant::ShardManager.with_shard(:shard_1) do
      Fiber.yield
      channel.send(Grant::ShardManager.current_shard)
    end
  end
  
  spawn do
    Grant::ShardManager.with_shard(:shard_2) do
      channel.send(Grant::ShardManager.current_shard)
    end
  end
  
  results = [channel.receive, channel.receive]
  results.should contain(:shard_1)
  results.should contain(:shard_2)
end
```

### 4. Real Database Tests (Optional)
```crystal
# With actual PostgreSQL/MySQL shards
describe "Real database sharding" do
  it "works with PostgreSQL" do
    # Would need actual DB setup
  end
end
```

### 5. Performance Tests
```crystal
it "executes scatter-gather queries in parallel" do
  start_time = Time.monotonic
  
  # Query that hits 4 shards
  # Each shard artificially delayed by 100ms
  results = ShardedModel.where(status: "active").select
  
  elapsed = Time.monotonic - start_time
  # Should take ~100ms, not 400ms
  elapsed.total_milliseconds.should be < 150
end
```

### 6. Edge Case Tests
```crystal
it "handles shard key updates" do
  user = User.create!(id: 1, region: "US")
  original_shard = user.current_shard
  
  user.region = "EU"  # Would change shard!
  expect_raises(Grant::Sharding::ShardKeyMutationError) do
    user.save
  end
end
```

## Test Implementation Priority

1. **High Priority** (Block PR)
   - Nil shard key handling
   - Basic scatter-gather execution
   - Shard context isolation

2. **Medium Priority** (Can be follow-up)
   - Performance validation
   - Connection failure handling
   - Complex geo routing

3. **Low Priority** (Future)
   - Real database tests
   - Migration scenarios
   - Benchmarks

## Recommendation

The current test coverage is **not production-ready**. We should at least implement the high-priority tests before merging. The architecture is sound, but we need confidence that it actually works in practice, not just in theory.