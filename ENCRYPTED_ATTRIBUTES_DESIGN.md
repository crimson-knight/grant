# Encrypted Attributes Design Document

## Overview

This document outlines the design and implementation plan for encrypted attributes in Grant ORM. The feature will provide transparent encryption/decryption of sensitive data with support for both non-deterministic (default) and deterministic encryption modes.

## Goals

1. **Transparent Encryption**: Encrypt/decrypt attributes automatically without application code changes
2. **Security First**: Use industry-standard encryption (AES-256-GCM)
3. **Rails Compatibility**: Provide familiar API for Rails developers
4. **Database Agnostic**: Work with all supported databases
5. **Performance**: Minimize overhead with caching and efficient algorithms
6. **Key Management**: Secure and flexible key management system

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                        Application                           │
├─────────────────────────────────────────────────────────────┤
│                    Grant::Base Model                       │
│                  (encrypts :attribute)                       │
├─────────────────────────────────────────────────────────────┤
│              Grant::Encryption::EncryptedAttribute         │
│                 (Handles encrypt/decrypt)                    │
├─────────────────────────────────────────────────────────────┤
│               Grant::Encryption::Cipher                    │
│              (AES-256-GCM implementation)                    │
├─────────────────────────────────────────────────────────────┤
│             Grant::Encryption::KeyProvider                 │
│           (Master key and derived key management)            │
├─────────────────────────────────────────────────────────────┤
│                       Database                               │
│              (Stores encrypted binary data)                  │
└─────────────────────────────────────────────────────────────┘
```

### Core Classes

#### 1. Grant::Encryption Module
Main module that provides the `encrypts` macro and configuration.

#### 2. Grant::Encryption::EncryptedAttribute
Handles the encryption/decryption lifecycle for individual attributes.

#### 3. Grant::Encryption::Cipher
Low-level encryption/decryption using AES-256-GCM.

#### 4. Grant::Encryption::KeyProvider
Manages master keys and derives attribute-specific keys.

#### 5. Grant::Encryption::Config
Global configuration for encryption settings.

## API Design

### Basic Usage

```crystal
class User < Grant::Base
  encrypts :ssn
  encrypts :email, deterministic: true
  encrypts :credit_card_number, key_provider: CustomKeyProvider
end

# Usage remains transparent
user = User.new
user.ssn = "123-45-6789"
user.save  # Automatically encrypted before storage

loaded_user = User.find(user.id)
puts loaded_user.ssn  # Automatically decrypted
```

### Configuration

```crystal
# config/initializers/grant_encryption.cr
Grant::Encryption.configure do |config|
  config.primary_key = ENV["GRANITE_MASTER_KEY"]
  config.deterministic_key = ENV["GRANITE_DETERMINISTIC_KEY"]
  config.key_derivation_salt = ENV["GRANITE_KEY_DERIVATION_SALT"]
  config.support_unencrypted_data = true  # For migrations
end
```

## Implementation Details

### Encryption Process

1. **Non-deterministic (default)**:
   - Generate random IV for each encryption
   - Use AES-256-GCM
   - Store as: `{header}{nonce}{ciphertext}{auth_tag}`
   - Different ciphertext each time for same plaintext

2. **Deterministic**:
   - Derive IV from content hash
   - Use AES-256-GCM
   - Store as: `{header}{ciphertext}{auth_tag}`
   - Same plaintext always produces same ciphertext

### Storage Format

```
┌────────────┬──────────┬──────────────┬──────────┐
│   Header   │  Nonce   │  Ciphertext  │ Auth Tag │
│  (1 byte)  │(12 bytes)│  (variable)  │(16 bytes)│
└────────────┴──────────┴──────────────┴──────────┘

