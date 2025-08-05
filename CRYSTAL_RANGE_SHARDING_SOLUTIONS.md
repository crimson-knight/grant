# Crystal-Native Range Sharding Solutions

## Option 1: Composite Keys with Time Prefix (RECOMMENDED)

This is the most straightforward approach using Crystal's standard library:

```crystal
class Order < Granite::Base
  include Granite::Sharding::Model
  
  # Composite key: "2024_01_15_1234567890_abc123"
  # Format: YYYY_MM_DD_TIMESTAMP_RANDOM
  column id : String, primary: true
  
  # Shard by year-month prefix
  shards_by :id, strategy: :range, ranges: [
    {min: "2023_01", max: "2023_12_99", shard: :shard_2023},
    {min: "2024_01", max: "2024_06_99", shard: :shard_2024_h1},
    {min: "2024_07", max: "2024_12_99", shard: :shard_2024_h2},
    {min: "2025_01", max: "2025_12_99", shard: :shard_2025}
  ]
  
  before_create :generate_composite_id
  
  private def generate_composite_id
    return if self.id # Don't override if already set
    
    now = Time.utc
    timestamp = now.to_unix_ms
    random_suffix = Random::Secure.hex(6)
    
    # Format: YYYY_MM_DD_TIMESTAMP_RANDOM
    self.id = String.build do |str|
      str << now.to_s("%Y_%m_%d")
      str << "_"
      str << timestamp
      str << "_"
      str << random_suffix
    end
  end
end

# Examples:
# "2024_01_15_1705344567890_a3f7b9"  -> goes to shard_2024_h1
# "2024_08_22_1724352567890_c2e8d1"  -> goes to shard_2024_h2
# "2025_01_01_1735689600000_f5a2c8"  -> goes to shard_2025
```

## Option 2: Unix Timestamp with Microseconds

Using Int64 with microsecond precision for natural time ordering:

```crystal
class Event < Granite::Base
  include Granite::Sharding::Model
  
  # ID is microseconds since epoch
  column id : Int64, primary: true
  
  # Shard by time ranges (as Int64)
  shards_by :id, strategy: :range, ranges: [
    # 2023: 1672531200000000 to 1704067199999999
    {min: 1672531200000000_i64, max: 1704067199999999_i64, shard: :shard_2023},
    # 2024 Q1-Q2: 1704067200000000 to 1719791999999999
    {min: 1704067200000000_i64, max: 1719791999999999_i64, shard: :shard_2024_h1},
    # 2024 Q3-Q4: 1719792000000000 to 1735689599999999
    {min: 1719792000000000_i64, max: 1735689599999999_i64, shard: :shard_2024_h2},
    # 2025+
    {min: 1735689600000000_i64, max: 9223372036854775807_i64, shard: :shard_current}
  ]
  
  before_create :generate_timestamp_id
  
  private def generate_timestamp_id
    return if self.id
    
    # Ensure uniqueness even within same microsecond
    loop do
      candidate_id = Time.utc.to_unix_f * 1_000_000
      
      # Add small random component to last 3 digits for uniqueness
      candidate_id += Random.rand(1000)
      
      # Check uniqueness (optional - depends on your needs)
      unless Event.exists?(id: candidate_id)
        self.id = candidate_id.to_i64
        break
      end
    end
  end
end

# Helper for human-readable range definitions
module TimeRangeHelper
  def self.time_to_id(time_str : String) : Int64
    Time.parse(time_str, "%F %T", Time::Location::UTC).to_unix_f * 1_000_000
  end
end

# Cleaner configuration using helper
shards_by :id, strategy: :range, ranges: [
  {
    min: TimeRangeHelper.time_to_id("2024-01-01 00:00:00"),
    max: TimeRangeHelper.time_to_id("2024-07-01 00:00:00"),
    shard: :shard_2024_h1
  }
]
```

## Option 3: Dedicated Sequence Table

Pre-allocate ranges per shard for guaranteed distribution:

