require "../../spec_helper"

class C01HashModel < Grant::Base
  table c01_hash_models
  column id : Int64, primary: true
  connects_to database: {writing: "c01_hash_primary", reading: "c01_hash_replica"}
end

class C01ShardsModel < Grant::Base
  table c01_shards_models
  column id : Int64, primary: true
  connects_to(
    database: "c01_shard_main",
    shards: {
      default:   {writing: "c01_shard_a", reading: "c01_shard_a_replica"},
      shard_two: {writing: "c01_shard_b", reading: "c01_shard_b_replica"},
    }
  )
end

class C01LegacyConfigModel < Grant::Base
  table c01_legacy_config_models
  column id : Int64, primary: true
  connects_to database: "c01_legacy", config: {writing: "c01_legacy_w", reading: "c01_legacy_r"}
end

class C01PlainModel < Grant::Base
  table c01_plain_models
  column id : Int64, primary: true
end

describe "connects_to database: {writing:, reading:} and shards:" do
  it "takes the role hash as the database argument" do
    C01HashModel.connection_config.should eq({:writing => "c01_hash_primary", :reading => "c01_hash_replica"})
    C01HashModel.default_database_name.should eq "c01_hash_primary"
    C01HashModel.database_name.should eq "c01_hash_primary"
  end

  it "keeps the separate config: argument working" do
    C01LegacyConfigModel.default_database_name.should eq "c01_legacy"
    C01LegacyConfigModel.connection_config[:reading].should eq "c01_legacy_r"
  end

  it "takes shards as a NamedTuple and reports them" do
    C01ShardsModel.shard_keys.should eq [:default, :shard_two]
    C01ShardsModel.default_shard.should eq :default
    C01ShardsModel.sharded?.should be_true
    C01ShardsModel.shard_config[:shard_two][:reading].should eq "c01_shard_b_replica"

    C01PlainModel.shard_keys.should be_empty
    C01PlainModel.default_shard.should eq :default
    C01PlainModel.sharded?.should be_false
  end

  it "lists every connection name a model declares" do
    C01HashModel.connection_names.should eq [
      {"c01_hash_primary", :writing, nil},
      {"c01_hash_replica", :reading, nil},
    ]
    C01ShardsModel.connection_names.should contain({"c01_shard_b_replica", :reading, :shard_two})
    C01PlainModel.connection_names.should eq [{"primary", :writing, nil}]
  end

  describe "eager verification at boot" do
    it "raises naming each connection that is not established" do
      error = expect_raises(Grant::UnestablishedConnectionError) { C01HashModel.verify_connections! }
      error.message.to_s.should contain "c01_hash_primary (role: writing)"
      error.message.to_s.should contain "c01_hash_replica (role: reading)"
      error.message.to_s.should contain "C01HashModel"

      expect_raises(Grant::UnestablishedConnectionError, /shard: shard_two/) do
        C01ShardsModel.verify_connections!
      end
    end

    it "passes once the connections are established" do
      path = File.join(Dir.tempdir, "c01_hash_#{Process.pid}.sqlite3")
      begin
        Grant::ConnectionRegistry.establish_connection(
          database: "c01_hash_primary", adapter: Grant::Adapter::Sqlite,
          url: "sqlite3:#{path}", role: :writing)
        Grant::ConnectionRegistry.establish_connection(
          database: "c01_hash_replica", adapter: Grant::Adapter::Sqlite,
          url: "sqlite3:#{path}", role: :reading)

        C01HashModel.verify_connections!
      ensure
        File.delete?(path)
      end
    end

    it "accepts a reading connection served by the same name's writer" do
      path = File.join(Dir.tempdir, "c01_legacy_#{Process.pid}.sqlite3")
      begin
        Grant::ConnectionRegistry.establish_connection(
          database: "c01_legacy_w", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{path}")
        Grant::ConnectionRegistry.establish_connection(
          database: "c01_legacy_r", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{path}")
        Grant::ConnectionRegistry.establish_connection(
          database: "c01_legacy", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{path}")

        C01LegacyConfigModel.verify_connections!
      ensure
        File.delete?(path)
      end
    end

    it "verifies every declaring model through Grant::ConnectionHandling" do
      Grant::ConnectionHandling.declared_models.should contain "C01ShardsModel"
      expect_raises(Grant::UnestablishedConnectionError, /C01ShardsModel/) do
        Grant::ConnectionHandling.verify_all!
      end
    end
  end
end
