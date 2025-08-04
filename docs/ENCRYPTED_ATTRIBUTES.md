# Encrypted Attributes for Grant

Grant provides transparent encryption for sensitive data in your models using industry-standard AES-256-GCM encryption. This feature allows you to encrypt specific attributes while maintaining the ability to query deterministic fields.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Using Encrypted Attributes](#using-encrypted-attributes)
- [Querying Encrypted Data](#querying-encrypted-data)
- [Migration Guide](#migration-guide)
- [Security Best Practices](#security-best-practices)
- [Advanced Topics](#advanced-topics)

## Overview

### Features

- **Transparent encryption/decryption** - Work with encrypted attributes as if they were regular attributes
- **AES-256-GCM encryption** - Industry-standard authenticated encryption
- **Deterministic and non-deterministic encryption** - Choose based on your needs
- **Query support** - Search deterministic encrypted fields
- **Key rotation** - Rotate encryption keys without downtime
- **Migration helpers** - Easily encrypt existing data
- **Performance optimization** - Built-in caching for decrypted values

### How It Works

1. You mark attributes as encrypted using the `encrypts` macro
2. Grant automatically creates an encrypted column to store the ciphertext
3. Virtual accessors handle encryption/decryption transparently
4. Deterministic fields can be queried like regular fields
5. All encryption uses derived keys specific to each model and attribute

## Quick Start

### 1. Configure Encryption Keys

```crystal
# config/initializers/encryption.cr
Granite::Encryption.configure do |config|
  # Required: Set your encryption keys (use secure random values in production!)
  config.primary_key = ENV["GRANITE_ENCRYPTION_PRIMARY_KEY"]
  config.deterministic_key = ENV["GRANITE_ENCRYPTION_DETERMINISTIC_KEY"]
  config.key_derivation_salt = ENV["GRANITE_ENCRYPTION_SALT"]
  
  # Optional: Support reading unencrypted data during migration
  config.support_unencrypted_data = true
end
```

### 2. Add Encrypted Attributes to Your Model

```crystal
class User < Granite::Base
  connection sqlite
  table users
  
  column id : Int64, primary: true
  column email : String
  column created_at : Time = Time.utc
  
  # Encrypt sensitive data (non-deterministic by default)
  encrypts :ssn
  encrypts :credit_card_number
  
  # Use deterministic encryption for fields you need to query
  encrypts :phone_number, deterministic: true
end
```

### 3. Use Encrypted Attributes

```crystal
# Create a user with encrypted data
user = User.new(
  email: "john@example.com",
  ssn: "123-45-6789",
  phone_number: "+1-555-0123"
)
user.save!

# Read encrypted data (automatically decrypted)
puts user.ssn # => "123-45-6789"

# Query deterministic fields
found = User.where(phone_number: "+1-555-0123").first
found = User.find_by_phone_number("+1-555-0123")

# Update encrypted data
user.ssn = "987-65-4321"
user.save!
```

## Configuration

### Generating Secure Keys

```crystal
# Generate random keys for your configuration
primary_key = Granite::Encryption::Config.generate_key
deterministic_key = Granite::Encryption::Config.generate_key
salt = Granite::Encryption::Config.generate_key

puts "GRANITE_ENCRYPTION_PRIMARY_KEY=#{primary_key}"
puts "GRANITE_ENCRYPTION_DETERMINISTIC_KEY=#{deterministic_key}"
puts "GRANITE_ENCRYPTION_SALT=#{salt}"
```

### Configuration Options

```crystal
Granite::Encryption.configure do |config|
  # Primary key for non-deterministic encryption (required)
  config.primary_key = "your-base64-encoded-32-byte-key"
  
  # Key for deterministic encryption (required if using deterministic fields)
  config.deterministic_key = "your-base64-encoded-32-byte-key"
  
  # Salt for key derivation (required)
  config.key_derivation_salt = "your-base64-encoded-salt"
  
  # Support reading unencrypted data (useful during migration)
  config.support_unencrypted_data = false
  
  # Enable verbose logging (for debugging only!)
  config.verbose_logging = false
end
```

## Using Encrypted Attributes

### Basic Encryption

```crystal
class Patient < Granite::Base
  connection sqlite
  table patients
  
  column id : Int64, primary: true
  column name : String
  
  # Non-deterministic encryption (default)
  # Each encryption produces different ciphertext
  encrypts :medical_history
  encrypts :notes
end

patient = Patient.new(name: "Jane Doe")
patient.medical_history = "Allergic to penicillin"
patient.save!

# The actual database stores encrypted data
# patient.medical_history_encrypted contains the ciphertext
```

### Deterministic Encryption

```crystal
class Customer < Granite::Base
  connection sqlite
  table customers
  
  column id : Int64, primary: true
  
  # Deterministic encryption for searchable fields
  # Same plaintext always produces same ciphertext
  encrypts :email, deterministic: true
  encrypts :tax_id, deterministic: true
end

# Can query deterministic fields
customer = Customer.find_by_email("john@example.com")
customers = Customer.where(tax_id: "123-45-6789").select
```

### Working with Nil Values

```crystal
user = User.new
user.ssn = nil # Stores nil, no encryption
user.save!

user.ssn # => nil
user.ssn = "123-45-6789"
user.ssn = nil # Can set back to nil
```

## Querying Encrypted Data

### Deterministic Fields

```crystal
# These methods are automatically available for deterministic fields
User.where_email("john@example.com")
User.find_by_email("john@example.com")

# Standard query methods work too
User.where(email: "john@example.com")
User.find_by(email: "john@example.com")

# For complex queries, use where_encrypted
users = User.where_encrypted(
  email: "john@example.com",
  status: "active" # Mix encrypted and regular fields
)
```

### Non-Deterministic Fields

```crystal
# Cannot query non-deterministic fields directly
# This will raise an error:
# User.where(ssn: "123-45-6789") # Error!

# Instead, load records and filter in memory
users = User.all.select { |u| u.ssn == "123-45-6789" }
```

## Migration Guide

### Encrypting Existing Data

```crystal
# 1. Add the encrypted attribute to your model
class User < Granite::Base
  encrypts :ssn
end

# 2. Create a migration to add the encrypted column
class AddEncryptedSsnToUsers < Granite::Migration
  def up
    alter_table :users do
      add_column :ssn_encrypted, :blob
    end
  end
  
  def down
    alter_table :users do
      drop_column :ssn_encrypted
    end
  end
end

# 3. Encrypt existing data
Granite::Encryption::MigrationHelpers.encrypt_column(
  User,
  :ssn,
  batch_size: 1000,
  progress: true
)

# 4. Remove the original column (after verification)
class RemovePlaintextSsn < Granite::Migration
  def up
    alter_table :users do
      drop_column :ssn
    end
  end
end
```

### Key Rotation

```crystal
# 1. Set new keys in configuration
Granite::Encryption.configure do |config|
  config.primary_key = new_primary_key
  config.deterministic_key = new_deterministic_key
end

# 2. Rotate encrypted data
Granite::Encryption::MigrationHelpers.rotate_encryption(
  User,
  :ssn,
  old_keys: {
    primary: old_primary_key,
    deterministic: old_deterministic_key
  },
  batch_size: 1000,
  progress: true
)
```

### Rolling Back Encryption

```crystal
# Decrypt data back to plaintext column
Granite::Encryption::MigrationHelpers.decrypt_column(
  User,
  :ssn,
  target_column: :ssn_plain,
  batch_size: 1000
)
```

## Security Best Practices

### Key Management

1. **Never commit keys to version control**
   ```crystal
   # Bad - never do this!
   config.primary_key = "hardcoded-key-value"
   
   # Good - use environment variables
   config.primary_key = ENV["GRANITE_ENCRYPTION_PRIMARY_KEY"]
   ```

2. **Use a key management service in production**
   - AWS KMS, HashiCorp Vault, or similar
   - Rotate keys regularly
   - Separate keys per environment

3. **Backup your keys securely**
   - Without keys, encrypted data is permanently lost
   - Store backups in a separate secure location

### Choosing Encryption Type

- **Use non-deterministic encryption (default) for:**
  - Highly sensitive data (SSN, credit cards, medical records)
  - Data you don't need to search by
  - Maximum security

- **Use deterministic encryption only for:**
  - Fields you must query (email, phone, account numbers)
  - Less sensitive data where searchability is required
  - Understand the security tradeoffs

### Security Considerations

1. **Deterministic encryption reveals patterns**
   - Same values encrypt to same ciphertext
   - Vulnerable to frequency analysis
   - Use only when necessary

2. **Encryption is not a silver bullet**
   - Protect your keys
   - Use HTTPS/TLS for data in transit
   - Implement proper access controls
   - Regular security audits

3. **Performance impact**
   - Encryption/decryption has CPU cost
   - Consider caching strategies
   - Index encrypted columns appropriately

## Advanced Topics

### Custom Key Providers

```crystal
class CustomKeyProvider < Granite::Encryption::KeyProvider
  def self.derive_key(model_name : String, attribute_name : String, deterministic : Bool) : Bytes
    # Custom key derivation logic
    # e.g., fetch from HSM, KMS, etc.
  end
end

# Use in model
class SecureModel < Granite::Base
  encrypts :data, key_provider: CustomKeyProvider
end
```

### Encryption Context

```crystal
# Future feature - add additional authenticated data
encrypts :medical_record, context: ->(record) { "patient_id:#{record.patient_id}" }
```

### Partial Encryption

```crystal
# Encrypt only part of a field (future feature)
encrypts :credit_card, partial: {
  mask: ->(value) { "****-****-****-#{value[-4..]}" },
  unmask: ->(masked, encrypted) { encrypted }
}
```

## Troubleshooting

### Common Issues

1. **"Primary encryption key not configured"**
   - Ensure you've set up encryption configuration
   - Check environment variables are loaded

2. **"Cannot query non-deterministic encrypted field"**
   - Use deterministic encryption for searchable fields
   - Or load and filter records in memory

3. **"Decryption failed"**
   - Check if using correct keys
   - Enable support_unencrypted_data during migration
   - Verify data wasn't corrupted

### Performance Optimization

```crystal
# Batch operations for better performance
User.transaction do
  users.each do |user|
    user.update!(ssn: encrypt_ssn(user.raw_ssn))
  end
end

# Use select to load only needed columns
User.select(:id, :email, :ssn_encrypted).each do |user|
  # Process user
end
```

## API Reference

### Model Macros

- `encrypts(attribute, deterministic: false)` - Define an encrypted attribute

### Query Methods (for deterministic fields)

- `Model.where_[attribute](value)` - Find by encrypted attribute
- `Model.find_by_[attribute](value)` - Find first by encrypted attribute
- `Model.where_encrypted(**attrs)` - Query with mixed encrypted/plain fields

### Migration Helpers

- `encrypt_column(model, attribute, batch_size: 100)` - Encrypt existing data
- `decrypt_column(model, attribute, target_column: nil)` - Decrypt to plaintext
- `rotate_encryption(model, attribute, old_keys:)` - Rotate encryption keys

### Configuration

- `Granite::Encryption.configure(&block)` - Configure encryption settings
- `Granite::Encryption.configured?` - Check if properly configured
- `Granite::Encryption::Config.generate_key` - Generate a secure key

## License

This feature is part of Grant and follows the same license terms.