```crystal
# Migration
create_table :shard_sequences do
  column :shard_name, :string, null: false
  column :year_month, :string, null: false
  column :next_value, :bigint, null: false, default: 1
  column :max_value, :bigint, null: false
  
  index [:shard_name, :year_month], unique: true
end

# Sequence manager
class ShardSequence < Granite::Base
  connection "primary"
  table shard_sequences
  
  column shard_name : String
  column year_month : String
  column next_value : Int64
  column max_value : Int64
  
  # Pre-create sequences for each shard/month
  def self.setup_for_month(year : Int32, month : Int32)
    base = Time.utc(year, month, 1).to_unix * 1_000_000
    
    [
      {name: "shard_2024_h1", range: (base + 0...base + 1_000_000_000)},
      {name: "shard_2024_h2", range: (base + 1_000_000_000...base + 2_000_000_000)},
      {name: "shard_current", range: (base + 2_000_000_000...base + 3_000_000_000)}
    ].each do |shard|
      create!(
        shard_name: shard[:name],
        year_month: "#{year}_#{month.to_s.rjust(2, '0')}",
        next_value: shard[:range].begin,
        max_value: shard[:range].end
      )
    end
  end
  
  def self.next_id_for_shard(shard : Symbol) : Int64
    year_month = Time.utc.to_s("%Y_%m")
    
    # Atomic increment
    result = Granite::Base.exec(<<-SQL, shard.to_s, year_month)
      UPDATE shard_sequences 
      SET next_value = next_value + 1
      WHERE shard_name = ? AND year_month = ?
      RETURNING next_value - 1 as id
    SQL
    
    result.rows.first[0].as(Int64)
  end
end

class Order < Granite::Base
  include Granite::Sharding::Model
  
  # IDs are pre-allocated per shard
  shards_by :id, strategy: :range, ranges: [
    {min: 1704067200000000_i64, max: 1704067200999999999_i64, shard: :shard_2024_h1},
    {min: 1704067201000000000_i64, max: 1704067201999999999_i64, shard: :shard_2024_h2},
    {min: 1704067202000000000_i64, max: 9223372036854775807_i64, shard: :shard_current}
  ]
  
  before_create :assign_sharded_id
  
  private def assign_sharded_id
    return if self.id
    
    # Determine target shard based on business logic
    target_shard = determine_target_shard
    self.id = ShardSequence.next_id_for_shard(target_shard)
  end
end
```

## Option 4: Simple Time-Based String Keys

The simplest approach - just use formatted timestamps:

```crystal
class LogEntry < Granite::Base
  include Granite::Sharding::Model
  
  # ID format: "20240115_143052_123456_a3f7"
  # YearMonthDay_HourMinSec_Microsec_Random
  column id : String, primary: true
  
  shards_by :id, strategy: :range, ranges: [
    {min: "20240101", max: "20240630_999999", shard: :shard_2024_h1},
    {min: "20240701", max: "20241231_999999", shard: :shard_2024_h2},
    {min: "20250101", max: "20251231_999999", shard: :shard_2025}
  ]
  
  before_create :generate_time_id
  
  private def generate_time_id
    return if self.id
    
    now = Time.utc
    microseconds = (now.to_unix_f * 1_000_000).to_i % 1_000_000
    random = Random::Secure.hex(2)
    
    self.id = String.build do |str|
      str << now.to_s("%Y%m%d_%H%M%S")
      str << "_"
      str << microseconds.to_s.rjust(6, '0')
      str << "_"
      str << random
    end
  end
end
```

## Comparison & Recommendations

| Approach | Pros | Cons | Best For |
|----------|------|------|----------|
| **Composite String Keys** | Human-readable, Easy debugging, Flexible format | Larger storage (vs Int64), String comparisons | Most use cases |
| **Unix Timestamp Int64** | Compact, Fast comparisons, Natural ordering | Less readable, Uniqueness concerns | High-performance systems |
| **Sequence Table** | Guaranteed uniqueness, Perfect distribution | Extra complexity, Requires maintenance | Mission-critical systems |
| **Simple Time Strings** | Dead simple, No dependencies | Larger keys, String sorting | Logging, low-volume data |

## Recommended Implementation

For Grant/Granite, I recommend **Option 1 (Composite String Keys)** because:

1. **No external dependencies** - Uses only Crystal stdlib
2. **Human-readable** - Easy debugging and operations
3. **Flexible** - Can embed shard hints in the ID itself
4. **Predictable** - Know the shard before insert

Here's a complete implementation:

```crystal
module Granite::Sharding
  module CompositeId
    def generate_sharded_id(prefix : String? = nil) : String
      now = Time.utc
      timestamp = now.to_unix_ms
      random = Random::Secure.hex(4)
      
      String.build do |str|
        str << prefix << "_" if prefix
        str << now.to_s("%Y%m%d")
        str << "_"
        str << timestamp.to_s.rjust(13, '0')
        str << "_"
        str << random
      end
    end
  end
end

# Usage
class Order < Granite::Base
  include Granite::Sharding::Model
  extend Granite::Sharding::CompositeId
  
  column id : String, primary: true
  
  shards_by :id, strategy: :range, ranges: [
    {min: "ORD_20240101", max: "ORD_20240630", shard: :shard_2024_h1},
    {min: "ORD_20240701", max: "ORD_20241231", shard: :shard_2024_h2},
    {min: "ORD_20250101", max: "ORD_99999999", shard: :shard_current}
  ]
  
  before_create do
    self.id ||= Order.generate_sharded_id("ORD")
  end
end
```

This gives you IDs like:
- `ORD_20240115_1705344567890_a3f7` 
- `ORD_20240822_1724352567890_c2e8`

Which are sortable, debuggable, and shard-predictable!