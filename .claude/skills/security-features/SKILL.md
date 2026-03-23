---
name: grant-security-features
description: Grant ORM security features including encrypted attributes, secure tokens, signed IDs, token generators, and data normalization.
user-invocable: false
---

# Grant Security Features

## Encrypted Attributes

Grant provides transparent encryption using AES-256-CBC with HMAC-SHA256 (Encrypt-then-MAC).

### Configuration

```crystal
Grant::Encryption.configure do |config|
  config.primary_key = ENV["GRANT_ENCRYPTION_PRIMARY_KEY"]
  config.deterministic_key = ENV["GRANT_ENCRYPTION_DETERMINISTIC_KEY"]
  config.key_derivation_salt = ENV["GRANT_ENCRYPTION_SALT"]
  config.support_unencrypted_data = true  # Useful during migration
end
```

Generate secure keys:

```crystal
key = Grant::Encryption::Config.generate_key
puts "GRANT_ENCRYPTION_PRIMARY_KEY=#{key}"
```

### Using the encrypts Macro

```crystal
class User < Grant::Base
  connection sqlite
  table users
  column id : Int64, primary: true
  column email : String

  # Non-deterministic (default) -- each encryption produces different ciphertext
  encrypts :ssn
  encrypts :credit_card_number

  # Deterministic -- same plaintext always produces same ciphertext (queryable)
  encrypts :phone_number, deterministic: true
end
```

### Working with Encrypted Attributes

```crystal
user = User.new(email: "john@example.com", ssn: "123-45-6789", phone_number: "+1-555-0123")
user.save!

user.ssn  # => "123-45-6789" (automatically decrypted)

# Update encrypted data
user.ssn = "987-65-4321"
user.save!

# Nil values store nil, no encryption
user.ssn = nil
user.save!
```

### Querying Encrypted Data

**Deterministic fields** can be queried:

```crystal
User.where(phone_number: "+1-555-0123").first
User.find_by(phone_number: "+1-555-0123")
User.where_encrypted(phone_number: "+1-555-0123", status: "active")
```

**Non-deterministic fields** cannot be queried directly (load and filter in memory):

```crystal
users = User.all.select { |u| u.ssn == "123-45-6789" }
```

### Choosing Encryption Type

| Type | Use When | Security | Queryable |
|------|----------|----------|-----------|
| **Non-deterministic** (default) | SSN, credit cards, medical records | Maximum | No |
| **Deterministic** | Email, phone, account numbers you must search | Trade-off (reveals patterns) | Yes |

### Key Rotation

```crystal
Grant::Encryption.configure do |config|
  config.primary_key = new_key
  config.deterministic_key = new_det_key
end

Grant::Encryption::MigrationHelpers.rotate_encryption(
  User, :ssn,
  old_keys: { primary: old_key, deterministic: old_det_key },
  batch_size: 1000
)
```

### Migration Helpers

```crystal
# Encrypt existing plaintext data
Grant::Encryption::MigrationHelpers.encrypt_column(User, :ssn, batch_size: 1000, progress: true)

# Decrypt back to plaintext
Grant::Encryption::MigrationHelpers.decrypt_column(User, :ssn, target_column: :ssn_plain)
```

---

## Secure Tokens

The `Grant::SecureToken` module provides automatic generation of cryptographically secure random tokens.

```crystal
class User < Grant::Base
  include Grant::SecureToken

  has_secure_token :auth_token
  has_secure_token :password_reset_token, length: 36
  has_secure_token :api_key, alphabet: :hex
end
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `length:` | Token length | 24 |
| `alphabet:` | Character set | `:base58` |

Alphabet choices:
- `:base58` (default) -- Bitcoin-style, no confusing characters (0/O, I/l)
- `:hex` -- Hexadecimal
- `:base64` -- URL-safe Base64

### Usage

```crystal
user = User.create(name: "John")
user.auth_token  # => "pX27zsMN2ViQKta1bGfLmVJE" (auto-generated on create)

