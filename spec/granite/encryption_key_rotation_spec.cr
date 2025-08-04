require "../spec_helper"
require "../../src/granite/encryption"
require "../../src/granite/encryption/migration_helpers"

# Ensure we have the test database
Granite::Adapter::Sqlite.new(name: "sqlite", url: "sqlite3://./spec_test_rotation.db").open do |db|
  db.exec "DROP TABLE IF EXISTS rotation_test_users"
  db.exec <<-SQL
    CREATE TABLE rotation_test_users (
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

# Test model for key rotation
class RotationTestUser < Granite::Base
  connection sqlite
  table rotation_test_users
  
  column id : Int64, primary: true
  column name : String
  
  # Deterministic for searches
  encrypts :email, deterministic: true
  encrypts :phone, deterministic: true
  
  # Non-deterministic for security
  encrypts :ssn
  
  timestamps
end

describe "Granite::Encryption Key Rotation" do
  # Original keys
  original_primary_key = Base64.strict_encode("original_primary_key_32_bytes!!".to_slice)
  original_deterministic_key = Base64.strict_encode("original_determ_key_32_bytes!!!".to_slice)
  original_salt = Base64.strict_encode("original_salt_key_32_bytes!!!!!".to_slice)
  
  # New keys for rotation
  new_primary_key = Base64.strict_encode("new_primary_key_32_bytes!!!!!!!".to_slice)
  new_deterministic_key = Base64.strict_encode("new_determ_key_32_bytes!!!!!!!!".to_slice)
  new_salt = Base64.strict_encode("new_salt_key_32_bytes!!!!!!!!!!".to_slice)
  
  before_all do
    # Set the adapter URL for this test  
    ENV["SQLITE_DATABASE_URL"] = "sqlite3://./spec_test_rotation.db"
    # Connection should already exist from spec_helper
  end
  
  before_each do
    RotationTestUser.clear
    
    # Start with original keys
    Granite::Encryption.configure do |config|
      config.primary_key = original_primary_key
      config.deterministic_key = original_deterministic_key
      config.key_derivation_salt = original_salt
    end
  end
  
  describe "key rotation process" do
    it "rotates encryption keys for all encrypted attributes" do
      # Create test data with original keys
      users = [] of RotationTestUser
      10.times do |i|
        user = RotationTestUser.create!(
          name: "User #{i}",
          email: "user#{i}@example.com",
          phone: "+1-555-#{i.to_s.rjust(4, '0')}",
          ssn: "#{i.to_s.rjust(3, '0')}-12-3456"
        )
        users << user
      end
      
      # Store original values for verification
      original_values = users.map do |user|
        {
          id: user.id,
          email: user.email,
          phone: user.phone,
          ssn: user.ssn
        }
      end
      
      # Configure new keys
      Granite::Encryption.configure do |config|
        config.primary_key = new_primary_key
        config.deterministic_key = new_deterministic_key
        config.key_derivation_salt = new_salt
      end
      
      # Rotate keys for each attribute
      [:email, :phone, :ssn].each do |attribute|
        count = Granite::Encryption::MigrationHelpers.rotate_encryption(
          RotationTestUser,
          attribute,
          old_keys: {
            primary: original_primary_key,
            deterministic: original_deterministic_key
          },
          batch_size: 5,
          progress: false
        )
        
        count.should eq(10)
      end
      
      # Verify all data is still readable with new keys
      original_values.each do |original|
        user = RotationTestUser.find!(original[:id])
        user.email.should eq(original[:email])
        user.phone.should eq(original[:phone])
        user.ssn.should eq(original[:ssn])
      end
      
      # Verify data is NOT readable with old keys
      Granite::Encryption.configure do |config|
        config.primary_key = original_primary_key
        config.deterministic_key = original_deterministic_key
        config.key_derivation_salt = original_salt
      end
      
      # Should fail to decrypt with old keys
      user = RotationTestUser.find!(users.first.id)
      expect_raises(Granite::Encryption::Cipher::DecryptionError) do
        user.email
      end
    end
    
    it "handles nil values during rotation" do
      # Create users with some nil values
      user_with_nil = RotationTestUser.create!(
        name: "No Email User",
        phone: "+1-555-9999"
      )
      
      user_with_values = RotationTestUser.create!(
        name: "Full User",
        email: "full@example.com",
        phone: "+1-555-8888",
        ssn: "999-88-7777"
      )
      
      # Configure new keys
      Granite::Encryption.configure do |config|
        config.primary_key = new_primary_key
        config.deterministic_key = new_deterministic_key
        config.key_derivation_salt = new_salt
      end
      
      # Rotate all attributes
      [:email, :phone, :ssn].each do |attribute|
        Granite::Encryption::MigrationHelpers.rotate_encryption(
          RotationTestUser,
          attribute,
          old_keys: {
            primary: original_primary_key,
            deterministic: original_deterministic_key
          },
          progress: false
        )
      end
      
      # Verify nil values remain nil
      retrieved_nil = RotationTestUser.find!(user_with_nil.id)
      retrieved_nil.email.should be_nil
      retrieved_nil.ssn.should be_nil
      retrieved_nil.phone.should eq("+1-555-9999")
      
      # Verify non-nil values are preserved
      retrieved_full = RotationTestUser.find!(user_with_values.id)
      retrieved_full.email.should eq("full@example.com")
      retrieved_full.phone.should eq("+1-555-8888")
      retrieved_full.ssn.should eq("999-88-7777")
    end
    
    it "maintains deterministic searchability after rotation" do
      # Create users with original keys
      user1 = RotationTestUser.create!(
        name: "Search Test 1",
        email: "search1@example.com",
        phone: "+1-555-1111"
      )
      
      user2 = RotationTestUser.create!(
        name: "Search Test 2",
        email: "search2@example.com",
        phone: "+1-555-2222"
      )
      
      # Verify searching works with original keys
      found = RotationTestUser.find_by_email("search1@example.com")
      found.should_not be_nil
      found.not_nil!.id.should eq(user1.id)
      
      # Configure new keys
      Granite::Encryption.configure do |config|
        config.primary_key = new_primary_key
        config.deterministic_key = new_deterministic_key
        config.key_derivation_salt = new_salt
      end
      
      # Rotate deterministic fields
      [:email, :phone].each do |attribute|
        Granite::Encryption::MigrationHelpers.rotate_encryption(
          RotationTestUser,
          attribute,
          old_keys: {
            primary: original_primary_key,
            deterministic: original_deterministic_key
          },
          progress: false
        )
      end
      
      # Verify searching still works with new keys
      found = RotationTestUser.find_by_email("search1@example.com")
      found.should_not be_nil
      found.not_nil!.id.should eq(user1.id)
      
      # Verify phone search also works
      found = RotationTestUser.find_by_phone("+1-555-2222")
      found.should_not be_nil
      found.not_nil!.id.should eq(user2.id)
      
      # Verify batch queries work
      results = RotationTestUser.where(email: "search2@example.com").select
      results.size.should eq(1)
      results.first.id.should eq(user2.id)
    end
    
    it "handles errors gracefully and restores original keys" do
      # Create test data
      user = RotationTestUser.create!(
        name: "Error Test",
        email: "error@example.com",
        ssn: "111-22-3333"
      )
      
      # Configure new keys
      Granite::Encryption.configure do |config|
        config.primary_key = new_primary_key
        config.deterministic_key = new_deterministic_key
        config.key_derivation_salt = new_salt
      end
      
      # Simulate an error during rotation by providing invalid old keys
      invalid_key = Base64.strict_encode("invalid_key_32_bytes_!!!!!!!!!!!".to_slice)
      
      expect_raises(Granite::Encryption::Cipher::DecryptionError) do
        Granite::Encryption::MigrationHelpers.rotate_encryption(
          RotationTestUser,
          :email,
          old_keys: {
            primary: invalid_key,  # Wrong key will cause decryption to fail
            deterministic: invalid_key
          },
          progress: false
        )
      end
      
      # Verify keys were restored to new keys (as configured)
      Granite::Encryption::KeyProvider.primary_key.should eq(new_primary_key)
      Granite::Encryption::KeyProvider.deterministic_key.should eq(new_deterministic_key)
    end
    
    it "handles batch processing correctly" do
      # Create many users to test batching
      50.times do |i|
        RotationTestUser.create!(
          name: "Batch User #{i}",
          email: "batch#{i}@example.com",
          ssn: "#{i.to_s.rjust(3, '0')}-99-8888"
        )
      end
      
      # Configure new keys
      Granite::Encryption.configure do |config|
        config.primary_key = new_primary_key
        config.deterministic_key = new_deterministic_key
        config.key_derivation_salt = new_salt
      end
      
      # Rotate with small batch size
      count = Granite::Encryption::MigrationHelpers.rotate_encryption(
        RotationTestUser,
        :email,
        old_keys: {
          primary: original_primary_key,
          deterministic: original_deterministic_key
        },
        batch_size: 7,  # Non-divisible batch size to test edge cases
        progress: false
      )
      
      count.should eq(50)
      
      # Verify all records were rotated
      RotationTestUser.all.each_with_index do |user, i|
        user.email.should eq("batch#{i}@example.com")
      end
    end
    
    it "rotates only non-deterministic fields correctly" do
      # Create users
      users = 5.times.map do |i|
        RotationTestUser.create!(
          name: "ND Test #{i}",
          email: "nd#{i}@example.com",
          ssn: "#{i}00-11-2222"
        ).as(RotationTestUser)
      end.to_a
      
      # Configure new keys but keep deterministic key the same
      Granite::Encryption.configure do |config|
        config.primary_key = new_primary_key
        config.deterministic_key = original_deterministic_key  # Keep same
        config.key_derivation_salt = new_salt
      end
      
      # Rotate only non-deterministic field (ssn)
      count = Granite::Encryption::MigrationHelpers.rotate_encryption(
        RotationTestUser,
        :ssn,
        old_keys: {
          primary: original_primary_key,
          deterministic: nil  # Not needed for non-deterministic
        },
        progress: false
      )
      
      count.should eq(5)
      
      # Verify SSN is readable with new key
      users.each_with_index do |original_user, i|
        user = RotationTestUser.find!(original_user.id)
        user.ssn.should eq("#{i}00-11-2222")
      end
      
      # Verify email is still searchable with original deterministic key
      found = RotationTestUser.find_by_email("nd2@example.com")
      found.should_not be_nil
      found.not_nil!.id.should eq(users[2].id)
    end
  end
  
  describe "partial rotation scenarios" do
    it "handles interruption and resume" do
      # Create test data
      20.times do |i|
        RotationTestUser.create!(
          name: "Resume Test #{i}",
          email: "resume#{i}@example.com",
          ssn: "#{i.to_s.rjust(3, '0')}-55-6666"
        )
      end
      
      # Configure new keys
      Granite::Encryption.configure do |config|
        config.primary_key = new_primary_key
        config.deterministic_key = new_deterministic_key
        config.key_derivation_salt = new_salt
      end
      
      # Simulate partial rotation by manually rotating first 10 records
      first_10 = RotationTestUser.limit(10).select
      first_10.each do |user|
        # Decrypt with old key
        Granite::Encryption::KeyProvider.primary_key = original_primary_key
        Granite::Encryption::KeyProvider.deterministic_key = original_deterministic_key
        email_value = user.email
        
        # Re-encrypt with new key
        Granite::Encryption::KeyProvider.primary_key = new_primary_key
        Granite::Encryption::KeyProvider.deterministic_key = new_deterministic_key
        user.email = email_value
        user.save!(validate: false)
      end
      
      # Now run full rotation - it should handle mixed state
      count = Granite::Encryption::MigrationHelpers.rotate_encryption(
        RotationTestUser,
        :email,
        old_keys: {
          primary: original_primary_key,
          deterministic: original_deterministic_key
        },
        progress: false
      )
      
      # Should process all 20, even though 10 were already done
      count.should eq(20)
      
      # Verify all records are readable
      RotationTestUser.all.each_with_index do |user, i|
        user.email.should eq("resume#{i}@example.com")
      end
    end
  end
  
  describe "multi-field rotation" do
    it "rotates multiple fields in a single pass" do
      # Create test data
      10.times do |i|
        RotationTestUser.create!(
          name: "Multi #{i}",
          email: "multi#{i}@example.com",
          phone: "+1-555-#{i.to_s.rjust(4, '0')}",
          ssn: "#{i.to_s.rjust(3, '0')}-77-8888"
        )
      end
      
      # Configure new keys
      Granite::Encryption.configure do |config|
        config.primary_key = new_primary_key
        config.deterministic_key = new_deterministic_key
        config.key_derivation_salt = new_salt
      end
      
      # Rotate all encrypted fields
      total_rotated = 0
      [:email, :phone, :ssn].each do |field|
        count = Granite::Encryption::MigrationHelpers.rotate_encryption(
          RotationTestUser,
          field,
          old_keys: {
            primary: original_primary_key,
            deterministic: original_deterministic_key
          },
          progress: false
        )
        total_rotated += count
      end
      
      total_rotated.should eq(30)  # 10 records × 3 fields
      
      # Verify all fields are accessible
      RotationTestUser.all.each_with_index do |user, i|
        user.email.should eq("multi#{i}@example.com")
        user.phone.should eq("+1-555-#{i.to_s.rjust(4, '0')}")
        user.ssn.should eq("#{i.to_s.rjust(3, '0')}-77-8888")
      end
    end
  end
end