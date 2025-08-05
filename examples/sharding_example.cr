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

puts "Sharding example demonstrates various sharding patterns and usage"