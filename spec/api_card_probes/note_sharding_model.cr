require "./probe_support"
require "../../src/grant/sharding"

class GrantAPICardShardingModelProbe < Grant::Base
  table :api_card_sharding_model_probes
  include Grant::Sharding::Model

  column id : Int64, primary: true
  column tenant_id : Int64

  shards_by :tenant_id, strategy: :hash, count: 2
end

def assert_sharded_model_result(value : T) forall T
  {% unless T == Grant::Sharding::ShardedQuery(GrantAPICardShardingModelProbe) %}
    {% raise "shards_by must create a sharded model query" %}
  {% end %}
end

assert_sharded_model_result(GrantAPICardShardingModelProbe.on_shard(:one))
