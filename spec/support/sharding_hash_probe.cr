# Prints the shard chosen for a fixed set of keys. Compiled and run by
# spec/grant/sharding/stable_hash_spec.cr in separate processes to prove
# routing does not depend on per-process hash seeding.
require "../../src/grant"
require "../../src/grant/sharding"

resolver = Grant::Sharding::HashResolver.new([:id], 7)
keys = [1_i64, 2_i64, 42_i64, -7_i64, 1_000_000_007_i64, "alice", "bob", "hello world"]
keys.each { |key| puts "#{key}=#{resolver.resolve_for_values([key])}" }
puts "composite=#{resolver.resolve_for_values([5_i64, "abc"])}"
