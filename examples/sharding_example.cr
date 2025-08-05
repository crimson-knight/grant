require "../src/granite"
require "../src/granite/sharding"

# Example: E-commerce platform with user data sharded by user_id
class User < Granite::Base
  connection "primary"
  table users
  
  include Granite::Sharding::Model
  
  # Shard users across 4 shards using hash strategy
  shards_by :id, strategy: :hash, count: 4
  
  column id : Int64, primary: true
  column name : String
  column email : String
  column created_at : Time = Time.utc
  
  has_many orders : Order
end

class Order < Granite::Base
  connection "primary"
  table orders
  
  include Granite::Sharding::Model
  
  # Shard orders by user_id to keep user data together
  shards_by :user_id, strategy: :hash, count: 4
  
  column id : Int64, primary: true
  column user_id : Int64
  column total : Float64
  column status : String
  column created_at : Time = Time.utc
  
  belongs_to user : User
end

# Example: Multi-tenant SaaS application
class Tenant < Granite::Base
  connection "primary"
  table tenants
  
  # Tenants table is not sharded - it's the control plane
  column id : Int64, primary: true
  column name : String
  column plan : String
  column created_at : Time = Time.utc
end

class TenantData < Granite::Base
  connection "primary"
  table tenant_data
  
  include Granite::Sharding::Model
  
  # Shard by tenant_id for data isolation
  shards_by :tenant_id, strategy: :hash, count: 8
  
  column id : Int64, primary: true
  column tenant_id : Int64
  column key : String
  column value : String
  column created_at : Time = Time.utc
end

# Example: Range-based sharding for time-series data
class Event < Granite::Base
  connection "primary"
  table events
  
  include Granite::Sharding::Model
  extend Granite::Sharding::CompositeId
  
  # Shard by composite ID with time prefix
  shards_by :id, strategy: :range, ranges: [
    {min: "2024_01", max: "2024_06_99", shard: :shard_2024_h1},
    {min: "2024_07", max: "2024_12_99", shard: :shard_2024_h2},
    {min: "2025_01", max: "2025_12_99", shard: :shard_2025}
  ]
  
  column id : String, primary: true
  column event_type : String
  column metadata : JSON::Any?
  column created_at : Time = Time.utc
  
  before_create :generate_id
  
  private def generate_id
    self.id ||= Event.generate_composite_id("EVT")
  end
end

# Example: Geo-based sharding for global applications
class RegionalCustomer < Granite::Base
  connection "primary"
  table regional_customers
  
  include Granite::Sharding::Model
  include Granite::Sharding::RegionDetermination::ExplicitRegion
  
  # Shard by location
  shards_by [:country, :state], strategy: :geo,
    regions: [
      {shard: :shard_us_west, countries: ["US"], states: ["CA", "OR", "WA"]},
      {shard: :shard_us_east, countries: ["US"], states: ["NY", "NJ", "FL"]},
      {shard: :shard_eu, countries: ["GB", "DE", "FR", "IT"]},
      {shard: :shard_apac, countries: ["JP", "AU", "SG", "CN"]}
    ],
    default_shard: :shard_global
  
  column id : Int64, primary: true
  column email : String
  column country : String
  column state : String?
  column created_at : Time = Time.utc
end

# Usage Examples:

# 1. Simple queries are automatically routed
user = User.find(123) # Goes directly to the shard containing user 123

# 2. Queries with shard key are optimized
orders = Order.where(user_id: 123).select # Only queries the shard for user 123

# 3. Scatter-gather for queries without shard key
active_orders = Order.where(status: "active").select # Queries all shards in parallel

# 4. Force query to specific shard
shard_0_users = User.on_shard(:shard_0).where(created_at: Time.utc - 1.day).select

# 5. Aggregate across all shards
total_users = User.count # Aggregates count from all shards

# 6. Cross-shard operations
User.on_all_shards do
  # Maintenance operation that runs on each shard
  User.where("created_at < ?", Time.utc - 1.year).delete_all
end

# 7. Shard-aware batch operations
User.find_each(batch_size: 1000) do |user|
  # Process users in batches, automatically handling shard iteration
  puts "Processing user #{user.id} on shard #{user.current_shard}"
end

# 8. Transaction within a shard
user_id = 456_i64
shard = Granite::ShardManager.resolve_shard("User", id: user_id)

Granite::ShardManager.with_shard(shard) do
  User.transaction do
    user = User.find!(user_id)
    user.name = "Updated Name"
    user.save!
    
    # Create related order on same shard
    Order.create!(
      user_id: user_id,
      total: 99.99,
      status: "pending"
    )
  end
end

# 9. Range-based sharding with time-series data
event = Event.new(event_type: "page_view", metadata: JSON.parse(%({"url": "/home"})))
event.save # ID like "EVT_2024_11_15_1731686400000_a3f7" routes to shard_2024_h2

# Query efficiently by time range
recent_events = Event.where("id >= ? AND id < ?", "2024_11_01", "2024_12_01").select

# 10. Geo-based sharding with explicit regions
customer = RegionalCustomer.create!(
  email: "user@example.com",
  country: "US",
  state: "CA"
) # Automatically saved to shard_us_west

# Regional queries stay on single shard
ca_customers = RegionalCustomer.where(country: "US", state: "CA").select

# 11. Using region context in web apps
class WebController
  def handle_request(context)
    # Set region from IP geolocation
    Granite::Sharding::RegionDetermination::Context.with(
      country: detect_country(context.request.remote_address)
    ) do
      # All models created here can use the context
      TenantData.create!(key: "setting", value: "dark_mode")
    end
  end
end

puts "Sharding example demonstrates hash, range, and geo sharding patterns"