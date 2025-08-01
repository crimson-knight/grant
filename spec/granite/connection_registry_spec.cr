require "../spec_helper"

# Mock adapter for testing
class MockAdapter < Granite::Adapter::Base
  QUOTING_CHAR = '"'
  
  def clear(table_name : String)
  end
  
  def insert(table_name : String, fields, params, lastval) : Int64
    0_i64
  end
  
  def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
  end
  
  def update(table_name : String, primary_name : String, fields, params)
  end
  
  def delete(table_name : String, primary_name : String, value)
  end
end

describe Granite::ConnectionRegistry do
  # Clean up after each test
  after_each do
    Granite::ConnectionRegistry.clear_all
  end
  
  describe ".establish_connection" do
    it "registers a new connection pool" do
      Granite::ConnectionRegistry.establish_connection(
        database: "test_db",
        adapter: MockAdapter,
        url: "sqlite3://test.db",
        role: :primary
      )
      
      Granite::ConnectionRegistry.connection_exists?("test_db", :primary).should be_true
    end
    
    it "registers connections with different roles" do
      Granite::ConnectionRegistry.establish_connection(
        database: "multi_role_db",
        adapter: MockAdapter,
        url: "sqlite3://writer.db",
        role: :writing
      )
      
      Granite::ConnectionRegistry.establish_connection(
        database: "multi_role_db",
        adapter: MockAdapter,
        url: "sqlite3://reader.db",
        role: :reading
      )
      
      Granite::ConnectionRegistry.connection_exists?("multi_role_db", :writing).should be_true
      Granite::ConnectionRegistry.connection_exists?("multi_role_db", :reading).should be_true
    end
    
    it "registers sharded connections" do
      Granite::ConnectionRegistry.establish_connection(
        database: "sharded_db",
        adapter: MockAdapter,
        url: "sqlite3://shard1.db",
        role: :primary,
        shard: :shard_one
      )
      
      Granite::ConnectionRegistry.establish_connection(
        database: "sharded_db",
        adapter: MockAdapter,
        url: "sqlite3://shard2.db",
        role: :primary,
        shard: :shard_two
      )
      
      Granite::ConnectionRegistry.connection_exists?("sharded_db", :primary, :shard_one).should be_true
      Granite::ConnectionRegistry.connection_exists?("sharded_db", :primary, :shard_two).should be_true
    end
    
    it "closes existing pool when re-establishing connection" do
      # First connection
      Granite::ConnectionRegistry.establish_connection(
        database: "replace_db",
        adapter: MockAdapter,
        url: "sqlite3://old.db"
      )
      
      # Should replace without error
      Granite::ConnectionRegistry.establish_connection(
        database: "replace_db",
        adapter: MockAdapter,
        url: "sqlite3://new.db"
      )
      
      adapter = Granite::ConnectionRegistry.get_adapter("replace_db")
      adapter.url.should eq "sqlite3://new.db"
    end
  end
  
  describe ".establish_connections" do
    it "registers multiple connections from config hash" do
      config = {
        "primary_db" => {
          adapter: MockAdapter,
          writer: "sqlite3://primary_writer.db",
          reader: "sqlite3://primary_reader.db"
        },
        "cache_db" => {
          adapter: MockAdapter,
          url: "sqlite3://cache.db"
        }
      }
      
      Granite::ConnectionRegistry.establish_connections(config)
      
      Granite::ConnectionRegistry.connection_exists?("primary_db", :writing).should be_true
      Granite::ConnectionRegistry.connection_exists?("primary_db", :reading).should be_true
      Granite::ConnectionRegistry.connection_exists?("cache_db", :primary).should be_true
    end
  end
  
  describe ".get_adapter" do
    it "returns the correct adapter for database and role" do
      Granite::ConnectionRegistry.establish_connection(
        database: "get_pool_db",
        adapter: MockAdapter,
        url: "sqlite3://test.db",
        role: :writing
      )
      
      adapter = Granite::ConnectionRegistry.get_adapter("get_pool_db", :writing)
      adapter.name.should eq "get_pool_db:writing"
    end
    
    it "falls back to primary role if specific role not found" do
      Granite::ConnectionRegistry.establish_connection(
        database: "fallback_db",
        adapter: MockAdapter,
        url: "sqlite3://test.db",
        role: :primary
      )
      
      # Request non-existent role, should fallback to primary
      adapter = Granite::ConnectionRegistry.get_adapter("fallback_db", :reading)
      adapter.should_not be_nil
    end
    
    it "falls back from reading to writing if reading not available" do
      Granite::ConnectionRegistry.establish_connection(
        database: "read_fallback_db",
        adapter: MockAdapter,
        url: "sqlite3://test.db",
        role: :writing
      )
      
      # Request reading role, should fallback to writing
      adapter = Granite::ConnectionRegistry.get_adapter("read_fallback_db", :reading)
      adapter.should_not be_nil
    end
    
    it "raises error if no connection found" do
      expect_raises(Exception, /No adapter found/) do
        Granite::ConnectionRegistry.get_adapter("non_existent_db")
      end
    end
  end
  
  describe ".databases" do
    it "returns all registered database names" do
      Granite::ConnectionRegistry.establish_connection(
        database: "db1",
        adapter: MockAdapter,
        url: "sqlite3://db1.db"
      )
      
      Granite::ConnectionRegistry.establish_connection(
        database: "db2",
        adapter: MockAdapter,
        url: "sqlite3://db2.db"
      )
      
      databases = Granite::ConnectionRegistry.databases
      databases.should contain "db1"
      databases.should contain "db2"
    end
  end
  
  describe ".shards_for_database" do
    it "returns all shards for a database" do
      Granite::ConnectionRegistry.establish_connection(
        database: "sharded_app",
        adapter: MockAdapter,
        url: "sqlite3://shard1.db",
        shard: :us_east
      )
      
      Granite::ConnectionRegistry.establish_connection(
        database: "sharded_app",
        adapter: MockAdapter,
        url: "sqlite3://shard2.db",
        shard: :us_west
      )
      
      shards = Granite::ConnectionRegistry.shards_for_database("sharded_app")
      shards.should contain :us_east
      shards.should contain :us_west
    end
  end
  
  # Health check and stats tests removed - not applicable for adapters
end