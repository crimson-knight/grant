# Region-Based Sharding: How to Determine Regions

## The Challenge

Unlike ID-based sharding where the shard key is generated, region-based sharding requires **explicit region information** at record creation. The region must come from somewhere - it's not something we can generate.

## Region Determination Strategies

### 1. Explicit User/Account Attribute

The most straightforward approach - store region as part of user data:

```crystal
class User < Grant::Base
  column id : Int64, primary: true
  column email : String
  column country : String      # Explicit region data
  column state : String?       # For country-level subdivision
  column preferred_region : String?  # User can override
  
  # Region is determined at registration
  def determine_region : Symbol
    # Check explicit preference first
    if pref = preferred_region
      return pref.to_sym
    end
    
    # Otherwise use country/state mapping
    case country
    when "US"
      case state
      when "CA", "OR", "WA", "NV", "AZ" then :shard_us_west
      when "NY", "NJ", "CT", "MA", "FL" then :shard_us_east
      else :shard_us_central
      end
    when "GB", "DE", "FR", "IT", "ES" then :shard_eu
    when "JP", "CN", "KR", "AU", "SG" then :shard_apac
    else :shard_global
    end
  end
end

# Orders inherit region from user
class Order < Grant::Base
  include Grant::Sharding::Model
  
  belongs_to user : User
  
  # Shard by user's region
  shards_by [:user_country, :user_state], strategy: :geo
  
  column id : Int64, primary: true
  column user_id : Int64
  column user_country : String  # Denormalized for sharding
  column user_state : String?   # Denormalized for sharding
  
  before_create :set_region_from_user
  
  private def set_region_from_user
    if u = user
      self.user_country = u.country
      self.user_state = u.state
    end
  end
end
```

### 2. IP-Based Geolocation

Determine region from request IP address:

```crystal
# Middleware to set region context
class GeoLocationMiddleware
  include HTTP::Handler
  
  def call(context)
    # Get client IP (considering proxies)
    client_ip = context.request.headers["X-Forwarded-For"]?.try(&.split(",").first) ||
                context.request.headers["X-Real-IP"]? ||
                context.request.remote_address.to_s
    
    # Look up region (using MaxMind, IP2Location, etc.)
    region_info = GeoIP.lookup(client_ip)
    
    # Store in fiber-local context
    Grant::ShardManager.set_context(
      country: region_info.country_code,
      state: region_info.state_code,
      city: region_info.city
    )
    
    call_next(context)
  end
end

# Models can access region context
class Event < Grant::Base
  include Grant::Sharding::Model
  
  shards_by [:country, :state], strategy: :geo
  
  column id : Int64, primary: true
  column country : String
  column state : String?
  column event_type : String
  
  before_create :set_region_from_context
  
  private def set_region_from_context
    if context = Grant::ShardManager.current_context
      self.country = context[:country]
      self.state = context[:state]?
    else
      # Fallback to default region
      self.country = "US"
      self.state = "CA"
    end
  end
end
```

### 3. API Request Headers

Client explicitly specifies region:

```crystal
# API accepts region in headers
class APIController
  def create_order
    # Client sends: X-Region: us-west
    # Or: X-Country: US, X-State: CA
    
    region = request.headers["X-Region"]?
    country = request.headers["X-Country"]?
    state = request.headers["X-State"]?
    
    order = Order.new(
      user_id: current_user.id,
      region: region || determine_region(country, state),
      # ... other fields
    )
    
    order.save
  end
end

class Order < Grant::Base
  include Grant::Sharding::Model
  
  # Simple region field
  shards_by :region, strategy: :lookup, mapping: {
    "us-west": :shard_us_west,
    "us-east": :shard_us_east,
    "eu": :shard_eu,
    "apac": :shard_apac
  }
  
  column region : String
end
```

### 4. Business Logic Determination

Region based on business rules:

```crystal
class Transaction < Grant::Base
  include Grant::Sharding::Model
  
  # Shard by merchant's region
  shards_by [:merchant_country], strategy: :geo
  
  belongs_to merchant : Merchant
  belongs_to customer : Customer
  
  column merchant_country : String
  column amount : Float64
  
  before_create :determine_transaction_region
  
  private def determine_transaction_region
    # Business rule: transactions process in merchant's region
    # for compliance and tax reasons
    self.merchant_country = merchant.country
    
    # Alternative rule: use customer's region for data residency
    # self.processing_country = customer.country
  end
end
```

