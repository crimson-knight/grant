module Grant::Sharding
  # Resolver for geographic/region-based sharding
  class GeoResolver < ShardResolver
    struct Region
      getter countries : Set(String)
      getter states : Set(String)?
      getter cities : Set(String)?
      getter shard : Symbol
      
      def initialize(@shard : Symbol, countries : Array(String), states : Array(String)? = nil, cities : Array(String)? = nil)
        @countries = countries.map(&.upcase).to_set
        @states = states.try { |s| s.map(&.upcase).to_set }
        @cities = cities.try { |c| c.map(&.upcase).to_set }
      end
      
      def matches?(country : String?, state : String? = nil, city : String? = nil) : Bool
        return false unless country
        
        country_upper = country.upcase
        return false unless @countries.includes?(country_upper)
        
        # If states are defined for this region, must match state
        if states = @states
          if state
            return false unless states.includes?(state.upcase)
          else
            # This region requires state but none provided
            return false
          end
        end
        
        # If cities are defined for this region, must match city
        if cities = @cities
          if city
            return false unless cities.includes?(city.upcase)
          else
            # This region requires city but none provided
            return false
          end
        end
        
        true
      end
    end
    
    @regions : Array(Region)
    @default_shard : Symbol
    
    def initialize(@key_columns : Array(Symbol), 
                   regions : Array(NamedTuple(shard: Symbol, countries: Array(String), states: Array(String)?, cities: Array(String)?)),
                   @default_shard : Symbol = :shard_global)
      @regions = regions.map do |r|
        Region.new(r[:shard], r[:countries], r[:states]?, r[:cities]?)
      end
      validate_configuration!
    end
    
    def resolve(model : Grant::Base) : Symbol
      values = @key_columns.map { |col| model.read_attribute(col.to_s) }
      resolve_for_values(values)
    end
    
    def resolve_for_keys(**keys) : Symbol
      values = @key_columns.map { |col| keys[col]? }
      resolve_for_values(values)
    end
    
    def all_shards : Array(Symbol)
      shards = @regions.map(&.shard).to_set
      shards << @default_shard
      shards.to_a
    end
    
    def resolve_for_values(values : Array) : Symbol
      # Expect values in order: [country, state?, city?]
      country = values[0]?.try(&.to_s)
      state = values[1]?.try(&.to_s) if @key_columns.size > 1
      city = values[2]?.try(&.to_s) if @key_columns.size > 2
      
      # Find first matching region
      region = @regions.find { |r| r.matches?(country, state, city) }
      
      region ? region.shard : @default_shard
    end
    
    private def validate_configuration!
      # Ensure key columns are in expected order
      valid_columns = [:country, :state, :city, :region]
      @key_columns.each_with_index do |col, i|
        unless valid_columns.includes?(col)
          # Also allow custom column names like user_country, merchant_country, etc.
          unless col.to_s.ends_with?("country") || col.to_s.ends_with?("state") || 
                 col.to_s.ends_with?("city") || col.to_s.ends_with?("region")
            raise "Invalid geo shard key column: #{col}. Expected country, state, city, or region (or columns ending with these)"
          end
        end
      end
    end
  end
  
  # Helper module for region determination
  module RegionDetermination
    # Mixin for models that need explicit region fields
    module ExplicitRegion
      macro included
        # Validate region is set before save
        before_save :validate_region_presence
        
        private def validate_region_presence
          # Check if any of the shard key columns are nil
          if self.class.responds_to?(:sharding_config)
            if config = self.class.sharding_config
              config.key_columns.each do |col|
                value = read_attribute(col.to_s)
                if value.nil? || (value.responds_to?(:empty?) && value.empty?)
                  raise "#{col} must be set for geo-sharded models"
                end
              end
            end
          end
        end
      end
    end
    
    # Mixin for models that derive region from associations
    module DerivedRegion
      macro derive_region_from(association, *fields)
        before_create :set_region_from_{{association.id}}
        before_update :set_region_from_{{association.id}}
        
        private def set_region_from_{{association.id}}
          if related = {{association.id}}
            {% for field in fields %}
              self.{{field.id}} = related.{{field.id}}
            {% end %}
          else
            raise "Cannot determine region: {{association.id}} not set"
          end
        end
      end
    end
    
    # Optional context for passing region through the request
    class Context
      @@current = {} of Symbol => String | Nil
      
      def self.with(**attributes, &)
        old = @@current.dup
        attributes.each do |key, value|
          @@current[key] = value
        end
        yield
      ensure
        @@current = old
      end
      
      def self.get(key : Symbol) : String?
        @@current[key]?
      end
      
      def self.clear
        @@current.clear
      end
    end
  end
end