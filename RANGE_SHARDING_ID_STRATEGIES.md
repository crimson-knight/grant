# Range-Based Sharding: ID Generation Strategies

## The Problem

With range-based sharding, you need to know the ID **before** insert to determine which shard to use. Traditional auto-increment IDs are generated **after** insert by the database, creating a chicken-and-egg problem.

## Solution Approaches

### 1. ULID (Universally Unique Lexicographically Sortable Identifier) ✅ RECOMMENDED

ULIDs are perfect for range-based sharding because they're:
- **Time-ordered**: First 48 bits are timestamp
- **Sortable**: Lexicographic sorting = chronological sorting
- **Unique**: No coordination needed between shards
- **Predictable**: You know the ID before insert

```crystal
# ULID Structure (26 characters)
# TTTTTTTTTTRRRRRRRRRRRRRRRR
# |---------|----------------|
# Timestamp   Random
# (48 bits)   (80 bits)

class Order < Grant::Base
  include Grant::Sharding::Model
  
  # Shard by ULID ranges (time-based)
  shards_by :id, strategy: :range, ranges: [
    # Historical data (2020-2022)
    {min: "01E000000000000000000000", max: "01G000000000000000000000", shard: :shard_archive},
    # 2023 data
    {min: "01G000000000000000000000", max: "01H000000000000000000000", shard: :shard_2023},
    # 2024 data
    {min: "01H000000000000000000000", max: "01J000000000000000000000", shard: :shard_2024},
    # Current/Future
    {min: "01J000000000000000000000", max: "7ZZZZZZZZZZZZZZZZZZZZZZZ", shard: :shard_current}
  ]
  
  column id : String, primary: true
  
  before_create :generate_ulid
  
  private def generate_ulid
    self.id ||= ULID.generate
  end
end

# Usage
order = Order.new(user_id: 123, total: 99.99)
# ULID generated before save: "01HK3QXKZ8RY4FQKQT5ZC6DJMR"
# System knows this goes to shard_current before inserting
order.save
```

### 2. Snowflake IDs (Twitter's Approach)

Snowflake IDs embed timestamp + machine ID + sequence:

```crystal
# Snowflake ID Structure (64 bits)
# 0 | 41 bits timestamp | 10 bits machine ID | 12 bits sequence
#
# Guarantees:
# - Time-ordered within same millisecond
# - No collisions across machines
# - Range-predictable based on timestamp

class SnowflakeGenerator
  def initialize(@machine_id : UInt16)
    @sequence = 0_u16
    @last_timestamp = 0_i64
  end
  
  def generate : Int64
    timestamp = Time.utc.to_unix_ms
    
    if timestamp == @last_timestamp
      @sequence = (@sequence + 1) & 0xFFF
      if @sequence == 0
        # Wait for next millisecond
        timestamp = wait_next_millis(timestamp)
      end
    else
      @sequence = 0
    end
    
    @last_timestamp = timestamp
    
    # Combine parts into ID
    ((timestamp - EPOCH) << 22) | (@machine_id << 12) | @sequence
  end
end

# Shard by time ranges (e.g., monthly)
shards_by :id, strategy: :range, ranges: [
  {min: snowflake_for_date("2024-01-01"), max: snowflake_for_date("2024-02-01"), shard: :shard_jan_2024},
  {min: snowflake_for_date("2024-02-01"), max: snowflake_for_date("2024-03-01"), shard: :shard_feb_2024},
  # etc...
]
```

### 3. Application-Managed Sequences

Pre-allocate ID ranges to application servers:

```crystal
class SequenceAllocator
  # Each app server gets a range of IDs
  def self.allocate_range(size : Int32 = 10000) : Range(Int64, Int64)
    # Atomic operation to claim next range
    DB.transaction do
      current = DB.scalar("SELECT next_value FROM sequence_ranges FOR UPDATE").as(Int64)
      next_value = current + size
      DB.exec("UPDATE sequence_ranges SET next_value = ?", next_value)
      current...next_value
    end
  end
end

class AppServer
  @@id_pool = [] of Int64
  @@pool_mutex = Mutex.new
  
  def self.next_id : Int64
    @@pool_mutex.synchronize do
      if @@id_pool.empty?
        range = SequenceAllocator.allocate_range
        @@id_pool = range.to_a
      end
      @@id_pool.shift
    end
  end
end
```

