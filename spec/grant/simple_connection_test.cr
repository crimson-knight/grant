require "../spec_helper"

# Simple test to verify connection handling works
describe "Basic Connection Handling" do
  it "can register connections with ConnectionRegistry" do
    # Register a test connection
    Grant::ConnectionRegistry.establish_connection(
      database: "test_db", 
      adapter: Grant::Adapter::Sqlite,
      url: "sqlite3::memory:"
    )
    
    # Verify it exists
    Grant::ConnectionRegistry.connection_exists?("test_db").should be_true
    
    # Get the adapter
    adapter = Grant::ConnectionRegistry.get_adapter("test_db")
    adapter.should be_a(Grant::Adapter::Sqlite)
    
    # Clean up
    Grant::ConnectionRegistry.clear_all
  end
  
  it "supports multiple roles" do
    # Register writer and reader
    Grant::ConnectionRegistry.establish_connection(
      database: "multi_role",
      adapter: Grant::Adapter::Sqlite,
      url: "sqlite3::memory:",
      role: :writing
    )
    
    Grant::ConnectionRegistry.establish_connection(
      database: "multi_role",
      adapter: Grant::Adapter::Sqlite, 
      url: "sqlite3::memory:",
      role: :reading
    )
    
    # Both should exist
    Grant::ConnectionRegistry.connection_exists?("multi_role", :writing).should be_true
    Grant::ConnectionRegistry.connection_exists?("multi_role", :reading).should be_true
    
    # Clean up
    Grant::ConnectionRegistry.clear_all
  end
end