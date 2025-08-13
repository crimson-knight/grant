---
title: "Encrypted Attributes"
category: "advanced"
subcategory: "security"
tags: ["encryption", "security", "aes", "sensitive-data", "gdpr", "compliance", "key-management"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../../core-features/models-and-columns.md", "../../core-features/crud-operations.md"]
related_docs: ["secure-tokens.md", "signed-ids.md", "../data-management/migrations.md"]
last_updated: "2025-01-13"
estimated_read_time: "20 minutes"
use_cases: ["pci-compliance", "gdpr-compliance", "sensitive-data", "healthcare", "financial"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Encrypted Attributes

Comprehensive guide to Grant's transparent encryption system for protecting sensitive data using industry-standard AES-256-GCM encryption with support for both deterministic and non-deterministic encryption modes.

## Overview

Grant provides transparent encryption/decryption of sensitive data attributes, allowing you to protect data at rest while maintaining a seamless development experience. The encryption system uses AES-256-GCM for authenticated encryption and supports both searchable (deterministic) and maximum-security (non-deterministic) encryption modes.

### Key Features

- **Transparent Operation**: Work with encrypted attributes as regular attributes
- **AES-256-GCM**: Authenticated encryption providing confidentiality and integrity
- **Dual Modes**: Non-deterministic (default) and deterministic encryption
- **Query Support**: Search deterministic encrypted fields directly
- **Key Management**: Secure key derivation with HKDF
- **Migration Tools**: Encrypt existing data with zero downtime
- **Performance**: Built-in caching and lazy decryption
- **Database Agnostic**: Works with PostgreSQL, MySQL, and SQLite

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Code                         │
│                  (works with plaintext)                      │
├─────────────────────────────────────────────────────────────┤
│                    Grant::Base Model                         │
│                  (encrypts :attribute)                       │
├─────────────────────────────────────────────────────────────┤
│           Grant::Encryption::EncryptedAttribute              │
│            (transparent encrypt/decrypt layer)               │
├─────────────────────────────────────────────────────────────┤
│               Grant::Encryption::Cipher                      │
│              (AES-256-GCM implementation)                    │
├─────────────────────────────────────────────────────────────┤
│             Grant::Encryption::KeyProvider                   │
│           (HKDF key derivation & management)                 │
├─────────────────────────────────────────────────────────────┤
│                       Database                               │
│            (stores encrypted binary data)                    │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Generate Encryption Keys

```bash
# Generate secure random keys
crystal eval 'require "random/secure"; 3.times { puts Random::Secure.base64(32) }'
```

### 2. Configure Encryption

```crystal
# config/initializers/encryption.cr
Grant::Encryption.configure do |config|
  # Required: Set your encryption keys from environment
  config.primary_key = ENV["GRANT_ENCRYPTION_PRIMARY_KEY"]
  config.deterministic_key = ENV["GRANT_ENCRYPTION_DETERMINISTIC_KEY"]
  config.key_derivation_salt = ENV["GRANT_ENCRYPTION_SALT"]
  
  # Optional: Support unencrypted data during migration
  config.support_unencrypted_data = true  # Set to false in production
end
```

### 3. Add Encrypted Attributes

```crystal
class User < Grant::Base
  connection pg
  table users
  
  column id : Int64, primary: true
  column name : String
  column email : String
  
  # Non-deterministic encryption (maximum security)
  encrypts :ssn
  encrypts :credit_card_number
  encrypts :medical_record
  
  # Deterministic encryption (searchable)
  encrypts :phone_number, deterministic: true
  encrypts :account_number, deterministic: true
end
```

### 4. Use Transparently

```crystal
# Create with encrypted data
user = User.create!(
  name: "John Doe",
  email: "john@example.com",
  ssn: "123-45-6789",
  phone_number: "+1-555-0123"
)

# Read decrypted data
puts user.ssn  # => "123-45-6789" (automatically decrypted)

# Query deterministic fields
found = User.where(phone_number: "+1-555-0123").first
users = User.where(account_number: "ACC-12345").select

# Update encrypted data
user.ssn = "987-65-4321"
user.save!
```

## Encryption Modes

### Non-Deterministic (Default)

Maximum security mode where the same plaintext produces different ciphertext each time:

```crystal
class Patient < Grant::Base
  # Each save produces different ciphertext
  encrypts :medical_history
  encrypts :prescription_notes
  encrypts :test_results
end

patient = Patient.new
patient.medical_history = "Allergies: Penicillin"
patient.save!

# Database stores unique ciphertext each time
# Cannot be used in WHERE clauses
```

**Characteristics:**
- Random IV generated for each encryption
- Same value encrypts differently each time
- Maximum security against cryptanalysis
- Cannot be used in database queries
- Recommended for highly sensitive data

### Deterministic

Searchable mode where the same plaintext always produces the same ciphertext:

```crystal
class Customer < Grant::Base
  # Same value always encrypts identically
  encrypts :email, deterministic: true
  encrypts :tax_id, deterministic: true
  encrypts :phone, deterministic: true
end

# Can query deterministic fields
customer = Customer.find_by_email("john@example.com")
customers = Customer.where(tax_id: "123-45-6789").select

# Works with standard query methods
Customer.where(phone: "+1-555-0123")
Customer.find_by(email: "user@example.com")
```

**Characteristics:**
- Content-derived IV for consistent encryption
- Same value always produces same ciphertext
- Enables database queries and uniqueness constraints
- Vulnerable to frequency analysis
- Use only when searching is required

## Storage Format

Encrypted data is stored in a binary format with metadata:

```
┌────────────┬──────────┬──────────────┬──────────┐
│   Header   │  Nonce   │  Ciphertext  │ Auth Tag │
│  (1 byte)  │(12 bytes)│  (variable)  │(16 bytes)│
└────────────┴──────────┴──────────────┴──────────┘

Header bits:
- Bit 0: Version (0 = v1)
- Bit 1: Deterministic flag
- Bits 2-7: Reserved for future use
```

### Database Column Types

```sql
-- PostgreSQL
ALTER TABLE users ADD COLUMN ssn_encrypted BYTEA;

-- MySQL
ALTER TABLE users ADD COLUMN ssn_encrypted VARBINARY(65535);

-- SQLite
ALTER TABLE users ADD COLUMN ssn_encrypted BLOB;
```

## Key Management

### Key Derivation

Grant uses HKDF (HMAC-based Key Derivation Function) to derive unique keys for each attribute:

```crystal
# Attribute-specific key derivation
attribute_key = HKDF(
  master_key,
  salt: "#{model_name}.#{attribute_name}",
  info: "encryption",
  length: 32
)
```

This ensures:
- Unique key per model/attribute combination
- Key compromise doesn't affect other attributes
- Efficient key generation and caching

### Generating Secure Keys

```crystal
# Helper method to generate keys
require "grant/encryption"

primary_key = Grant::Encryption::Config.generate_key
deterministic_key = Grant::Encryption::Config.generate_key
salt = Grant::Encryption::Config.generate_key

puts "GRANT_ENCRYPTION_PRIMARY_KEY=#{primary_key}"
puts "GRANT_ENCRYPTION_DETERMINISTIC_KEY=#{deterministic_key}"
puts "GRANT_ENCRYPTION_SALT=#{salt}"
```

### Key Rotation

Rotate encryption keys without downtime:

```crystal
# Step 1: Configure new keys
Grant::Encryption.configure do |config|
  config.primary_key = ENV["NEW_PRIMARY_KEY"]
  config.deterministic_key = ENV["NEW_DETERMINISTIC_KEY"]
  config.previous_keys = [
    {
      primary: ENV["OLD_PRIMARY_KEY"],
      deterministic: ENV["OLD_DETERMINISTIC_KEY"]
    }
  ]
end

# Step 2: Re-encrypt data with new keys
Grant::Encryption::MigrationHelpers.rotate_encryption(
  User,
  [:ssn, :credit_card_number],
  batch_size: 1000,
  progress: true
)

# Step 3: Remove old keys from configuration
```

## Querying Encrypted Data

### Deterministic Fields

```crystal
# Standard query methods work
User.where(email: "john@example.com")
User.find_by(phone: "+1-555-0123")

# Dynamic finders
User.find_by_email("john@example.com")
User.where_phone("+1-555-0123")

# Complex queries
users = User.where(
  email: "john@example.com",
  status: "active"  # Mix encrypted and plain columns
).select

# With joins
User.joins(:orders)
    .where(email: "john@example.com")
    .where("orders.total > ?", 100)
```

### Non-Deterministic Fields

```crystal
# Direct queries not supported
# User.where(ssn: "123-45-6789")  # Error!

# Load and filter in memory
users = User.all.select { |u| u.ssn == "123-45-6789" }

# Or use custom search methods
class User < Grant::Base
  def self.find_by_ssn(ssn)
    all.find { |u| u.ssn == ssn }
  end
end
```

### Indexing Strategies

```sql
-- Create index on deterministic encrypted column
CREATE INDEX idx_users_email_encrypted 
ON users(email_encrypted);

-- Partial index for better performance
CREATE INDEX idx_users_active_email 
ON users(email_encrypted) 
WHERE status = 'active';

-- Composite index
CREATE INDEX idx_users_email_created 
ON users(email_encrypted, created_at);
```

## Migration Strategies

### Encrypting Existing Data

```crystal
# Step 1: Add encrypted columns
class AddEncryptedColumns < Grant::Migration
  def up
    alter_table :users do
      add_column :ssn_encrypted, :blob
      add_column :credit_card_encrypted, :blob
    end
  end
end

# Step 2: Enable encryption in model
class User < Grant::Base
  encrypts :ssn
  encrypts :credit_card_number
end

# Step 3: Encrypt existing data
Grant::Encryption::MigrationHelpers.encrypt_column(
  User,
  :ssn,
  source_column: :ssn_plain,
  batch_size: 1000,
  progress: true
)

# Step 4: Verify and remove plaintext columns
class RemovePlaintextColumns < Grant::Migration
  def up
    alter_table :users do
      drop_column :ssn_plain
      drop_column :credit_card_plain
    end
  end
end
```

### Progressive Encryption

Encrypt data gradually as records are updated:

```crystal
class User < Grant::Base
  encrypts :ssn, support_unencrypted: true
  
  before_save :ensure_encryption
  
  private def ensure_encryption
    # Automatically encrypt on next save
    encrypt_attribute!(:ssn) if ssn_changed?
  end
end

# Background job to encrypt remaining data
class EncryptDataJob
  def perform
    User.where_unencrypted(:ssn).find_in_batches do |batch|
      batch.each do |user|
        user.encrypt_attribute!(:ssn)
        user.save!
      end
    end
  end
end
```

### Rolling Back Encryption

```crystal
# Decrypt data back to plaintext
Grant::Encryption::MigrationHelpers.decrypt_column(
  User,
  :ssn,
  target_column: :ssn_plain,
  batch_size: 1000
)

# Remove encryption from model
class User < Grant::Base
  # Remove: encrypts :ssn
  column ssn_plain : String  # Use plaintext column
end
```

## Performance Optimization

### Caching Strategies

```crystal
class User < Grant::Base
  encrypts :profile_data
  
  # Cache decrypted values in memory
  @decrypted_cache = {} of String => String
  
  def profile_data
    @decrypted_cache["profile_data"] ||= super
  end
end
```

### Batch Operations

```crystal
# Efficient bulk encryption
User.transaction do
  User.find_in_batches(batch_size: 1000) do |batch|
    batch.each do |user|
      user.encrypt_attributes!
      user.save!(validate: false)
    end
  end
end

# Selective loading
User.select(:id, :email_encrypted, :created_at)
    .where("created_at > ?", 1.day.ago)
```

### Lazy Decryption

```crystal
# Only decrypt when accessed
class Document < Grant::Base
  encrypts :content, lazy: true
  
  # Content only decrypted when explicitly accessed
  def preview
    content[0..100] if content  # Triggers decryption
  end
end
```

## Security Best Practices

### Key Management

1. **Environment Separation**
   ```crystal
   # Different keys per environment
   config.primary_key = ENV["GRANT_#{ENV["APP_ENV"]}_ENCRYPTION_KEY"]
   ```

2. **Key Storage**
   - Never commit keys to version control
   - Use secret management services (Vault, AWS KMS)
   - Implement key rotation policies
   - Maintain secure key backups

3. **Access Control**
   ```crystal
   class User < Grant::Base
     encrypts :ssn
     
     # Restrict decryption access
     def ssn
       raise "Unauthorized" unless Current.user.admin?
       super
     end
   end
   ```

### Choosing Encryption Mode

**Use Non-Deterministic For:**
- Social Security Numbers
- Credit card numbers
- Medical records
- Financial data
- Personal identification
- Any data not requiring search

**Use Deterministic Only For:**
- Email addresses (when searchable)
- Phone numbers (when searchable)
- Account numbers (when searchable)
- Less sensitive searchable data

### Compliance Considerations

```crystal
# GDPR - Right to be forgotten
class User < Grant::Base
  encrypts :personal_data
  
  def forget!
    self.personal_data = nil
    self.email = "deleted-#{id}@example.com"
    save!
  end
end

# PCI DSS - Credit card encryption
class Payment < Grant::Base
  # Never store full card number
  encrypts :card_last_four, deterministic: true
  encrypts :card_token  # From payment processor
  
  # No CVV storage allowed
  attr_accessor :cvv  # Memory only, never persisted
end

# HIPAA - Medical records
class MedicalRecord < Grant::Base
  encrypts :diagnosis
  encrypts :treatment_notes
  encrypts :prescription_data
  
  # Audit trail for access
  after_find :log_access
end
```

## Advanced Topics

### Custom Key Providers

```crystal
# Integrate with HSM or KMS
class HsmKeyProvider < Grant::Encryption::KeyProvider
  def self.derive_key(model_name : String, attribute_name : String, deterministic : Bool) : Bytes
    # Fetch from Hardware Security Module
    hsm_client = HSM::Client.new(ENV["HSM_ENDPOINT"])
    hsm_client.derive_key(
      master_key_id: ENV["HSM_MASTER_KEY_ID"],
      context: "#{model_name}.#{attribute_name}",
      algorithm: "AES-256-GCM"
    )
  end
end

class SecureDocument < Grant::Base
  encrypts :content, key_provider: HsmKeyProvider
end
```

### Encryption Context

```crystal
# Add authenticated associated data
class Transaction < Grant::Base
  encrypts :amount, context: ->(txn) { 
    "user:#{txn.user_id}:merchant:#{txn.merchant_id}" 
  }
  
  # Context prevents tampering/moving encrypted data
end
```

### Field-Level Encryption Permissions

```crystal
class MedicalRecord < Grant::Base
  encrypts :diagnosis, decrypt_if: ->(record) {
    Current.user.role.in?(["doctor", "nurse"])
  }
  
  encrypts :billing_info, decrypt_if: ->(record) {
    Current.user.role == "billing"
  }
end
```

## Troubleshooting

### Common Issues

**"Primary encryption key not configured"**
- Ensure `Grant::Encryption.configure` is called
- Verify environment variables are set
- Check configuration loads before models

**"Cannot query non-deterministic field"**
- Switch to deterministic encryption for searchable fields
- Or implement in-memory filtering

**"Decryption failed: Invalid authentication tag"**
- Data corrupted or tampered
- Wrong decryption key
- Check `support_unencrypted_data` during migration

**"Deterministic encryption not configured"**
- Set `config.deterministic_key` in configuration
- Ensure different from primary key

### Debugging

```crystal
# Enable verbose logging (development only!)
Grant::Encryption.configure do |config|
  config.verbose_logging = true
end

# Check encryption status
user = User.find(1)
user.encrypted_attribute?(:ssn)  # => true
user.encryption_metadata(:ssn)   # => {mode: :non_deterministic, ...}

# Verify raw encrypted data
raw = User.connection.query_one(
  "SELECT ssn_encrypted FROM users WHERE id = ?",
  1,
  as: Bytes
)
```

## Testing

```crystal
describe User do
  describe "encryption" do
    it "encrypts sensitive data" do
      user = User.create!(ssn: "123-45-6789")
      
      # Verify encrypted in database
      raw = User.connection.query_one(
        "SELECT ssn_encrypted FROM users WHERE id = ?",
        user.id,
        as: Bytes
      )
      
      raw.should_not eq("123-45-6789".to_slice)
      
      # Verify decryption works
      loaded = User.find(user.id)
      loaded.ssn.should eq("123-45-6789")
    end
    
    it "supports deterministic queries" do
      User.create!(email: "test@example.com", deterministic: true)
      
      found = User.find_by_email("test@example.com")
      found.should_not be_nil
    end
    
    it "handles nil values" do
      user = User.create!(ssn: nil)
      user.ssn.should be_nil
    end
  end
end
```

## API Reference

### Model Macros

```crystal
# Define encrypted attribute
encrypts(attribute : Symbol,
  deterministic : Bool = false,
  key_provider : KeyProvider.class? = nil,
  lazy : Bool = false)
```

### Query Methods

```crystal
# For deterministic fields
Model.where_[attribute](value)
Model.find_by_[attribute](value)
Model.where_encrypted(**attributes)

# Check encryption status
model.encrypted_attribute?(attribute)
model.encryption_metadata(attribute)
```

### Migration Helpers

```crystal
# Encrypt existing column
encrypt_column(model, attribute,
  source_column: nil,
  batch_size: 100,
  progress: false)

# Decrypt to plaintext
decrypt_column(model, attribute,
  target_column: nil,
  batch_size: 100)

# Rotate encryption keys
rotate_encryption(model, attributes,
  old_keys: Hash,
  batch_size: 100)
```

## Next Steps

- [Secure Tokens](secure-tokens.md)
- [Signed IDs](signed-ids.md)
- [Migrations](../data-management/migrations.md)
- [Performance Optimization](../performance/query-optimization.md)