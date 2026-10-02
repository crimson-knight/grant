require "../../spec_helper"
require "../../support/crystal_compiler"
require "../../../src/grant/sharding"

describe Grant::Sharding::HashResolver do
  # Golden values computed independently with 64-bit FNV-1a (Python). If one of
  # these changes, persisted rows on existing shards would be misrouted.
  describe "stable routing" do
    it "maps integer keys to pinned hashes and shards" do
      Grant::Sharding::HashResolver.stable_hash(1_i64).should eq(9929646806074584996_u64)
      Grant::Sharding::HashResolver.stable_hash(2_i64).should eq(16626593026977353223_u64)
      Grant::Sharding::HashResolver.stable_hash(42_i64).should eq(18391255480883862255_u64)
      Grant::Sharding::HashResolver.stable_hash(-7_i64).should eq(13809339044719496699_u64)
      Grant::Sharding::HashResolver.stable_hash(Int64::MAX).should eq(10157194460633784765_u64)
    end

    it "maps string keys to pinned hashes" do
      Grant::Sharding::HashResolver.stable_hash("alice").should eq(5803779529149266183_u64)
      Grant::Sharding::HashResolver.stable_hash("bob").should eq(21748447695211092_u64)
      Grant::Sharding::HashResolver.stable_hash("").should eq(14695981039346656037_u64)
      Grant::Sharding::HashResolver.stable_hash("hello world").should eq(8618312879776256743_u64)
    end

    it "pins key to shard for a 4 shard resolver" do
      resolver = Grant::Sharding::HashResolver.new([:id], 4)
      resolver.resolve_for_values([1_i64]).should eq(:shard_0)
      resolver.resolve_for_values([2_i64]).should eq(:shard_3)
      resolver.resolve_for_values([42_i64]).should eq(:shard_3)
      resolver.resolve_for_values(["alice"]).should eq(:shard_3)
      resolver.resolve_for_values(["bob"]).should eq(:shard_0)
    end

    it "hashes Int32 and Int64 keys alike, and canonical integer strings like integers" do
      Grant::Sharding::HashResolver.stable_hash(42_i32).should eq(Grant::Sharding::HashResolver.stable_hash(42_i64))
      Grant::Sharding::HashResolver.stable_hash("42").should eq(Grant::Sharding::HashResolver.stable_hash(42_i64))
      Grant::Sharding::HashResolver.stable_hash("042").should_not eq(Grant::Sharding::HashResolver.stable_hash(42_i64))
    end

    it "hashes composite keys in order with a separator" do
      resolver = Grant::Sharding::HashResolver.new([:a, :b], 7)
      resolver.resolve_for_values([5_i64, "abc"]).should eq(:shard_5)
      resolver.resolve_for_values(["ab", "c"]).should_not be_nil
      Grant::Sharding::HashResolver.stable_hash("ab").should_not eq(Grant::Sharding::HashResolver.stable_hash("a"))
    end

    it "gives identical shards across three separate process runs" do
      probe = File.join(Dir.tempdir, "grant_sharding_hash_probe_#{Process.pid}")
      source = File.expand_path("../../support/sharding_hash_probe.cr", __DIR__)
      begin
        build_output = IO::Memory.new
        status = Process.run(spec_crystal_compiler, ["build", source, "-o", probe], output: build_output, error: build_output)
        status.success?.should be_true, build_output.to_s

        outputs = Array(String).new(3) do
          io = IO::Memory.new
          Process.run(probe, output: io).success?.should be_true
          io.to_s
        end

        outputs.uniq.size.should eq(1)
        expected = <<-OUT
          1=shard_1
          2=shard_6
          42=shard_0
          -7=shard_1
          1000000007=shard_3
          alice=shard_1
          bob=shard_2
          hello world=shard_2
          composite=shard_5

          OUT
        outputs.first.should eq(expected)
      ensure
        File.delete(probe) if File.exists?(probe)
      end
    end
  end
end
