require "../spec_helper"
require "../../src/grant/encryption"

# Ensure we have the test database
Grant::Adapter::Sqlite.new(name: "sqlite", url: "sqlite3://./spec_test_encryption.db").open do |db|
  db.exec "DROP TABLE IF EXISTS encrypted_users"
  db.exec <<-SQL
    CREATE TABLE encrypted_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email_encrypted TEXT,
      ssn_encrypted TEXT,
      phone_encrypted TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  SQL
end

# Test model with encrypted fields
class EncryptedUser < Grant::Base
  connection sqlite
  table encrypted_users
  
  column id : Int64, primary: true
  column name : String
  
  # Deterministic for searches
  encrypts :email, deterministic: true
  encrypts :phone, deterministic: true
  
  # Non-deterministic for security
  encrypts :ssn
  
  timestamps
end

describe "Grant::Encryption Database Integration" do
  # Use consistent keys for testing
  test_primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
  test_deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
  test_salt = Base64.strict_encode("test_salt_key_32_bytes_long!!!!!".to_slice)
  
  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = test_primary_key
      config.deterministic_key = test_deterministic_key
      config.key_derivation_salt = test_salt
    end
    
    # Connection should already exist from spec_helper
  end
  
  before_each do
    EncryptedUser.clear
  end
  
  describe "database persistence" do
    it "saves and retrieves encrypted data" do
      user = EncryptedUser.new(
        name: "John Doe",
        email: "john@example.com",
        phone: "+1-555-0123",
        ssn: "123-45-6789"
      )
      
      user.save!
      user.persisted?.should be_true
      user.id.should_not be_nil
      
      # Retrieve from database
      retrieved = EncryptedUser.find!(user.id.not_nil!)
      retrieved.name.should eq("John Doe")
      retrieved.email.should eq("john@example.com")
      retrieved.phone.should eq("+1-555-0123")
      retrieved.ssn.should eq("123-45-6789")
    end
    
    it "stores encrypted data in database" do
      user = EncryptedUser.create!(
        name: "Jane Doe",
        email: "jane@example.com",
        ssn: "987-65-4321"
      )
      
      # Query raw database to verify encryption
      adapter = EncryptedUser.adapter
      raw_data = adapter.open do |db|
        db.query_one(
          "SELECT email_encrypted, ssn_encrypted FROM encrypted_users WHERE id = ?",
          user.id.not_nil!,
          as: {String?, String?}
        )
      end
      
      email_encrypted, ssn_encrypted = raw_data
      
      # Data should be encrypted (not readable as plaintext)
      email_encrypted.should_not be_nil
      ssn_encrypted.should_not be_nil
      
      # Encrypted data should be Base64
      email_encrypted.not_nil!.should match(/^[A-Za-z0-9+\/=]+$/)
      ssn_encrypted.not_nil!.should match(/^[A-Za-z0-9+\/=]+$/)
    end
    
    it "queries deterministic encrypted fields" do
      # Create multiple users
      user1 = EncryptedUser.create!(name: "User 1", email: "user1@example.com", phone: "+1-555-0001")
      user2 = EncryptedUser.create!(name: "User 2", email: "user2@example.com", phone: "+1-555-0002")
      user3 = EncryptedUser.create!(name: "User 3", email: "user1@example.com", phone: "+1-555-0003")
      
      # Query by encrypted email
      results = EncryptedUser.where(email: "user1@example.com").select
      results.size.should eq(2)
      results.map(&.id.not_nil!).sort.should eq([user1.id.not_nil!, user3.id.not_nil!].sort)
      
      # Query by encrypted phone
      found = EncryptedUser.find_by(phone: "+1-555-0002")
      found.should_not be_nil
      found.not_nil!.id.should eq(user2.id.not_nil!)
      
      # Use custom query methods
      found = EncryptedUser.find_by_email("user2@example.com")
      found.should_not be_nil
      found.not_nil!.id.should eq(user2.id.not_nil!)
    end
    
    it "handles nil values in database" do
      user = EncryptedUser.create!(name: "No Email User")
      user.email.should be_nil
      user.ssn.should be_nil
      
      # Retrieve and verify nils
      retrieved = EncryptedUser.find!(user.id.not_nil!)
      retrieved.email.should be_nil
      retrieved.ssn.should be_nil
      
      # Update with values
      retrieved.email = "newemail@example.com"
      retrieved.ssn = "555-55-5555"
      retrieved.save!
      
      # Verify update
      updated = EncryptedUser.find!(user.id.not_nil!)
      updated.email.should eq("newemail@example.com")
      updated.ssn.should eq("555-55-5555")
      
      # Set back to nil
      updated.email = nil
      updated.save!
      
      final = EncryptedUser.find!(user.id.not_nil!)
      final.email.should be_nil
    end
    
    # NOTE: Grant doesn't currently support transactions
    # it "works with transactions" do
    #   success = false
    #   
    #   EncryptedUser.transaction do
    #     user1 = EncryptedUser.create!(name: "TX User 1", email: "tx1@example.com")
    #     user2 = EncryptedUser.create!(name: "TX User 2", email: "tx2@example.com")
    #     
    #     # Verify within transaction
    #     EncryptedUser.find_by_email("tx1@example.com").should_not be_nil
    #     EncryptedUser.find_by_email("tx2@example.com").should_not be_nil
    #     
    #     success = true
    #   end
    #   
    #   success.should be_true
    #   
    #   # Verify after transaction
    #   EncryptedUser.find_by_email("tx1@example.com").should_not be_nil
    #   EncryptedUser.find_by_email("tx2@example.com").should_not be_nil
    # end
    # 
    # it "handles rollback correctly" do
    #   initial_count = EncryptedUser.count
    #   
    #   expect_raises(Exception, "Rollback test") do
    #     EncryptedUser.transaction do
    #       EncryptedUser.create!(name: "Rollback User", email: "rollback@example.com")
    #       raise "Rollback test"
    #     end
    #   end
    #   
    #   # Count should be unchanged
    #   EncryptedUser.count.should eq(initial_count)
    #   EncryptedUser.find_by_email("rollback@example.com").should be_nil
    # end
  end
  
  describe "dirty tracking with encryption" do
    it "tracks changes to encrypted attributes" do
      user = EncryptedUser.create!(name: "Track User", email: "original@example.com")
      
      user.email = "new@example.com"
      user.changed?.should be_true
      user.changed_attributes.should contain("email_encrypted")
      
      user.save!
      user.changed?.should be_false
      
      # Previous changes should be tracked
      user.saved_change_to_attribute?("email_encrypted").should be_true
    end
  end
  
  describe "batch operations" do
    it "handles bulk inserts with encryption" do
      users = [] of EncryptedUser
      
      100.times do |i|
        users << EncryptedUser.new(
          name: "Bulk User #{i}",
          email: "bulk#{i}@example.com",
          ssn: "555-00-#{i.to_s.rjust(4, '0')}"
        )
      end
      
      # Save all
      users.each(&.save!)
      
      # Verify count
      EncryptedUser.count.should eq(100)
      
      # Verify random samples
      sample = EncryptedUser.find_by_email("bulk50@example.com")
      sample.should_not be_nil
      sample.not_nil!.ssn.should eq("555-00-0050")
    end
  end
  
  describe "complex queries" do
    it "combines encrypted and non-encrypted fields in queries" do
      user1 = EncryptedUser.create!(name: "Alice", email: "alice@example.com")
      user2 = EncryptedUser.create!(name: "Bob", email: "bob@example.com")
      user3 = EncryptedUser.create!(name: "Alice", email: "alice2@example.com")
      
      # Query by name and encrypted email
      results = EncryptedUser.where(name: "Alice").where(email: "alice@example.com").select
      results.size.should eq(1)
      results.first.id.should eq(user1.id.not_nil!)
      
      # Query with encrypted helper
      results = EncryptedUser.where_encrypted(name: "Alice", email: "alice2@example.com")
      results.size.should eq(1)
      results.first.id.should eq(user3.id.not_nil!)
    end
  end
end