require "../src/grant"
require "../src/grant/sharding"

# GOOD PATTERNS - These work well with sharding

# Pattern 1: Keep related data on same shard
class User < Grant::Base
  include Grant::Sharding::Model
  shards_by :id, strategy: :hash, count: 4
  
  has_many orders : Order
  has_many addresses : Address
end

class Order < Grant::Base
  include Grant::Sharding::Model
  shards_by :user_id, strategy: :hash, count: 4  # Same as User!
  
  belongs_to user : User
  has_many order_items : OrderItem
end

class OrderItem < Grant::Base
  include Grant::Sharding::Model
  shards_by :user_id, strategy: :hash, count: 4  # Denormalized from Order
  
  belongs_to order : Order
  column user_id : Int64  # Denormalized for sharding
end

# Pattern 2: Application-level joins for cross-shard data
class ProductView
  # Products might be on different shards than orders
  def self.get_user_product_history(user_id : Int64)
    # Step 1: Get user's orders (single shard query)
    orders = Order.where(user_id: user_id).select
    
    # Step 2: Collect product IDs
    product_ids = orders.map(&.product_id).uniq
    
    # Step 3: Fetch products (might be on different shard)
    products = Product.where(id: product_ids).select
    
    # Step 4: Join in application
    orders.map do |order|
      product = products.find { |p| p.id == order.product_id }
      {order: order, product: product}
    end
  end
end

# Pattern 3: Event-driven updates instead of transactions
class OrderService
  def complete_order(order_id : Int64)
    # Instead of distributed transaction:
    # DB.transaction do
    #   order.update!(status: "completed")      # Shard 1
    #   inventory.decrement!(quantity)          # Shard 2  
    #   user.add_points!(100)                   # Shard 3
    # end
    
    # Use event-driven approach:
    order = Order.find(order_id)
    order.status = "completed"
    order.save!
    
    # Emit events for other systems
    EventBus.publish("order.completed", {
      order_id: order_id,
      user_id: order.user_id,
      items: order.items.map(&.to_h)
    })
    
    # Other services handle their updates asynchronously
    # If they fail, they can be retried
  end
end

# Pattern 4: Denormalization for read performance
class DenormalizedOrder < Grant::Base
  include Grant::Sharding::Model
  shards_by :user_id, strategy: :hash, count: 4
  
  # Order data
  column id : Int64, primary: true
  column user_id : Int64
  column total : Float64
  
  # Denormalized user data (avoid join)
  column user_name : String
  column user_email : String
  column user_country : String
  
  # Denormalized product data (avoid join)
  column product_names : Array(String)
  column product_skus : Array(String)
end

# Pattern 5: Read replicas for analytics
class AnalyticsService
  # Don't run analytics on sharded operational data
  # Use read replicas or data warehouse
  
  def self.daily_revenue_report
    # This would run on a read replica or data warehouse
    # that aggregates data from all shards
    Analytics::Revenue.where(date: Time.local.at_beginning_of_day).sum(:total)
  end
end

# ANTI-PATTERNS - These DON'T work with sharding

# Anti-pattern 1: Cross-shard joins
# Order.joins(:product).where("products.category = ?", "Electronics")
# FAILS if orders and products are on different shards

# Anti-pattern 2: Cross-shard transactions
# DB.transaction do
#   user1.balance -= 100    # Shard 1
#   user2.balance += 100    # Shard 2
# end
# No atomicity guarantee!

# Anti-pattern 3: Global unique constraints
# class Email < Grant::Base
#   validates :address, uniqueness: true  # Can't enforce across shards!
# end

# Anti-pattern 4: Foreign keys across shards
# add_foreign_key :orders, :products  # Won't work if on different shards

# SOLUTIONS

# Solution 1: Batch operations on same shard
class BatchProcessor
  def self.process_user_orders(user_id : Int64)
    # All operations on same shard
    ShardManager.with_shard(User.shard_for_id(user_id)) do
      user = User.find(user_id)
      orders = user.orders
      
      DB.transaction do
        orders.each do |order|
          order.process!
        end
        user.last_processed_at = Time.utc
        user.save!
      end
    end
  end
end

# Solution 2: Eventual consistency with retries
class EventualConsistencyProcessor
  def self.transfer_points(from_user_id : Int64, to_user_id : Int64, points : Int32)
    # Step 1: Deduct points (might succeed)
    begin
      from_user = User.find(from_user_id)
      from_user.points -= points
      from_user.save!
    rescue
      return false  # Failed to deduct
    end
    
    # Step 2: Add points (might fail)
    begin
      to_user = User.find(to_user_id)
      to_user.points += points
      to_user.save!
    rescue
      # Compensation: Return points to sender
      RetryJob.perform_later do
        from_user = User.find(from_user_id)
        from_user.points += points
        from_user.save!
      end
      return false
    end
    
    true
  end
end

puts "See these patterns for building sharding-friendly applications"