require "../spec_helper"
require "../../src/grant/encryption"

# Test model for encryption features
class EncryptedModel < Grant::Base
  connection sqlite
  table encrypted_models
  
  column id : Int64, primary: true, auto: true
  column created_at : Time = Time.utc
  column updated_at : Time = Time.utc
  
  # Non-deterministic encrypted field
  encrypts :ssn
  
  # Deterministic encrypted field for searching
  encrypts :email, deterministic: true
end

describe Grant::Encryption do
  before_each do
    # Configure encryption
    Grant::Encryption.configure do |config|
      # Generate proper Base64-encoded 32-byte keys
      config.primary_key = Base64.strict_encode(Random::Secure.random_bytes(32))
      config.deterministic_key = Base64.strict_encode(Random::Secure.random_bytes(32))
      config.key_derivation_salt = Base64.strict_encode(Random::Secure.random_bytes(32))
    end
  end
  
  describe "configuration" do
    it "checks if encryption is configured" do
      Grant::Encryption.configured?.should be_true
    end
    
    it "generates a new key" do
      key = Grant::Encryption::Config.generate_key
      key.should_not be_nil
      key.size.should eq(44) # Base64 encoded 32 bytes
    end
  end
  
  describe "encrypts macro" do
    it "creates encrypted columns" do
      EncryptedModel.fields.should contain("ssn_encrypted")
      EncryptedModel.fields.should contain("email_encrypted")
    end
    
    it "provides virtual accessors" do
      model = EncryptedModel.new
      model.responds_to?(:ssn).should be_true
      model.responds_to?(:ssn=).should be_true
      model.responds_to?(:email).should be_true
      model.responds_to?(:email=).should be_true
    end
  end
  
  describe "encryption and decryption" do
    it "encrypts and decrypts non-deterministic fields" do
      model = EncryptedModel.new
      model.ssn = "123-45-6789"
      
      # Should encrypt the value
      model.@ssn_encrypted.should_not be_nil
      model.@ssn_encrypted.not_nil!.size.should be > 0
      
      # Should decrypt back to original
      model.ssn.should eq("123-45-6789")
    end
    
    it "encrypts and decrypts deterministic fields" do
      model = EncryptedModel.new
      model.email = "jane@example.com"
      
      # Should encrypt the value
      model.@email_encrypted.should_not be_nil
      
      # Should decrypt back to original
      model.email.should eq("jane@example.com")
    end
    
    it "handles nil values" do
      model = EncryptedModel.new
      model.ssn = nil
      model.email = nil
      
      model.@ssn_encrypted.should be_nil
      model.@email_encrypted.should be_nil
      model.ssn.should be_nil
      model.email.should be_nil
    end
    
    it "produces different ciphertexts for non-deterministic encryption" do
      model1 = EncryptedModel.new
      model2 = EncryptedModel.new
      
      model1.ssn = "123-45-6789"
      model2.ssn = "123-45-6789"
      
      # Same plaintext should produce different ciphertexts
      model1.@ssn_encrypted.should_not eq(model2.@ssn_encrypted)
    end
    
    it "produces same ciphertext for deterministic encryption" do
      model1 = EncryptedModel.new
      model2 = EncryptedModel.new
      
      model1.email = "same@example.com"
      model2.email = "same@example.com"
      
      # Same plaintext should produce same ciphertext
      model1.@email_encrypted.should eq(model2.@email_encrypted)
    end
  end
  
  describe "querying deterministic fields" do
    it "provides query methods for deterministic fields" do
      EncryptedModel.responds_to?(:where_email).should be_true
      EncryptedModel.responds_to?(:find_by_email).should be_true
    end
    
    it "does not provide query methods for non-deterministic fields" do
      EncryptedModel.responds_to?(:where_ssn).should be_false
      EncryptedModel.responds_to?(:find_by_ssn).should be_false
    end
    
    it "provides encrypted query helpers" do
      EncryptedModel.responds_to?(:where_encrypted).should be_true
      EncryptedModel.responds_to?(:find_by_encrypted).should be_true
    end
  end
  
  describe "caching" do
    it "caches decrypted values" do
      model = EncryptedModel.new
      model.ssn = "999-88-7777"
      
      # First access decrypts
      value1 = model.ssn
      
      # Second access should use cache (we can't directly test this without mocking)
      value2 = model.ssn
      
      value1.should eq(value2)
    end
  end
end