Header bits:
- Bit 0: Version (0 = v1)
- Bit 1: Deterministic flag
- Bits 2-7: Reserved
```

### Key Derivation

```crystal
# Attribute-specific key derivation
attribute_key = HKDF(
  master_key,
  salt: "#{model_name}.#{attribute_name}",
  info: "encryption"
)
```

### Database Storage

- Encrypted attributes stored as `BLOB`/`BYTEA`/`VARBINARY`
- Additional `_encrypted` column stores ciphertext
- Original column becomes virtual getter/setter

### Query Support

```crystal
# Deterministic encryption allows equality searches
User.where(email: "user@example.com")  # Works with deterministic

# Non-deterministic requires special handling
User.where_encrypted(:ssn, "123-45-6789")  # Special method
```

## Security Considerations

### Key Management

1. **Master Key Storage**:
   - Never in code/repository
   - Use environment variables or key management service
   - Support for key rotation

2. **Key Derivation**:
   - Use HKDF for deriving attribute keys
   - Unique key per model/attribute combination
   - Salt prevents rainbow table attacks

3. **Encryption Algorithm**:
   - AES-256-GCM for authenticated encryption
   - Random IV for non-deterministic
   - No ECB mode (prevents pattern analysis)

### Threat Model

Protects against:
- Database breaches (data encrypted at rest)
- SQL injection (encrypted values not useful)
- Insider threats with DB access only

Does NOT protect against:
- Application-level breaches (keys in memory)
- Malicious code with model access
- Key compromise

## Migration Strategy

### Encrypting Existing Data

```crystal
class EncryptUserEmails < Grant::Migration
  def up
    User.find_in_batches do |batch|
      batch.each do |user|
        user.encrypt_attribute!(:email)
        user.save
      end
    end
  end
  
  def down
    User.find_in_batches do |batch|
      batch.each do |user|
        user.decrypt_attribute!(:email)
        user.save
      end
    end
  end
end
```

### Progressive Encryption

```crystal
class User < Grant::Base
  encrypts :email, support_unencrypted: true
  
  # Automatically encrypts on next save
  before_save :ensure_encryption
end
```

## Performance Optimizations

1. **Lazy Decryption**: Only decrypt when accessed
2. **Caching**: Cache decrypted values in memory
3. **Batch Operations**: Optimize for bulk encrypt/decrypt
4. **Index Strategy**: Add partial indexes for deterministic fields

## Testing Strategy

### Unit Tests
- Encryption/decryption correctness
- Key derivation
- Edge cases (nil, empty, binary data)

### Integration Tests
- Model integration
- Query functionality
- Migration helpers

### Security Tests
- Verify encrypted storage
- Test key rotation
- Ensure no plaintext leaks

## Implementation Phases

### Phase 1: Core Encryption (Priority: High)
- Implement Cipher class with AES-256-GCM
- Create KeyProvider for key management
- Basic encrypts macro

### Phase 2: Model Integration (Priority: High)
- EncryptedAttribute class
- Transparent getter/setter
- Dirty tracking support

### Phase 3: Deterministic Encryption (Priority: High)
- Deterministic mode implementation
- Query support for deterministic fields

### Phase 4: Advanced Features (Priority: Medium)
- Key rotation support
- Migration helpers
- Performance optimizations

### Phase 5: Documentation & Polish (Priority: High)
- Security best practices guide
- Migration documentation
- Performance tuning guide

## Dependencies

### Crystal Shards Required
- `openssl` - For AES-256-GCM encryption
- Built-in `crypto` module usage where possible

## Compatibility

### Database Support
- PostgreSQL: `BYTEA` columns
- MySQL: `VARBINARY` or `BLOB` columns  
- SQLite: `BLOB` columns

### Crystal Version
- Requires Crystal 1.0+ for stable crypto APIs

## Future Enhancements

1. **Encryption Schemes**: Support for other algorithms
2. **HSM Integration**: Hardware security module support
3. **Audit Logging**: Track encryption/decryption operations
4. **Field-level Permissions**: Control who can decrypt
5. **Searchable Encryption**: Advanced query capabilities

## References

- Rails ActiveRecord Encryption: https://guides.rubyonrails.org/active_record_encryption.html
- OWASP Cryptographic Storage Cheat Sheet
- AES-GCM specification
- HKDF RFC 5869