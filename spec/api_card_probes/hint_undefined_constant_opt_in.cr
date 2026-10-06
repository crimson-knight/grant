require "./probe_support"
require "../../src/grant/sharding"

class ShardedProbeRecord < Grant::Base
  include Grant::Sharding::Model

  table :api_card_probe_sharded_records

  column id : Int64, primary: true
end

def assert_sharded_model(value : T) forall T
  {% unless T == ShardedProbeRecord %}
    {% raise "Grant sharding model declarations must preserve the model type" %}
  {% end %}
end

assert_sharded_model(ShardedProbeRecord.new)
