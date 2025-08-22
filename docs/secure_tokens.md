# Secure Tokens and Signed IDs

Grant provides built-in support for secure token generation, signed IDs, and temporary tokens for authentication and security purposes.

## Secure Tokens

The `Grant::SecureToken` module provides automatic generation of cryptographically secure random tokens.

### Basic Usage

```crystal
class User < Grant::Base
  include Grant::SecureToken
  
  has_secure_token :auth_token
  has_secure_token :password_reset_token, length: 36
  has_secure_token :api_key, alphabet: :hex
end

# Tokens are automatically generated on creation
user = User.create(name: "John")
user.auth_token # => "pX27zsMN2ViQKta1bGfLmVJE"

# Regenerate tokens
user.regenerate_auth_token
user.save
```

### Options

- `length`: Token length (default: 24)
- `alphabet`: Character set to use
  - `:base58` (default) - Bitcoin-style alphabet without confusing characters
  - `:hex` - Hexadecimal characters
  - `:base64` - URL-safe Base64

## Signed IDs

The `Grant::SignedId` module provides tamper-proof, optionally expiring IDs for secure URL generation.

### Basic Usage

```crystal
class User < Grant::Base
  include Grant::SignedId
end

# Generate signed ID with purpose
signed_id = user.signed_id(purpose: :password_reset)

# Find by signed ID
user = User.find_signed(signed_id, purpose: :password_reset)
# Returns nil if expired, tampered, or wrong purpose
```

### With Expiration

```crystal
# Generate signed ID that expires in 15 minutes
reset_id = user.signed_id(purpose: :password_reset, expires_in: 15.minutes)

# Permanent signed ID (no expiration)
permanent_id = user.signed_id(purpose: :login_token)
```

### Security

- Signed IDs use HMAC-SHA256 with your application secret
- Purpose scoping prevents token reuse across different contexts
- Set `GRANT_SIGNING_SECRET` environment variable for the signing key

## Token For (Temporary Tokens)

The `Grant::TokenFor` module generates tokens that become invalid when specific data changes.

### Basic Usage

```crystal
class User < Grant::Base
  include Grant::TokenFor
  
  generates_token_for :password_reset, expires_in: 15.minutes do
    # Token becomes invalid if password_salt changes
    password_salt
  end
  
  generates_token_for :email_confirmation, expires_in: 24.hours do
    # Token becomes invalid if email changes
    email
  end
end

# Generate token
token = user.generate_token_for(:password_reset)

# Find by token
user = User.find_by_token_for(:password_reset, token)
# Returns nil if expired or data changed
```

### Use Cases

- Password reset tokens that expire when password changes
- Email confirmation tokens that expire when email changes
- Any temporary access that should invalidate on data change

## Complete Example

```crystal
class User < Grant::Base
  connection sqlite
  table users
  
  include Grant::SecureToken
  include Grant::SignedId
  include Grant::TokenFor
  
  # Columns
  column id : Int64, primary: true
  column name : String
  column email : String
  column password_digest : String
  column password_salt : String
  
  # Secure tokens
  has_secure_token :auth_token
  has_secure_token :api_key, alphabet: :hex, length: 32
  
  # Token generators
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt
  end
  
  generates_token_for :email_confirmation, expires_in: 24.hours do
    email
  end
end

# Usage
user = User.create(
  name: "John Doe",
  email: "john@example.com",
  password_digest: hash_password("secret"),
  password_salt: generate_salt
)

# Automatic token generation
user.auth_token # => "pX27zsMN2ViQKta1bGfLmVJE"
user.api_key    # => "a1b2c3d4e5f6..."

# Password reset flow
reset_token = user.generate_token_for(:password_reset)
reset_url = "https://example.com/reset?token=#{reset_token}"

# Email confirmation
confirm_id = user.signed_id(purpose: :email_confirmation, expires_in: 24.hours)
confirm_url = "https://example.com/confirm?id=#{confirm_id}"

# API authentication
api_user = User.find_by(api_key: request.headers["X-API-Key"])
```

## Security Best Practices

1. **Always set GRANT_SIGNING_SECRET** in production
2. **Use appropriate expiration times** - shorter for sensitive operations
3. **Use purpose scoping** to prevent token reuse
4. **Regenerate tokens** after they're used for sensitive operations
5. **Use HTTPS** for all token transmission

## Environment Configuration

```bash
# Required for signed IDs and token_for
export GRANT_SIGNING_SECRET="your-secret-key-here"
```

Generate a secure secret:
```crystal
require "random/secure"
puts Random::Secure.hex(32)
```