require "./probe_support"
require "../../src/grant/sharding"

def assert_geo_resolver(value : T) forall T
  {% unless T == Grant::Sharding::GeoResolver %}
    {% raise "GeoResolver.new must return GeoResolver" %}
  {% end %}
end

regions = [{shard: :us, countries: ["US"], states: nil, cities: nil}]
assert_geo_resolver(Grant::Sharding::GeoResolver.new([:country], regions))
