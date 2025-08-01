require "../src/granite"

# Example sharding implementations for Grant ORM

# 1. Simple Hash Sharding by User ID
class User < Granite::Base
  table users
  column id : Int64, primary: true
  column email : String
  column country : String
  column created_at : Time
  
  # Hash sharding across 4 shards
  shards_by :id, strategy: :hash, count: 4
  
  connects_to shards: {
    shard_0: {
      writing: ENV["USER_SHARD_0_PRIMARY_URL"],
      reading: ENV["USER_SHARD_0_REPLICA_URL"]
    },
    shard_1: {
      writing: ENV["USER_SHARD_1_PRIMARY_URL"],
      reading: ENV["USER_SHARD_1_REPLICA_URL"]
    },
    shard_2: {
      writing: ENV["USER_SHARD_2_PRIMARY_URL"],
      reading: ENV["USER_SHARD_2_REPLICA_URL"]
    },
    shard_3: {
      writing: ENV["USER_SHARD_3_PRIMARY_URL"],
      reading: ENV["USER_SHARD_3_REPLICA_URL"]
    }
  }
end

# 2. Multi-tenant Sharding with Composite Keys
class TenantData < Granite::Base
  table tenant_data
  
  # Composite key sharding - ensures all data for a tenant stays together
  shards_by :tenant_id, strategy: :hash, count: 8
  
  column id : Int64, primary: true
  column tenant_id : Int64
  column data_type : String
  column value : JSON::Any
  
  # Ensure queries always include tenant_id for proper routing
  default_scope { where(tenant_id: Current.tenant_id) }
end

# 3. Time-based Sharding for High-Volume Event Data
class Event < Granite::Base
  table events
  column id : Int64, primary: true
  column user_id : Int64
  column event_type : String
  column payload : JSON::Any
  column created_at : Time
  
  # Monthly sharding - new shard each month
  shards_by :created_at, strategy: :monthly do
    # Automatically creates shards like: events_2024_01, events_2024_02, etc.
    retention 6.months # Automatically archive/drop old shards
  end
  
  # Query examples:
  # Event.where(created_at: Time.utc(2024, 1, 15)).select # Routes to events_2024_01
  # Event.in_month(2024, 1).where(event_type: "login").select # Explicit month
end

# 4. Geographic Sharding for Compliance
class PersonalData < Granite::Base
  table personal_data
  column id : Int64, primary: true
  column user_id : Int64
  column data_classification : String
  column country_code : String
  column data : JSON::Any
  
  # Geographic sharding for GDPR compliance
  shards_by :country_code, strategy: :geographic do
    region :eu, countries: ["DE", "FR", "IT", "ES", "NL", "BE", "PL"], {
      writing: ENV["EU_PRIMARY_URL"],
      reading: ENV["EU_REPLICA_URL"]
    }
    
    region :us, countries: ["US"], {
      writing: ENV["US_PRIMARY_URL"],
      reading: ENV["US_REPLICA_URL"]
    }
    
    region :asia, countries: ["JP", "SG", "KR", "CN", "IN"], {
      writing: ENV["ASIA_PRIMARY_URL"],
      reading: ENV["ASIA_REPLICA_URL"]
    }
    
    # Default region for other countries
    default_region :global, {
      writing: ENV["GLOBAL_PRIMARY_URL"],
      reading: ENV["GLOBAL_REPLICA_URL"]
    }
  end
end

# 5. Advanced: Consistent Hashing for Dynamic Scaling
class Session < Granite::Base
  table sessions
  column id : String, primary: true
  column user_id : Int64
  column data : JSON::Any
  column expires_at : Time
  
  # Consistent hashing allows adding/removing shards with minimal reshuffling
  shards_by :id, strategy: :consistent_hash do
    virtual_nodes 150 # More virtual nodes = better distribution
    
    nodes({
      cache_1: ENV["SESSION_CACHE_1_URL"],
      cache_2: ENV["SESSION_CACHE_2_URL"],
      cache_3: ENV["SESSION_CACHE_3_URL"]
    })
  end
  
  # Add a new cache node dynamically
  def self.add_cache_node(name : Symbol, url : String)
    shard_config.add_node(name, url)
  end
end

# 6. Custom Sharding Logic
class GameScore < Granite::Base
  table game_scores
  column id : Int64, primary: true
  column player_id : Int64
  column game_id : Int64
  column score : Int32
  column achieved_at : Time
  
  # Custom sharding based on game and player
  shards_by do |score|
    # Shard by game_id to keep leaderboards together
    # But also consider player activity for hot partition avoidance
    game_shard = score.game_id % 4
    player_activity = Redis.new.get("player:#{score.player_id}:activity").to_i
    
    if player_activity > 1000 # High-activity players
      :"shard_hot_#{game_shard}"
    else
      :"shard_regular_#{game_shard}"
    end
  end
end

# Usage Examples

puts "=== Sharding Examples ==="

# 1. Creating records - automatically routed to correct shard
user = User.create(email: "user@example.com", country: "US")
puts "User #{user.id} created on shard: #{user.current_shard}"

# 2. Finding records - automatically determines shard from ID
found_user = User.find(user.id)
puts "Found user on shard: #{found_user.current_shard}"

# 3. Cross-shard queries
all_users_count = User.on_all_shards.count
puts "Total users across all shards: #{all_users_count}"

# 4. Shard-specific queries
shard_0_users = User.on_shard(:shard_0).where(country: "US").select
puts "US users on shard_0: #{shard_0_users.size}"

# 5. Parallel shard aggregation
country_counts = User.on_all_shards.parallel do |shard|
  group_by(:country).count
end.merge_results
puts "Users by country: #{country_counts}"

# 6. Geographic routing
eu_data = PersonalData.create(
  user_id: 123,
  country_code: "DE",
  data_classification: "PII",
  data: {"name" => "Hans Schmidt"}
)
puts "EU data stored in: #{eu_data.current_shard}"

# 7. Time-based routing
event = Event.create(
  user_id: user.id,
  event_type: "login",
  payload: {"ip" => "1.2.3.4"},
  created_at: Time.utc
)
puts "Event stored in monthly shard: #{event.current_shard}"

# 8. Resharding example
puts "\n=== Resharding Example ==="
Session.shard_config.nodes.each do |name, url|
  puts "Current node: #{name} -> #{url}"
end

# Add new node
Session.add_cache_node(:cache_4, ENV["SESSION_CACHE_4_URL"])
puts "Added cache_4 node"

# Show redistribution
affected_keys = Session.shard_config.affected_keys_for_new_node(:cache_4)
puts "Keys that moved to new node: #{affected_keys.size}"