# Regenerate
user.regenerate_auth_token
user.save
```

---

## Signed IDs

The `Grant::SignedId` module provides tamper-proof, optionally expiring IDs for secure URL generation. Uses HMAC-SHA256 with your application secret.

```crystal
class User < Grant::Base
  include Grant::SignedId
end
```

### Generating and Finding

```crystal
# Generate with purpose (prevents token reuse across contexts)
signed_id = user.signed_id(purpose: :password_reset)

# With expiration
signed_id = user.signed_id(purpose: :password_reset, expires_in: 15.minutes)

# Permanent (no expiration)
signed_id = user.signed_id(purpose: :login_token)

# Find by signed ID
user = User.find_signed(signed_id, purpose: :password_reset)
# Returns nil if expired, tampered, or wrong purpose
```

### Configuration

Set `GRANT_SIGNING_SECRET` environment variable for the signing key:

```bash
export GRANT_SIGNING_SECRET="your-secret-key-here"
```

---

## Token For (Temporary Tokens)

The `Grant::TokenFor` module generates tokens that automatically invalidate when specific data changes.

```crystal
class User < Grant::Base
  include Grant::TokenFor

  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt  # Token invalidates when password_salt changes
  end

  generates_token_for :email_confirmation, expires_in: 24.hours do
    email  # Token invalidates when email changes
  end
end
```

### Usage

```crystal
# Generate
token = user.generate_token_for(:password_reset)
reset_url = "https://example.com/reset?token=#{token}"

# Find (returns nil if expired or data changed)
user = User.find_by_token_for(:password_reset, token)
```

### Use Cases

- Password reset tokens that expire when password changes
- Email confirmation tokens that expire when email changes
- Any temporary access that should invalidate on data change

---

## Complete Security Example

```crystal
class User < Grant::Base
  connection sqlite
  table users

  include Grant::SecureToken
  include Grant::SignedId
  include Grant::TokenFor

  column id : Int64, primary: true
  column name : String
  column email : String
  column password_digest : String
  column password_salt : String

  # Encrypted attributes
  encrypts :ssn
  encrypts :phone_number, deterministic: true

  # Auto-generated tokens
  has_secure_token :auth_token
  has_secure_token :api_key, alphabet: :hex, length: 32

  # Invalidating token generators
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt
  end

  generates_token_for :email_confirmation, expires_in: 24.hours do
    email
  end
end
```

---

## Data Normalization

The `Grant::Normalization` module provides automatic data normalization that runs before validation.

```crystal
class User < Grant::Base
  include Grant::Normalization
  column id : Int64, primary: true
  column email : String?
  column phone : String?

  normalizes :email do |value|
    value.downcase.strip
  end

  normalizes :phone do |value|
    value.gsub(/\D/, "")
  end
end
```

### When Normalizations Run

Normalizations run during validation (via `before_validation`), NOT at assignment time:

```crystal
user = User.new
user.email = "  JOHN@EXAMPLE.COM  "
user.email  # => "  JOHN@EXAMPLE.COM  " (unchanged)

user.valid?
user.email  # => "john@example.com" (normalized after validation)
```

### Conditional Normalization

```crystal
normalizes :website, if: :website_present? do |value|
  value.starts_with?("http") ? value : "https://#{value}"
end
```

### Opting Out

```crystal
user.valid?(skip_normalization: true)
```

### Integration with Dirty Tracking

If normalization returns the value to its original state, the attribute is NOT considered changed:

```crystal
user = User.create(email: "test@example.com")
user.email = "  TEST@EXAMPLE.COM  "
user.email_changed?  # => true

user.valid?
user.email  # => "test@example.com" (normalized back)
user.email_changed?  # => false
```

## Security Best Practices

1. **Never commit encryption keys** to version control -- use environment variables
2. **Use non-deterministic encryption** for highly sensitive data (SSN, credit cards)
3. **Use deterministic encryption only** when you must query the field
4. **Set appropriate expiration times** for signed IDs and token_for (shorter for sensitive ops)
5. **Use purpose scoping** on signed IDs to prevent token reuse
6. **Regenerate tokens** after they are used for sensitive operations
7. **Always use HTTPS** for all token transmission
8. **Backup encryption keys securely** -- without keys, encrypted data is permanently lost
