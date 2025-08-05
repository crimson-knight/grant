require "../src/granite"
require "../src/granite/sharding"

# Example 1: Time-based range sharding with composite IDs
class Order < Granite::Base
  connection "primary"
  table orders
  
  include Granite::Sharding::Model
  extend Granite::Sharding::CompositeId
  
  # Shard by composite string ID with date prefix
  shards_by :id, strategy: :range, ranges: [
    {min: "2023_01_01", max: "2023_12_31_999999", shard: :shard_2023},
    {min: "2024_01_01", max: "2024_06_30_999999", shard: :shard_2024_h1},
    {min: "2024_07_01", max: "2024_12_31_999999", shard: :shard_2024_h2},
    {min: "2025_01_01", max: "2029_12_31_999999", shard: :shard_current}
  ]
  
  column id : String, primary: true
  column user_id : Int64
  column total : Float64
  column status : String
  column created_at : Time = Time.utc
  
  before_create :generate_id
  
  private def generate_id
    self.id ||= Order.generate_composite_id("ORD")
  end
end

# Example 2: Numeric range sharding with Int64 timestamps
class Event < Granite::Base
  connection "primary"
  table events
  
  include Granite::Sharding::Model
  extend Granite::Sharding::CompositeId
  
  # Shard by timestamp ID (microseconds since epoch)
  shards_by :id, strategy: :range, ranges: [
    # 2023: Jan 1, 2023 00:00:00 UTC to Dec 31, 2023 23:59:59 UTC
    {min: 1672531200000000_i64, max: 1704067199999999_i64, shard: :shard_2023},
    # 2024 H1: Jan 1, 2024 to Jun 30, 2024
    {min: 1704067200000000_i64, max: 1719791999999999_i64, shard: :shard_2024_h1},
    # 2024 H2: Jul 1, 2024 to Dec 31, 2024
    {min: 1719792000000000_i64, max: 1735689599999999_i64, shard: :shard_2024_h2},
    # 2025+
    {min: 1735689600000000_i64, max: Int64::MAX, shard: :shard_current}
  ]
  
  column id : Int64, primary: true
  column event_type : String
  column user_id : Int64?
  column metadata : JSON::Any?
  column created_at : Time = Time.utc
  
  before_create :generate_timestamp_id
  
  private def generate_timestamp_id
    self.id ||= Event.generate_timestamp_id
  end
end

# Example 3: Time range sharding with helper
class AuditLog < Granite::Base
  connection "primary"
  table audit_logs
  
  include Granite::Sharding::Model
  
  # Use time_range strategy for cleaner configuration
  shards_by :id, strategy: :time_range, ranges: [
    {
      from: Time.parse("2023-01-01", "%F", Time::Location::UTC),
      to: Time.parse("2024-01-01", "%F", Time::Location::UTC),
      shard: :shard_2023
    },
    {
      from: Time.parse("2024-01-01", "%F", Time::Location::UTC),
      to: Time.parse("2024-07-01", "%F", Time::Location::UTC),
      shard: :shard_2024_h1
    },
    {
      from: Time.parse("2024-07-01", "%F", Time::Location::UTC),
      to: Time.parse("2025-01-01", "%F", Time::Location::UTC),
      shard: :shard_2024_h2
    },
    {
      from: Time.parse("2025-01-01", "%F", Time::Location::UTC),
      to: Time.parse("2030-01-01", "%F", Time::Location::UTC),
      shard: :shard_current
    }
  ]
  
  column id : String, primary: true
  column action : String
  column user_id : Int64?
  column ip_address : String?
  column created_at : Time = Time.utc
end

# Usage Examples:

# 1. Creating records - ID determines shard automatically
order = Order.new(user_id: 123, total: 99.99, status: "pending")
order.save  # ID generated: "ORD_2024_11_15_1731686400000_a3f7"
            # Automatically saved to shard_2024_h2

# 2. Querying by ID efficiently routes to single shard
order = Order.find("ORD_2024_06_15_1718409600000_b4c8")
# Only queries shard_2024_h1

# 3. Querying without shard key uses scatter-gather
pending_orders = Order.where(status: "pending").select
# Queries all shards in parallel

# 4. Time-based maintenance
# Archive old data by moving entire shards
Order.on_shard(:shard_2023) do
  # Backup 2023 data to cold storage
  # Then drop shard_2023 tables
end

# 5. Monitoring shard distribution
def shard_distribution_report
  shards = [:shard_2023, :shard_2024_h1, :shard_2024_h2, :shard_current]
  
  shards.each do |shard|
    count = Order.on_shard(shard).count
    puts "#{shard}: #{count} orders"
  end
end

# 6. Migrating between shards (rebalancing)
def migrate_orders_to_new_shard(from_date : Time, to_date : Time, target_shard : Symbol)
  Order.where("created_at >= ? AND created_at < ?", from_date, to_date).find_each do |order|
    # Would need special handling to move between shards
    # This is complex and requires careful coordination
  end
end

puts "Range sharding example demonstrates time-based data partitioning"