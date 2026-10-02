require "../../spec_helper"
require "../../support/w6_c04_support"
require "../../../src/grant/sharding"

# Connections are declared on the models below before any of them exists, so
# declaring must not consult the registry; the registry is checked once, by an
# explicit boot call.
class W6RegistryThing < Grant::Base
  table w6_registry_things
  column id : Int64, primary: true
  column label : String?
  connects_to database: {writing: "w6_reg_writer", reading: "w6_reg_reader"}
end

class W6RegistryOtherThing < Grant::Base
  table w6_registry_things
  column id : Int64, primary: true
  column label : String?
  connects_to database: "w6_reg_missing_other"
end

# A sharded model whose databases come from connects_to(shards:), not from the
# registry's shard key.
class W6RegistryShardedThing < Grant::Base
  include Grant::Sharding::Model

  table w6_registry_sharded_things
  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String?

  connects_to shards: {
    default: {writing: "w6_reg_default"},
    one:     {writing: "w6_reg_shard_one", reading: "w6_reg_shard_one_r"},
    two:     {writing: "w6_reg_shard_two"},
  }
  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil
end

W6_REG_DDL = ->{ ["CREATE TABLE w6_registry_things (#{W6C04.id_column}, label TEXT)"] }
W6_REG_SHARD_DDL = ->{ ["CREATE TABLE w6_registry_sharded_things (#{W6C04.id_column}, tenant_id BIGINT NOT NULL, label TEXT)"] }

describe "connects_to and the connection registry (#{CURRENT_ADAPTER})" do
  after_all do
    %w(w6_reg_writer w6_reg_reader w6_reg_default w6_reg_shard_one w6_reg_shard_one_r w6_reg_shard_two).each do |name|
      W6C04.remove(name, :writing)
      W6C04.remove(name, :reading)
    end
    W6C04.cleanup
  end

  it "declares connections without consulting the registry" do
    Grant::ConnectionRegistry.connection_exists?("w6_reg_writer", :writing).should be_false
    Grant::ConnectionHandling.declared_models.should contain "W6RegistryThing"
    W6RegistryThing.connection_names.map(&.first).should eq ["w6_reg_writer", "w6_reg_reader"]
  end

  it "verifies one model against the registry on request and names what is missing" do
    error = expect_raises(Grant::UnestablishedConnectionError) { Grant::ConnectionRegistry.verify!(W6RegistryThing) }
    error.message.to_s.should contain "W6RegistryThing"
    error.message.to_s.should contain "w6_reg_writer"
    error.message.to_s.should contain "w6_reg_reader"
  end

  it "verifies every declaring model at once and lists each" do
    error = expect_raises(Grant::UnestablishedConnectionError) { Grant::ConnectionRegistry.verify_all! }
    error.message.to_s.should contain "W6RegistryThing"
    error.message.to_s.should contain "W6RegistryOtherThing"
    error.message.to_s.should contain "w6_reg_missing_other"
  end

  it "passes once the connections exist, without opening a pool" do
    W6C04.provision("w6_reg_writer", W6_REG_DDL.call)
    W6C04.provision("w6_reg_reader", W6_REG_DDL.call)
    writer = W6C04.establish("w6_reg_writer", "w6_reg_writer", :writing)
    reader = W6C04.establish("w6_reg_reader", "w6_reg_reader", :reading)

    Grant::ConnectionRegistry.verify!(W6RegistryThing)
    writer.connected?.should be_false
    reader.connected?.should be_false
  end

  it "routes the declared roles to their own databases" do
    W6C04.exec("w6_reg_writer", "INSERT INTO w6_registry_things (label) VALUES ('writer row')")
    W6C04.exec("w6_reg_reader", "INSERT INTO w6_registry_things (label) VALUES ('reader row')")

    W6RegistryThing.connected_to(role: :writing) { W6RegistryThing.first!.label }.should eq "writer row"
    W6RegistryThing.connected_to(role: :reading) { W6RegistryThing.first!.label }.should eq "reader row"
  end

  describe "a sharded model reading connects_to(shards:)" do
    before_all do
      {"w6_reg_default", "w6_reg_shard_one", "w6_reg_shard_one_r", "w6_reg_shard_two"}.each do |name|
        W6C04.provision(name, W6_REG_SHARD_DDL.call)
        W6C04.establish(name, name, name.ends_with?("_r") ? :reading : :writing)
      end
      W6C04.exec("w6_reg_default", "INSERT INTO w6_registry_sharded_things (tenant_id, label) VALUES (0, 'default row')")
      W6C04.exec("w6_reg_shard_one", "INSERT INTO w6_registry_sharded_things (tenant_id, label) VALUES (1, 'shard one writer')")
      W6C04.exec("w6_reg_shard_one_r", "INSERT INTO w6_registry_sharded_things (tenant_id, label) VALUES (1, 'shard one reader')")
      W6C04.exec("w6_reg_shard_two", "INSERT INTO w6_registry_sharded_things (tenant_id, label) VALUES (2, 'shard two writer')")
    end

    it "exposes the declared shards" do
      W6RegistryShardedThing.shard_keys.should eq [:default, :one, :two]
      W6RegistryShardedThing.default_shard.should eq :default
      W6RegistryShardedThing.sharded?.should be_true
      Grant::ConnectionRegistry.verify!(W6RegistryShardedThing)
    end

    it "reaches each shard's declared database by connected_to(shard:)" do
      W6RegistryShardedThing.connected_to(shard: :one) { W6RegistryShardedThing.order(id: :asc).select.map(&.label) }.should eq ["shard one writer"]
      W6RegistryShardedThing.connected_to(shard: :two) { W6RegistryShardedThing.order(id: :asc).select.map(&.label) }.should eq ["shard two writer"]
    end

    it "reaches a shard's declared reader in the reading role" do
      W6RegistryShardedThing.connected_to(role: :reading, shard: :one) { W6RegistryShardedThing.order(id: :asc).select.map(&.label) }.should eq ["shard one reader"]
    end

    it "serves the :default shard while no shard is active" do
      W6RegistryShardedThing.adapter.url.should start_with W6C04.url("w6_reg_default")
      W6RegistryShardedThing.adapter_for_shard(:default).url.should start_with W6C04.url("w6_reg_default")
      W6RegistryShardedThing.connected_to(shard: :default) { W6RegistryShardedThing.adapter.url }.should start_with W6C04.url("w6_reg_default")
    end

    it "routes a record to the database its key resolves to" do
      W6RegistryShardedThing.new(tenant_id: 2_i64, label: "saved on two").save!

      W6C04.strings("w6_reg_shard_two", "SELECT label FROM w6_registry_sharded_things ORDER BY id").should eq ["shard two writer", "saved on two"]
      W6C04.strings("w6_reg_shard_one", "SELECT label FROM w6_registry_sharded_things ORDER BY id").should eq ["shard one writer"]
    end

    it "does not borrow another connection for a shard with no declared database" do
      expect_raises(Grant::AdapterNotAvailableError) do
        W6RegistryShardedThing.adapter_for_shard(:missing_shard)
      end
    end
  end
end
