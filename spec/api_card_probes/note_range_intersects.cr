require "./probe_support"
require "../../src/grant/sharding"

def assert_range_intersection_result(value : T) forall T
  {% unless T == Bool %}
    {% raise "RangeDefinition#intersects? must return Bool" %}
  {% end %}
end

range = Grant::Sharding::RangeResolver::RangeDefinition.new(1_i64, 10_i64, :one)
assert_range_intersection_result(range.intersects?(1_i64, 5_i64))
assert_range_intersection_result(range.intersects?(1_i64, nil))
