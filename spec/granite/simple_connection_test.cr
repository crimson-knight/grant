require "../spec_helper"

# Simple test to verify connection handling works
describe "Basic Connection Handling" do
  it "can register connections with ConnectionRegistry" do
    # Register a test connection
    Granite::ConnectionRegistry.establish_connection(
      database: "test_db", 
      adapter: Granite::Adapter::Sqlite,
      url: "sqlite3::memory:"
    )
    
    # Verify it exists
    Granite::ConnectionRegistry.connection_exists?("test_db").should be_true
    
    # Get the adapter
    adapter = Granite::ConnectionRegistry.get_adapter("test_db")
    adapter.should be_a(Granite::Adapter::Sqlite)
    
    # Clean up
    Granite::ConnectionRegistry.clear_all
  end
  
  it "supports multiple roles" do
    # Register writer and reader
    Granite::ConnectionRegistry.establish_connection(
      database: "multi_role",
      adapter: Granite::Adapter::Sqlite,
      url: "sqlite3::memory:",
      role: :writing
    )
    
    Granite::ConnectionRegistry.establish_connection(
      database: "multi_role",
      adapter: Granite::Adapter::Sqlite, 
      url: "sqlite3::memory:",
      role: :reading
    )
    
    # Both should exist
    Granite::ConnectionRegistry.connection_exists?("multi_role", :writing).should be_true
    Granite::ConnectionRegistry.connection_exists?("multi_role", :reading).should be_true
    
    # Clean up
    Granite::ConnectionRegistry.clear_all
  end
end