### 5. Multi-Region Records (Read Replicas)

Some records need to exist in multiple regions:

```crystal
class GlobalProduct < Grant::Base
  include Grant::Sharding::Model
  
  # Products replicated to all regions for fast reads
  shards_by :primary_region, strategy: :geo, 
            replicate_to: [:shard_us, :shard_eu, :shard_apac]
  
  column id : Int64, primary: true
  column sku : String
  column primary_region : String  # Where writes go
  
  # Reads can happen from any region
  def self.find_in_nearest_region(id : Int64)
    nearest_shard = Grant::ShardManager.nearest_shard
    on_shard(nearest_shard).find(id)
  end
  
  # Writes go to primary region
  def save
    self.primary_region ||= Grant::ShardManager.current_region
    super
  end
end
```

## Practical Implementation for Grant

```crystal
module Grant::Sharding
  # Region determination helpers
  module RegionDetermination
    # Strategy 1: Explicit field
    module ExplicitRegion
      macro included
        column region : String
        column country : String?
        column state : String?
        
        before_create :validate_region
        
        private def validate_region
          unless region
            raise "Region must be explicitly set for sharded models"
          end
        end
      end
    end
    
    # Strategy 2: Derived from related model
    module DerivedRegion
      macro derive_region_from(association, *fields)
        before_create :set_region_from_{{association}}
        
        private def set_region_from_{{association}}
          if related = {{association}}
            {% for field in fields %}
              self.{{field}} = related.{{field}}
            {% end %}
          else
            raise "Cannot determine region: {{association}} not set"
          end
        end
      end
    end
    
    # Strategy 3: Context-based
    module ContextRegion
      macro included
        before_create :set_region_from_context
        
        private def set_region_from_context
          if context = Grant::ShardManager.current_context
            self.country = context[:country]? || raise "No country in context"
            self.state = context[:state]?
          else
            raise "No region context available"
          end
        end
      end
    end
  end
end

# Usage Examples:

# 1. Explicit region (e.g., user chooses at signup)
class User < Grant::Base
  include Grant::Sharding::Model
  include Grant::Sharding::RegionDetermination::ExplicitRegion
  
  shards_by [:country, :state], strategy: :geo
end

# 2. Derived region (e.g., order uses customer's region)
class Order < Grant::Base
  include Grant::Sharding::Model
  include Grant::Sharding::RegionDetermination::DerivedRegion
  
  belongs_to customer : Customer
  
  derive_region_from customer, country, state
  shards_by [:country, :state], strategy: :geo
end

# 3. Context region (e.g., events use request location)
class PageView < Grant::Base
  include Grant::Sharding::Model
  include Grant::Sharding::RegionDetermination::ContextRegion
  
  shards_by [:country], strategy: :geo
end
```

## Best Practices

1. **Always validate region data**
   - Don't allow NULL regions for sharded tables
   - Have a default/fallback region
   - Validate against allowed regions

2. **Denormalize region fields**
   - Store region data directly on sharded records
   - Avoids cross-shard joins to look up regions
   - Makes debugging easier

3. **Consider region migration**
   - Users may move between regions
   - Design for data portability
   - Plan for GDPR "right to data portability"

4. **Use meaningful region identifiers**
   ```crystal
   # Good: Clear what region this is
   region = "us-west-2"
   region = "eu-frankfurt"
   
   # Bad: Opaque identifiers
   region = "shard1"
   region = "dc3"
   ```

5. **Handle region determination failures**
   ```crystal
   def determine_region_with_fallback
     # Try multiple strategies
     region = try_ip_geolocation ||
              try_user_preference ||
              try_browser_locale ||
              default_region
   end
   ```

## Summary

Region-based sharding requires **explicit region information** from one of these sources:

1. **User data** - Country/state at registration
2. **IP geolocation** - Determine from request
3. **API headers** - Client specifies region
4. **Business logic** - Derived from related data
5. **Configuration** - Default regions per tenant

The key is making region determination **explicit and required** rather than optional. This ensures every record can be properly routed to its shard.