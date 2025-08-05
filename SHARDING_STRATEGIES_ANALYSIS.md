# Additional Sharding Strategies Implementation Analysis

## Level of Effort Estimation

### Current Architecture
The current implementation uses a clean strategy pattern with:
- `ResolverBase` as the abstract interface
- `HashResolver` as the concrete implementation
- Clear separation between resolution logic and shard management

### Implementation Effort

**Low-Medium Effort (1-2 days per strategy):**
- The architecture is already well-designed for extensibility
- Each new strategy only needs to implement the `ResolverBase` interface
- Core routing and execution logic remains unchanged

## Range-Based Sharding Strategy

### Implementation Design

```crystal
class RangeResolver < ResolverBase
  struct RangeDefinition
    getter min : Int64
    getter max : Int64
    getter shard : Symbol
    
    def initialize(@min, @max, @shard)
    end
    
    def includes?(value : Int64) : Bool
      value >= @min && value <= @max
    end
  end
  
  @ranges : Array(RangeDefinition)
  
  def initialize(@key_columns : Array(Symbol), ranges : Array(NamedTuple(min: Int64, max: Int64, shard: Symbol)))
    @ranges = ranges.map { |r| RangeDefinition.new(r[:min], r[:max], r[:shard]) }
    validate_ranges!
  end
  
  def resolve_for_values(values : Array) : Symbol
    # For range sharding, typically use first key column only
    value = values.first.as(Int64)
    
    range = @ranges.find { |r| r.includes?(value) }
    range ? range.shard : raise "Value #{value} not in any defined range"
  end
  
  private def validate_ranges!
    # Ensure no gaps or overlaps
    sorted = @ranges.sort_by(&.min)
    sorted.each_cons(2) do |prev, curr|
      if prev.max >= curr.min
        raise "Overlapping ranges: #{prev.max} and #{curr.min}"
      end
    end
  end
end
```

### Usage Example

```crystal
class Order < Granite::Base
  include Granite::Sharding::Model
  
  # Shard by order_id ranges
  shards_by :id, strategy: :range, ranges: [
    {min: 0_i64, max: 999_999_i64, shard: :shard_legacy},
    {min: 1_000_000_i64, max: 4_999_999_i64, shard: :shard_2020},
    {min: 5_000_000_i64, max: 9_999_999_i64, shard: :shard_2023},
    {min: 10_000_000_i64, max: Int64::MAX, shard: :shard_current}
  ]
end
```

### Real-World Benefits
1. **Time-based data archival** - Old orders on slower storage
2. **Predictable growth** - New ranges for future data
3. **Easy maintenance** - Can migrate old ranges to archive
4. **Query optimization** - Date ranges often correlate with ID ranges

## Geo-Based Sharding Strategy

### Implementation Design

```crystal
class GeoResolver < ResolverBase
  struct Region
    getter countries : Set(String)
    getter states : Set(String)?
    getter shard : Symbol
    
    def initialize(@shard, @countries, @states = nil)
    end
  end
  
  @regions : Array(Region)
  @default_shard : Symbol
  
  def initialize(@key_columns : Array(Symbol), regions : Array(NamedTuple), @default_shard = :shard_global)
    @regions = build_regions(regions)
  end
  
  def resolve_for_values(values : Array) : Symbol
    # Expect values like ["US", "CA"] for country, state
    country = values[0].to_s.upcase
    state = values[1]?.try(&.to_s.upcase)
    
    # Find matching region
    region = @regions.find do |r|
      next false unless r.countries.includes?(country)
      
      # If states are defined, must match state too
      if r.states && state
        r.states.includes?(state)
      else
        true
      end
    end
    
    region ? region.shard : @default_shard
  end
end
```

### Usage Example

```crystal
class User < Granite::Base
  include Granite::Sharding::Model
  
  # Shard by user location
  shards_by [:country, :state], strategy: :geo, regions: [
    # US West Coast
    {
      shard: :shard_us_west,
      countries: ["US"],
      states: ["CA", "OR", "WA", "NV", "AZ"]
    },
    # US East Coast
    {
      shard: :shard_us_east,
      countries: ["US"],
      states: ["NY", "NJ", "CT", "MA", "FL", "GA", "VA", "MD", "DC"]
    },
    # US Central (remaining US states)
    {
      shard: :shard_us_central,
      countries: ["US"]
    },
    # Europe
    {
      shard: :shard_eu,
      countries: ["GB", "DE", "FR", "IT", "ES", "NL", "BE", "CH", "AT", "PL"]
    },
    # Asia Pacific
    {
      shard: :shard_apac,
      countries: ["JP", "CN", "KR", "AU", "NZ", "SG", "IN", "TH", "MY", "ID"]
    },
    # Latin America
    {
      shard: :shard_latam,
      countries: ["BR", "MX", "AR", "CO", "CL", "PE", "VE"]
    }
  ]
end
```

### Real-World Use Cases

1. **E-commerce Platforms**
   - Inventory data near fulfillment centers
   - Order processing in regional facilities
   - Reduced latency for regional customers

2. **Social Media Applications**
   - User data in their region for privacy compliance (GDPR, etc.)
   - Content delivery optimization
   - Regional trending calculations

3. **Financial Services**
   - Transaction processing in local regions
   - Regulatory compliance (data residency)
   - Regional reporting and analytics

4. **Gaming Platforms**
   - Player data near game servers
   - Regional leaderboards
   - Matchmaking within regions

### Geo-Sharding Benefits

1. **Latency Reduction**
   - Data physically closer to users
   - Regional caching strategies
   - Faster query response times

2. **Compliance**
   - GDPR requires EU data to stay in EU
   - China requires data localization
   - Industry-specific regulations

3. **Disaster Recovery**
   - Regional failures don't affect global service
   - Easier regional backups
   - Simplified failover strategies

4. **Cost Optimization**
   - Use cheaper regions for archive data
   - Regional pricing strategies
   - Reduced cross-region data transfer costs

## Implementation Checklist

### For Range-Based Sharding (1-2 days)
- [ ] Implement `RangeResolver` class
- [ ] Add range validation logic
- [ ] Support for numeric and date ranges
- [ ] Handle edge cases (gaps, overlaps)
- [ ] Add configuration DSL support
- [ ] Write comprehensive tests
- [ ] Document migration strategies

### For Geo-Based Sharding (2-3 days)
- [ ] Implement `GeoResolver` class
- [ ] Add geo-mapping configuration
- [ ] Support country/state/city hierarchies
- [ ] Handle unknown locations (default shard)
- [ ] Add IP-to-location support (optional)
- [ ] Write comprehensive tests
- [ ] Document compliance considerations

### Additional Strategies to Consider

1. **Consistent Hashing** (2-3 days)
   - For dynamic shard addition/removal
   - Minimal data movement
   - Used by Cassandra, DynamoDB

2. **Custom/Composite** (1 day)
   - Allow user-defined resolver functions
   - Combine multiple strategies
   - Business-specific logic

3. **Directory-Based** (3-4 days)
   - Lookup table for shard mapping
   - Most flexible but requires additional storage
   - Used by YouTube, Facebook

The modular architecture makes adding new strategies straightforward, with most effort spent on strategy-specific logic rather than integration.