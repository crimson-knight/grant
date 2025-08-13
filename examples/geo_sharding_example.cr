require "../src/grant"
require "../src/grant/sharding"

# Example 1: E-commerce with regional sharding
class Customer < Grant::Base
  connection "primary"
  table customers
  
  include Grant::Sharding::Model
  include Grant::Sharding::RegionDetermination::ExplicitRegion
  
  # Shard by customer location
  shards_by [:country, :state], strategy: :geo,
    regions: [
      # US West Coast
      {
        shard: :shard_us_west,
        countries: ["US"],
        states: ["CA", "OR", "WA", "NV", "AZ", "UT", "ID"]
      },
      # US East Coast
      {
        shard: :shard_us_east,
        countries: ["US"],
        states: ["NY", "NJ", "CT", "MA", "FL", "GA", "VA", "MD", "DC", "PA", "NC", "SC"]
      },
      # US Central (catch-all for other US states)
      {
        shard: :shard_us_central,
        countries: ["US"]
      },
      # Europe
      {
        shard: :shard_eu,
        countries: ["GB", "DE", "FR", "IT", "ES", "NL", "BE", "CH", "AT", "PL", "SE", "NO", "DK", "FI"]
      },
      # Asia Pacific
      {
        shard: :shard_apac,
        countries: ["JP", "CN", "KR", "AU", "NZ", "SG", "IN", "TH", "MY", "ID", "PH", "VN"]
      },
      # Latin America
      {
        shard: :shard_latam,
        countries: ["BR", "MX", "AR", "CO", "CL", "PE", "VE", "EC", "UY", "PY"]
      }
    ],
    default_shard: :shard_global
  
  column id : Int64, primary: true
  column email : String
  column name : String
  column country : String
  column state : String?
  column city : String?
  column created_at : Time = Time.utc
end

# Example 2: Orders inherit region from customer
class RegionalOrder < Grant::Base
  connection "primary"
  table regional_orders
  
  include Grant::Sharding::Model
  include Grant::Sharding::RegionDetermination::DerivedRegion
  
  belongs_to customer : Customer
  
  # Derive region from customer
  derive_region_from customer, country, state
  
  # Shard by customer's location for data locality
  shards_by [:country, :state], strategy: :geo,
    regions: [
      {shard: :shard_us_west, countries: ["US"], states: ["CA", "OR", "WA"]},
      {shard: :shard_us_east, countries: ["US"], states: ["NY", "NJ", "FL"]},
      {shard: :shard_eu, countries: ["GB", "DE", "FR"]},
      {shard: :shard_apac, countries: ["JP", "AU", "SG"]}
    ],
    default_shard: :shard_global
  
  column id : Int64, primary: true
  column customer_id : Int64
  column country : String  # Denormalized from customer
  column state : String?   # Denormalized from customer
  column total : Float64
  column status : String
  column created_at : Time = Time.utc
end

# Example 3: Multi-tenant SaaS with tenant-based regions
class Tenant < Grant::Base
  connection "primary"
  table tenants
  
  # Tenants table is not sharded - it's the control plane
  column id : Int64, primary: true
  column name : String
  column primary_region : String  # Where their data lives
  column compliance_region : String?  # For GDPR, etc.
  column created_at : Time = Time.utc
end

class TenantData < Grant::Base
  connection "primary"
  table tenant_data
  
  include Grant::Sharding::Model
  
  belongs_to tenant : Tenant
  
  # Shard by tenant's region
  shards_by :tenant_region, strategy: :geo,
    regions: [
      {shard: :shard_us, countries: ["US"]},
      {shard: :shard_eu, countries: ["DE", "FR", "GB"]},
      {shard: :shard_apac, countries: ["JP", "SG", "AU"]}
    ]
  
  column id : Int64, primary: true
  column tenant_id : Int64
  column tenant_region : String  # Denormalized from tenant.primary_region
  column key : String
  column value : JSON::Any
  column created_at : Time = Time.utc
  
  before_create :set_tenant_region
  
  private def set_tenant_region
    self.tenant_region = tenant.primary_region
  end
end

# Example 4: Using region context (e.g., from HTTP request)
class PageView < Grant::Base
  connection "primary"
  table page_views
  
  include Grant::Sharding::Model
  
  # Simple region-based sharding
  shards_by :region, strategy: :geo,
    regions: [
      {shard: :shard_us, countries: ["US"]},
      {shard: :shard_eu, countries: ["GB", "DE", "FR", "IT", "ES"]},
      {shard: :shard_asia, countries: ["JP", "CN", "KR", "IN"]}
    ],
    default_shard: :shard_global
  
  column id : Int64, primary: true
  column url : String
  column ip_address : String
  column region : String  # Determined from IP
  column user_agent : String?
  column created_at : Time = Time.utc
end

# Usage Examples:

# 1. Customer registration with explicit region
customer = Customer.create!(
  email: "john@example.com",
  name: "John Doe",
  country: "US",
  state: "CA",
  city: "San Francisco"
)
# Automatically saved to shard_us_west

# 2. Order creation with derived region
order = RegionalOrder.new(
  customer_id: customer.id,
  total: 149.99,
  status: "pending"
)
# Before save, country and state are copied from customer
order.save  # Goes to shard_us_west

# 3. Querying within a region
# Find all California customers (efficient - single shard)
ca_customers = Customer.where(country: "US", state: "CA").select

# Find all US customers (less efficient - queries 3 US shards)
us_customers = Customer.where(country: "US").select

# 4. Using region context in web application
class PageViewController
  def track_page_view(context)
    # Middleware has already set region context based on IP
    Grant::Sharding::RegionDetermination::Context.with(
      country: context.get("geo_country"),
      state: context.get("geo_state")
    ) do
      PageView.create!(
        url: context.request.path,
        ip_address: context.request.remote_address.to_s,
        region: context.get("geo_country"),
        user_agent: context.request.headers["User-Agent"]?
      )
    end
  end
end

# 5. GDPR compliance - query only EU data
def export_eu_customer_data(email : String)
  # Only queries EU shard
  Customer.where(email: email, country: ["GB", "DE", "FR", "IT", "ES"]).first
end

# 6. Regional analytics
def regional_order_totals
  regions = {
    "US West": :shard_us_west,
    "US East": :shard_us_east,
    "Europe": :shard_eu,
    "Asia Pacific": :shard_apac
  }
  
  regions.each do |name, shard|
    total = RegionalOrder.on_shard(shard).where("created_at > ?", 30.days.ago).sum(:total)
    puts "#{name}: $#{total}"
  end
end

# 7. Data residency validation
class GDPRCompliantModel < Grant::Base
  include Grant::Sharding::Model
  
  validate :ensure_eu_data_stays_in_eu
  
  private def ensure_eu_data_stays_in_eu
    eu_countries = ["GB", "DE", "FR", "IT", "ES", "NL", "BE", "PL"]
    if eu_countries.includes?(country) && !current_shard.to_s.includes?("eu")
      errors.add(:country, "EU data must be stored in EU region")
    end
  end
end

puts "Geo sharding example demonstrates regional data partitioning"