### 4. Composite Keys with Shard Prefix

Embed the shard directly in the ID:

```crystal
class ShardedOrder < Grant::Base
  # ID format: "shard_2024_1234567890"
  column id : String, primary: true
  
  before_create :generate_sharded_id
  
  private def generate_sharded_id
    timestamp = Time.utc
    shard = determine_shard_for_timestamp(timestamp)
    sequence = Redis.incr("sequence:#{shard}:#{timestamp.to_s("%Y%m%d")}")
    self.id = "#{shard}_#{timestamp.to_unix}_#{sequence}"
  end
end
```

## Comparison Table

| Strategy | Pros | Cons | Best For |
|----------|------|------|----------|
| **ULID** | Time-ordered, No coordination, Human-readable | 26 chars (larger than int64) | Most range-sharding use cases |
| **Snowflake** | Compact (64-bit), Time-ordered | Requires machine ID coordination | High-volume systems |
| **App Sequences** | Simple, Compact | Requires central coordinator | Small-scale systems |
| **Composite Keys** | Explicit shard info | String keys, Complex | Multi-tenant systems |

## Implementing ULID-Based Range Sharding

```crystal
# Add ULID support to Grant
module Grant::ULID
  ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  
  def self.generate : String
    timestamp = Time.utc.to_unix_ms
    
    # Generate timestamp portion (10 chars)
    time_chars = String::Builder.new(10)
    10.times do |i|
      time_chars << ENCODING[(timestamp >> (48 - (i + 1) * 5)) & 0x1F]
    end
    
    # Generate random portion (16 chars)
    random_chars = String::Builder.new(16)
    16.times do
      random_chars << ENCODING[Random.rand(32)]
    end
    
    time_chars.to_s + random_chars.to_s
  end
  
  def self.timestamp(ulid : String) : Time
    # Extract timestamp from first 10 characters
    timestamp = 0_i64
    ulid[0...10].each_char_with_index do |char, i|
      timestamp |= (ENCODING.index(char).not_nil!.to_i64 << (48 - (i + 1) * 5))
    end
    Time.unix_ms(timestamp)
  end
end

# Enhanced range resolver for time-based ranges
class TimeRangeResolver < RangeResolver
  def initialize(@key_columns : Array(Symbol), time_ranges : Array(NamedTuple(from: Time, to: Time, shard: Symbol)))
    ulid_ranges = time_ranges.map do |range|
      {
        min: ulid_for_time(range[:from]),
        max: ulid_for_time(range[:to]),
        shard: range[:shard]
      }
    end
    super(@key_columns, ulid_ranges)
  end
  
  private def ulid_for_time(time : Time) : String
    # Generate ULID prefix for given time
    # Only need first 10 chars for time comparison
    Grant::ULID.generate[0...10] + "0" * 16
  end
end

# Usage - Clean time-based configuration
class Order < Grant::Base
  shards_by :id, strategy: :time_range, ranges: [
    {from: Time.parse("2023-01-01", "%F", Time::Location::UTC), 
     to: Time.parse("2024-01-01", "%F", Time::Location::UTC), 
     shard: :shard_2023},
    {from: Time.parse("2024-01-01", "%F", Time::Location::UTC), 
     to: Time.parse("2025-01-01", "%F", Time::Location::UTC), 
     shard: :shard_2024},
    {from: Time.parse("2025-01-01", "%F", Time::Location::UTC), 
     to: Time.parse("2030-01-01", "%F", Time::Location::UTC), 
     shard: :shard_current}
  ]
end
```

## Best Practices

1. **Always use ULID for new range-sharded systems**
   - Simplest implementation
   - No coordination required
   - Natural time-based sharding

2. **Plan range boundaries carefully**
   - Consider data growth patterns
   - Leave room for expansion
   - Plan migration strategy upfront

3. **Monitor shard distribution**
   - Track records per shard
   - Alert on imbalanced growth
   - Plan rebalancing before needed

4. **Consider hybrid approaches**
   ```crystal
   # Recent data: range-based by time (fast access)
   # Old data: hash-based (even distribution)
   shards_by :id, strategy: :hybrid, 
     recent: {strategy: :range, days: 90},
     archive: {strategy: :hash, count: 16}
   ```