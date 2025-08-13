require "../spec_helper"

# Mock adapter for testing
class MockAdapter < Grant::Adapter::Base
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
  
  def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
    true
  end
  
  def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
    true
  end
  
  def supports_savepoints? : Bool
    true
  end
end

describe Grant::ConnectionRegistry do
  # Clean up after each test
  after_each do
    Grant::ConnectionRegistry.clear_all
  end
  
  describe ".establish_connection" do
    it "registers a new connection pool" do
      Grant::ConnectionRegistry.establish_connection(
        database: "test_db",
        adapter: MockAdapter,
        url: "sqlite3://test.db",
        role: :primary
      )
      
      Grant::ConnectionRegistry.connection_exists?("test_db", :primary).should be_true
    end
    
    it "registers connections with different roles" do
      Grant::ConnectionRegistry.establish_connection(
        database: "multi_role_db",
        adapter: MockAdapter,
        url: "sqlite3://writer.db",
        role: :writing
      )
      
      Grant::ConnectionRegistry.establish_connection(
        database: "multi_role_db",
        adapter: MockAdapter,
        url: "sqlite3://reader.db",
        role: :reading
      )
      
      Grant::ConnectionRegistry.connection_exists?("multi_role_db", :writing).should be_true
      Grant::ConnectionRegistry.connection_exists?("multi_role_db", :reading).should be_true
    end
    
    it "registers sharded connections" do
      Grant::ConnectionRegistry.establish_connection(
        database: "sharded_db",
        adapter: MockAdapter,
        url: "sqlite3://shard1.db",
        role: :primary,
        shard: :shard_one
      )
      
      Grant::ConnectionRegistry.establish_connection(
        database: "sharded_db",
        adapter: MockAdapter,
        url: "sqlite3://shard2.db",
        role: :primary,
        shard: :shard_two
      )
      
      Grant::ConnectionRegistry.connection_exists?("sharded_db", :primary, :shard_one).should be_true
      Grant::ConnectionRegistry.connection_exists?("sharded_db", :primary, :shard_two).should be_true
    end
    
    it "closes existing pool when re-establishing connection" do
      # First connection
      Grant::ConnectionRegistry.establish_connection(
        database: "replace_db",
        adapter: MockAdapter,
        url: "sqlite3://old.db"
      )
      
      # Should replace without error
      Grant::ConnectionRegistry.establish_connection(
        database: "replace_db",
        adapter: MockAdapter,
        url: "sqlite3://new.db"
      )
      
      adapter = Grant::ConnectionRegistry.get_adapter("replace_db")
      # URL now includes pool parameters
      adapter.url.should start_with("sqlite3://new.db?")
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
      
      Grant::ConnectionRegistry.establish_connections(config)
      
      Grant::ConnectionRegistry.connection_exists?("primary_db", :writing).should be_true
      Grant::ConnectionRegistry.connection_exists?("primary_db", :reading).should be_true
      Grant::ConnectionRegistry.connection_exists?("cache_db", :primary).should be_true
    end
  end
  
  describe ".get_adapter" do
    it "returns the correct adapter for database and role" do
      Grant::ConnectionRegistry.establish_connection(
        database: "get_pool_db",
        adapter: MockAdapter,
        url: "sqlite3://test.db",
        role: :writing
      )
      
      adapter = Grant::ConnectionRegistry.get_adapter("get_pool_db", :writing)
      adapter.name.should eq "get_pool_db:writing"
    end
    
    it "falls back to primary role if specific role not found" do
      Grant::ConnectionRegistry.establish_connection(
        database: "fallback_db",
        adapter: MockAdapter,
        url: "sqlite3://test.db",
        role: :primary
      )
      
      # Request non-existent role, should fallback to primary
      adapter = Grant::ConnectionRegistry.get_adapter("fallback_db", :reading)
      adapter.should_not be_nil
    end
    
    it "falls back from reading to writing if reading not available" do
      Grant::ConnectionRegistry.establish_connection(
        database: "read_fallback_db",
        adapter: MockAdapter,
        url: "sqlite3://test.db",
        role: :writing
      )
      
      # Request reading role, should fallback to writing
      adapter = Grant::ConnectionRegistry.get_adapter("read_fallback_db", :reading)
      adapter.should_not be_nil
    end
    
    it "raises error if no connection found" do
      expect_raises(Exception, /No adapter found/) do
        Grant::ConnectionRegistry.get_adapter("non_existent_db")
      end
    end
  end
  
  describe ".databases" do
    it "returns all registered database names" do
      Grant::ConnectionRegistry.establish_connection(
        database: "db1",
        adapter: MockAdapter,
        url: "sqlite3://db1.db"
      )
      
      Grant::ConnectionRegistry.establish_connection(
        database: "db2",
        adapter: MockAdapter,
        url: "sqlite3://db2.db"
      )
      
      databases = Grant::ConnectionRegistry.databases
      databases.should contain "db1"
      databases.should contain "db2"
    end
  end
  
  describe ".shards_for_database" do
    it "returns all shards for a database" do
      Grant::ConnectionRegistry.establish_connection(
        database: "sharded_app",
        adapter: MockAdapter,
        url: "sqlite3://shard1.db",
        shard: :us_east
      )
      
      Grant::ConnectionRegistry.establish_connection(
        database: "sharded_app",
        adapter: MockAdapter,
        url: "sqlite3://shard2.db",
        shard: :us_west
      )
      
      shards = Grant::ConnectionRegistry.shards_for_database("sharded_app")
      shards.should contain :us_east
      shards.should contain :us_west
    end
  end
  
  # Health check and stats tests removed - not applicable for adapters
end