require "./probe_support"
require "../../src/grant/sharding"

class GrantAPICardShardedPost < Grant::Base
  table :api_card_sharded_posts
  include Grant::Sharding::Model

  column id : Int64, primary: true
  column tenant_id : Int64

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one}, default_shard: nil
end

def assert_sharded_model_query(value : T) forall T
  {% unless T == Grant::Sharding::ShardedQuery(GrantAPICardShardedPost) %}
    {% raise "Model.on_shard must return a sharded query" %}
  {% end %}
end

assert_sharded_model_query(GrantAPICardShardedPost.on_shard(:one))
