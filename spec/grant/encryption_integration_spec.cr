require "../spec_helper"
require "../../src/grant/encryption"

# Create test tables
{% if flag?(:run_migrations) %}
  Grant::Adapter::Sqlite.new(adapter: "sqlite3", database: "./spec_db.db").open do |db|
    db.exec "DROP TABLE IF EXISTS secure_users"
    db.exec <<-SQL
      CREATE TABLE secure_users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        email_encrypted BLOB,
        ssn_encrypted BLOB,
        notes_encrypted BLOB,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    SQL
  end
{% end %}

# Test model with multiple encrypted fields
class SecureUser < Grant::Base
  connection sqlite
  table secure_users
  
  primary id : Int64, auto: true
  
  # Regular field
  column name : String
  
  # Deterministic encrypted field (for lookups)
  encrypts :email, deterministic: true
  
  # Non-deterministic encrypted fields
  encrypts :ssn
  encrypts :notes
  
  column created_at : Time = Time.utc
  column updated_at : Time = Time.utc
  
  # Validation
  validate :name, presence: true
end

describe "Grant::Encryption Integration" do
  before_all do
    # Configure encryption
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.encode(Random::Secure.random_bytes(32)).strip
      config.deterministic_key = Base64.encode(Random::Secure.random_bytes(32)).strip
      config.key_derivation_salt = Base64.encode(Random::Secure.random_bytes(32)).strip
    end
  end
  
  describe "persistence with encryption" do
    it "saves and retrieves encrypted data" do
      user = SecureUser.new(
        name: "John Doe",
        email: "john@example.com",
        ssn: "123-45-6789",
        notes: "Important notes about this user"
      )
      
      user.save!.should be_true
      user.id.should_not be_nil
      
      # Retrieve from database
      retrieved = SecureUser.find!(user.id)
      retrieved.name.should eq("John Doe")
      retrieved.email.should eq("john@example.com")
      retrieved.ssn.should eq("123-45-6789")
      retrieved.notes.should eq("Important notes about this user")
    end
    
    it "stores data as encrypted in database" do
      user = SecureUser.create!(
        name: "Jane Doe",
        email: "jane@example.com",
        ssn: "987-65-4321"
      )
      
      # Check raw database values
      adapter = SecureUser.adapter
      raw_data = adapter.open do |db|
        db.query_one(
          "SELECT email_encrypted, ssn_encrypted FROM secure_users WHERE id = ?",
          user.id,
          as: {Bytes?, Bytes?}
        )
      end
      
      email_encrypted, ssn_encrypted = raw_data
      
      # Encrypted data should exist and not match plaintext
      email_encrypted.should_not be_nil
      ssn_encrypted.should_not be_nil
      
      # Try to decode as string - should fail or be gibberish
      expect_raises(Exception) do
        String.new(email_encrypted.not_nil!)
      end
    end
  end
  
  describe "querying encrypted data" do
    before_each do
      SecureUser.clear
    end
    
    it "finds records by deterministic encrypted fields" do
      user1 = SecureUser.create!(name: "User 1", email: "user1@example.com")
      user2 = SecureUser.create!(name: "User 2", email: "user2@example.com")
      user3 = SecureUser.create!(name: "User 3", email: "user1@example.com") # Same email as user1
      
      # Find by email
      results = SecureUser.where(email: "user1@example.com").select
      results.size.should eq(2)
      results.map(&.id).sort.should eq([user1.id, user3.id].sort)
      
      # Find single record
      found = SecureUser.find_by(email: "user2@example.com")
      found.should_not be_nil
      found.not_nil!.id.should eq(user2.id)
    end
    
    it "supports query methods for deterministic fields" do
      user = SecureUser.create!(name: "Test User", email: "test@example.com")
      
      # Use generated query method
      found = SecureUser.find_by_email("test@example.com")
      found.should_not be_nil
      found.not_nil!.id.should eq(user.id)
      
      # Use where method
      results = SecureUser.where_email("test@example.com").select
      results.size.should eq(1)
      results.first.id.should eq(user.id)
    end
    
    it "raises error when querying non-deterministic fields" do
      expect_raises(ArgumentError, /Cannot query non-deterministic/) do
        SecureUser.where(ssn: "123-45-6789")
      end
    end
  end
  
  describe "data migration" do
    it "encrypts existing plaintext data" do
      # Simulate existing data by directly inserting
      adapter = SecureUser.adapter
      adapter.open do |db|
        db.exec(
          "INSERT INTO secure_users (name, created_at, updated_at) VALUES (?, ?, ?)",
          "Legacy User",
          Time.utc.to_s,
          Time.utc.to_s
        )
      end
      
      # Now encrypt the email field
      user = SecureUser.find_by!(name: "Legacy User")
      user.email = "legacy@example.com"
      user.save!
      
      # Verify it's encrypted
      retrieved = SecureUser.find!(user.id)
      retrieved.email.should eq("legacy@example.com")
    end
  end
  
  describe "nil handling" do
    it "handles nil values correctly" do
      user = SecureUser.create!(name: "No Email User")
      
      user.email.should be_nil
      user.ssn.should be_nil
      user.notes.should be_nil
      
      # Update with nil
      user.email = "temp@example.com"
      user.save!
      user.email = nil
      user.save!
      
      retrieved = SecureUser.find!(user.id)
      retrieved.email.should be_nil
    end
  end
  
  describe "validation with encryption" do
    it "works with model validations" do
      user = SecureUser.new(email: "invalid@example.com")
      user.valid?.should be_false
      user.errors.size.should eq(1)
      user.errors.first.message.should contain("required")
    end
  end
  
  describe "updates and dirty tracking" do
    it "tracks changes to encrypted attributes" do
      user = SecureUser.create!(
        name: "Change Tracker",
        email: "original@example.com"
      )
      
      user.email = "new@example.com"
      user.changed?.should be_true
      user.changed_attributes.should contain("email_encrypted")
      
      user.save!
      user.changed?.should be_false
    end
  end
  
  describe "concurrent access" do
    it "handles concurrent reads correctly" do
      user = SecureUser.create!(
        name: "Concurrent User",
        email: "concurrent@example.com",
        ssn: "555-55-5555"
      )
      
      # Simulate concurrent access
      fibers = [] of Fiber
      results = [] of String?
      
      10.times do
        fibers << spawn do
          retrieved = SecureUser.find!(user.id)
          results << retrieved.email
        end
      end
      
      fibers.each(&.join)
      
      # All results should be the same
      results.uniq.size.should eq(1)
      results.first.should eq("concurrent@example.com")
    end
  end
end