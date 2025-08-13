---
title: "Secure Tokens"
category: "advanced"
subcategory: "security"
tags: ["security", "tokens", "authentication", "api-keys", "jwt", "sessions", "cryptography"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../../core-features/models-and-columns.md", "encrypted-attributes.md"]
related_docs: ["signed-ids.md", "encrypted-attributes.md", "../../core-features/callbacks-lifecycle.md"]
last_updated: "2025-01-13"
estimated_read_time: "18 minutes"
use_cases: ["authentication", "api-access", "password-reset", "email-verification", "session-management"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Secure Tokens

Comprehensive guide to implementing secure token systems in Grant for authentication, API keys, session management, and temporary access tokens with cryptographic security.

## Overview

Secure tokens are essential for modern web applications, providing:
- User authentication and sessions
- API key management
- Password reset tokens
- Email verification links
- Temporary access grants
- OAuth/JWT integration

Grant provides built-in support for generating, storing, and validating secure tokens with proper cryptographic practices.

## Basic Token Implementation

### Simple Secure Tokens

```crystal
require "random/secure"
require "digest/sha256"

class User < Grant::Base
  column id : Int64, primary: true
  column email : String
  column password_digest : String
  
  # Token columns
  column api_key : String?
  column api_key_digest : String?
  column reset_token_digest : String?
  column reset_token_sent_at : Time?
  column confirmation_token_digest : String?
  column confirmed_at : Time?
  
  # Generate API key
  def generate_api_key!
    raw_token = Random::Secure.hex(32)
    self.api_key_digest = Digest::SHA256.hexdigest(raw_token)
    self.api_key = raw_token  # Return once, don't store
    save!
    raw_token
  end
  
  # Verify API key
  def self.find_by_api_key(key : String) : User?
    digest = Digest::SHA256.hexdigest(key)
    find_by(api_key_digest: digest)
  end
  
  # Password reset token
  def generate_reset_token!
    raw_token = Random::Secure.urlsafe_base64(32)
    self.reset_token_digest = Digest::SHA256.hexdigest(raw_token)
    self.reset_token_sent_at = Time.utc
    save!
    raw_token
  end
  
  # Find and validate reset token
  def self.find_by_reset_token(token : String) : User?
    digest = Digest::SHA256.hexdigest(token)
    user = find_by(reset_token_digest: digest)
    
    # Check token expiry (2 hours)
    if user && user.reset_token_sent_at
      if Time.utc - user.reset_token_sent_at.not_nil! > 2.hours
        return nil
      end
    end
    
    user
  end
  
  # Clear reset token after use
  def clear_reset_token!
    self.reset_token_digest = nil
    self.reset_token_sent_at = nil
    save!
  end
end
```

### Token Module

```crystal
module SecureToken
  extend self
  
  # Generate cryptographically secure token
  def generate(length : Int32 = 32) : String
    Random::Secure.urlsafe_base64(length)
  end
  
  # Generate with prefix (like GitHub tokens)
  def generate_with_prefix(prefix : String, length : Int32 = 32) : String
    "#{prefix}_#{generate(length)}"
  end
  
  # Hash token for storage
  def digest(token : String) : String
    Digest::SHA256.hexdigest(token)
  end
  
  # Time-limited token
  def generate_expiring(expires_in : Time::Span) : {String, Time}
    token = generate()
    expires_at = Time.utc + expires_in
    {token, expires_at}
  end
  
  # Verify token format
  def valid_format?(token : String, prefix : String? = nil) : Bool
    return false if token.empty?
    
    if prefix
      return false unless token.starts_with?("#{prefix}_")
    end
    
    # Check base64 format
    token.matches?(/^[A-Za-z0-9_-]+$/)
  end
end

class AccessToken < Grant::Base
  column id : Int64, primary: true
  column user_id : Int64
  column token_digest : String
  column name : String?
  column scopes : Array(String) = [] of String,
    converter: Grant::Converters::Json(Array(String))
  column expires_at : Time?
  column last_used_at : Time?
  column created_at : Time = Time.utc
  
  belongs_to :user
  
  # Class method to create token
  def self.create_for_user(user : User, name : String? = nil, scopes : Array(String) = [] of String, expires_in : Time::Span? = nil) : {AccessToken, String}
    raw_token = SecureToken.generate(48)
    
    token = new(
      user_id: user.id,
      token_digest: SecureToken.digest(raw_token),
      name: name,
      scopes: scopes,
      expires_at: expires_in ? Time.utc + expires_in : nil
    )
    token.save!
    
    {token, raw_token}
  end
  
  # Find and validate token
  def self.authenticate(raw_token : String) : AccessToken?
    digest = SecureToken.digest(raw_token)
    token = find_by(token_digest: digest)
    
    return nil unless token
    return nil if token.expired?
    
    # Update last used
    token.touch_last_used!
    token
  end
  
  def expired? : Bool
    expires_at ? Time.utc > expires_at : false
  end
  
  def touch_last_used!
    update!(last_used_at: Time.utc)
  end
  
  def has_scope?(scope : String) : Bool
    scopes.includes?("*") || scopes.includes?(scope)
  end
end
```

## Session Tokens

### Database Sessions

```crystal
class Session < Grant::Base
  column id : Int64, primary: true
  column user_id : Int64
  column token_digest : String
  column ip_address : String
  column user_agent : String?
  column data : JSON::Any = JSON.parse("{}"),
    converter: Grant::Converters::Json(JSON::Any)
  column expires_at : Time
  column created_at : Time = Time.utc
  column last_activity_at : Time = Time.utc
  
  belongs_to :user
  
  # Session configuration
  SESSION_LIFETIME = 30.days
  IDLE_TIMEOUT = 2.hours
  
  def self.create_for_user(user : User, ip : String, user_agent : String? = nil) : {Session, String}
    raw_token = SecureToken.generate(64)
    
    session = new(
      user_id: user.id,
      token_digest: SecureToken.digest(raw_token),
      ip_address: ip,
      user_agent: user_agent,
      expires_at: Time.utc + SESSION_LIFETIME
    )
    session.save!
    
    {session, raw_token}
  end
  
  def self.authenticate(raw_token : String) : Session?
    return nil if raw_token.empty?
    
    digest = SecureToken.digest(raw_token)
    session = find_by(token_digest: digest)
    
    return nil unless session
    return nil if session.expired?
    return nil if session.idle_timeout?
    
    session.touch!
    session
  end
  
  def expired? : Bool
    Time.utc > expires_at
  end
  
  def idle_timeout? : Bool
    Time.utc - last_activity_at > IDLE_TIMEOUT
  end
  
  def touch!
    update!(last_activity_at: Time.utc)
  end
  
  def revoke!
    update!(expires_at: Time.utc)
  end
  
  # Store session data
  def set(key : String, value : JSON::Any::Type)
    data_hash = data.as_h
    data_hash[key] = JSON::Any.new(value)
    self.data = JSON::Any.new(data_hash)
    save!
  end
  
  def get(key : String) : JSON::Any?
    data[key]?
  end
  
  # Cleanup old sessions
  def self.cleanup_expired
    where.lt(:expires_at, Time.utc).delete_all
    where.lt(:last_activity_at, Time.utc - IDLE_TIMEOUT).delete_all
  end
end
```

### Remember Me Tokens

```crystal
class RememberToken < Grant::Base
  column id : Int64, primary: true
  column user_id : Int64
  column token_digest : String
  column device_name : String?
  column expires_at : Time
  column created_at : Time = Time.utc
  
  belongs_to :user
  
  LIFETIME = 90.days
  
  def self.create_for_user(user : User, device : String? = nil) : String
    raw_token = SecureToken.generate(64)
    selector = SecureToken.generate(16)
    
    # Store selector:token format
    full_token = "#{selector}:#{raw_token}"
    
    create!(
      user_id: user.id,
      token_digest: SecureToken.digest(full_token),
      device_name: device,
      expires_at: Time.utc + LIFETIME
    )
    
    full_token
  end
  
  def self.authenticate(full_token : String) : User?
    return nil unless full_token.includes?(":")
    
    digest = SecureToken.digest(full_token)
    token = find_by(token_digest: digest)
    
    return nil unless token
    return nil if Time.utc > token.expires_at
    
    token.user
  end
  
  def self.revoke_for_user(user : User)
    where(user_id: user.id).delete_all
  end
end
```

## JWT Implementation

```crystal
require "jwt"

module JWTService
  extend self
  
  SECRET_KEY = ENV["JWT_SECRET"]
  ALGORITHM = JWT::Algorithm::HS256
  
  def encode(payload : Hash(String, JSON::Any::Type), expires_in : Time::Span = 24.hours) : String
    payload["exp"] = (Time.utc + expires_in).to_unix
    payload["iat"] = Time.utc.to_unix
    
    JWT.encode(payload, SECRET_KEY, ALGORITHM)
  end
  
  def decode(token : String) : Hash(String, JSON::Any)?
    JWT.decode(token, SECRET_KEY, ALGORITHM).first
  rescue JWT::Error
    nil
  end
  
  def generate_access_token(user : User) : String
    encode({
      "sub" => user.id,
      "email" => user.email,
      "type" => "access"
    }, expires_in: 15.minutes)
  end
  
  def generate_refresh_token(user : User) : String
    encode({
      "sub" => user.id,
      "type" => "refresh"
    }, expires_in: 7.days)
  end
end

class JWTToken < Grant::Base
  column id : Int64, primary: true
  column user_id : Int64
  column jti : String  # JWT ID for revocation
  column token_type : String
  column expires_at : Time
  column revoked_at : Time?
  column created_at : Time = Time.utc
  
  belongs_to :user
  
  def self.create_pair(user : User) : {String, String}
    access_token = JWTService.generate_access_token(user)
    refresh_token = JWTService.generate_refresh_token(user)
    
    # Store refresh token for revocation
    if payload = JWTService.decode(refresh_token)
      create!(
        user_id: user.id,
        jti: Random::Secure.hex(16),
        token_type: "refresh",
        expires_at: Time.unix(payload["exp"].as_i64)
      )
    end
    
    {access_token, refresh_token}
  end
  
  def self.revoked?(jti : String) : Bool
    token = find_by(jti: jti)
    token ? token.revoked_at != nil : false
  end
  
  def revoke!
    update!(revoked_at: Time.utc)
  end
end
```

## OAuth Tokens

```crystal
class OAuthToken < Grant::Base
  column id : Int64, primary: true
  column user_id : Int64
  column provider : String
  column access_token_encrypted : String
  column refresh_token_encrypted : String?
  column expires_at : Time?
  column scopes : Array(String) = [] of String,
    converter: Grant::Converters::Json(Array(String))
  column created_at : Time = Time.utc
  column updated_at : Time = Time.utc
  
  belongs_to :user
  
  # Encrypt tokens at rest
  def access_token=(value : String)
    self.access_token_encrypted = Encryption.encrypt(value)
  end
  
  def access_token : String
    Encryption.decrypt(access_token_encrypted)
  end
  
  def refresh_token=(value : String?)
    self.refresh_token_encrypted = value ? Encryption.encrypt(value) : nil
  end
  
  def refresh_token : String?
    refresh_token_encrypted ? Encryption.decrypt(refresh_token_encrypted) : nil
  end
  
  def expired? : Bool
    expires_at ? Time.utc > expires_at : false
  end
  
  def refresh!(client : OAuth2::Client) : Bool
    return false unless refresh_token
    
    response = client.refresh_token(refresh_token)
    
    self.access_token = response.access_token
    self.refresh_token = response.refresh_token if response.refresh_token
    self.expires_at = response.expires_in ? Time.utc + response.expires_in.seconds : nil
    save!
    
    true
  rescue
    false
  end
end
```

## Advanced Token Patterns

### Time-based OTP (TOTP)

```crystal
require "otp"

class TwoFactorAuth < Grant::Base
  column id : Int64, primary: true
  column user_id : Int64
  column secret_encrypted : String
  column backup_codes_encrypted : String?
  column enabled : Bool = false
  column verified_at : Time?
  column last_used_at : Time?
  column created_at : Time = Time.utc
  
  belongs_to :user
  
  def self.setup_for_user(user : User) : {TwoFactorAuth, String, Array(String)}
    secret = OTP::Secret.generate
    backup_codes = generate_backup_codes
    
    auth = new(
      user_id: user.id,
      secret_encrypted: Encryption.encrypt(secret),
      backup_codes_encrypted: Encryption.encrypt(backup_codes.to_json)
    )
    auth.save!
    
    {auth, secret, backup_codes}
  end
  
  def secret : String
    Encryption.decrypt(secret_encrypted)
  end
  
  def backup_codes : Array(String)
    return [] of String unless backup_codes_encrypted
    Array(String).from_json(Encryption.decrypt(backup_codes_encrypted))
  end
  
  def verify_code(code : String) : Bool
    totp = OTP::TOTP.new(secret)
    
    # Check TOTP code
    if totp.verify(code, at: Time.utc)
      touch_last_used!
      return true
    end
    
    # Check backup codes
    codes = backup_codes
    if codes.includes?(code)
      codes.delete(code)
      self.backup_codes_encrypted = Encryption.encrypt(codes.to_json)
      save!
      return true
    end
    
    false
  end
  
  def enable!(verification_code : String) : Bool
    return false if enabled
    return false unless verify_code(verification_code)
    
    update!(
      enabled: true,
      verified_at: Time.utc
    )
  end
  
  def generate_qr_code : String
    totp = OTP::TOTP.new(secret)
    provisioning_uri = totp.provisioning_uri(
      user.email,
      issuer: "MyApp"
    )
    
    # Generate QR code URL
    "https://chart.googleapis.com/chart?chs=200x200&cht=qr&chl=#{URI.encode(provisioning_uri)}"
  end
  
  private def self.generate_backup_codes : Array(String)
    8.times.map { Random::Secure.hex(4).upcase }.to_a
  end
  
  private def touch_last_used!
    update!(last_used_at: Time.utc)
  end
end
```

### Magic Links

```crystal
class MagicLink < Grant::Base
  column id : Int64, primary: true
  column email : String
  column token_digest : String
  column expires_at : Time
  column used_at : Time?
  column ip_address : String?
  column user_agent : String?
  column created_at : Time = Time.utc
  
  LIFETIME = 15.minutes
  
  def self.create_for_email(email : String, ip : String? = nil) : String
    raw_token = SecureToken.generate(48)
    
    create!(
      email: email.downcase,
      token_digest: SecureToken.digest(raw_token),
      expires_at: Time.utc + LIFETIME,
      ip_address: ip
    )
    
    raw_token
  end
  
  def self.authenticate(raw_token : String, ip : String? = nil) : User?
    digest = SecureToken.digest(raw_token)
    link = find_by(token_digest: digest)
    
    return nil unless link
    return nil if link.used?
    return nil if link.expired?
    
    # Optional: Verify IP match
    if link.ip_address && ip && link.ip_address != ip
      Log.warn { "Magic link IP mismatch: #{link.ip_address} != #{ip}" }
    end
    
    # Mark as used
    link.update!(used_at: Time.utc)
    
    # Find or create user
    User.find_or_create_by(email: link.email)
  end
  
  def used? : Bool
    !used_at.nil?
  end
  
  def expired? : Bool
    Time.utc > expires_at
  end
  
  def self.cleanup_expired
    where.lt(:expires_at, Time.utc - 1.hour).delete_all
  end
end
```

### Rate-Limited Tokens

```crystal
class RateLimitedToken < Grant::Base
  column id : Int64, primary: true
  column token_digest : String
  column purpose : String
  column identifier : String  # IP, user_id, email, etc.
  column attempts : Int32 = 0
  column locked_until : Time?
  column expires_at : Time
  column created_at : Time = Time.utc
  
  MAX_ATTEMPTS = 5
  LOCKOUT_DURATION = 1.hour
  
  def self.create_token(purpose : String, identifier : String, expires_in : Time::Span = 1.hour) : String?
    # Check if locked out
    if locked_out?(purpose, identifier)
      return nil
    end
    
    raw_token = SecureToken.generate(32)
    
    create!(
      token_digest: SecureToken.digest(raw_token),
      purpose: purpose,
      identifier: identifier,
      expires_at: Time.utc + expires_in
    )
    
    raw_token
  end
  
  def self.verify_token(raw_token : String, purpose : String) : Bool
    digest = SecureToken.digest(raw_token)
    token = find_by(token_digest: digest, purpose: purpose)
    
    return false unless token
    return false if token.locked?
    return false if token.expired?
    
    # Valid token
    token.delete
    true
  rescue
    # Invalid attempt
    if token
      token.record_failed_attempt!
    end
    false
  end
  
  def self.locked_out?(purpose : String, identifier : String) : Bool
    recent = where(purpose: purpose, identifier: identifier)
              .where.gteq(:created_at, 1.hour.ago)
              .order(created_at: :desc)
              .first
    
    recent ? recent.locked? : false
  end
  
  def locked? : Bool
    locked_until ? Time.utc < locked_until : false
  end
  
  def expired? : Bool
    Time.utc > expires_at
  end
  
  def record_failed_attempt!
    self.attempts += 1
    
    if attempts >= MAX_ATTEMPTS
      self.locked_until = Time.utc + LOCKOUT_DURATION
    end
    
    save!
  end
end
```

## Security Best Practices

### Token Storage

```crystal
class SecureTokenStorage
  # Never store raw tokens
  # Always hash before storage
  def self.store_token(raw_token : String) : String
    Digest::SHA256.hexdigest(raw_token)
  end
  
  # Use constant-time comparison
  def self.secure_compare(a : String, b : String) : Bool
    return false unless a.bytesize == b.bytesize
    
    result = 0_u8
    a.bytes.zip(b.bytes) do |byte_a, byte_b|
      result |= byte_a ^ byte_b
    end
    result == 0
  end
  
  # Secure token generation
  def self.generate_secure_token(length : Int32 = 32) : String
    # Use cryptographically secure random
    Random::Secure.urlsafe_base64(length)
  end
  
  # Token with checksum
  def self.generate_with_checksum(length : Int32 = 32) : String
    token = generate_secure_token(length)
    checksum = Digest::SHA256.hexdigest(token)[0...8]
    "#{token}-#{checksum}"
  end
  
  def self.verify_checksum(token_with_checksum : String) : Bool
    parts = token_with_checksum.split("-")
    return false unless parts.size == 2
    
    token = parts[0]
    checksum = parts[1]
    expected = Digest::SHA256.hexdigest(token)[0...8]
    
    secure_compare(checksum, expected)
  end
end
```

### Token Rotation

```crystal
class RotatingToken < Grant::Base
  column id : Int64, primary: true
  column token_digest : String
  column previous_token_digest : String?
  column rotated_at : Time?
  column expires_at : Time
  
  ROTATION_PERIOD = 7.days
  GRACE_PERIOD = 1.hour
  
  def should_rotate? : Bool
    return false unless rotated_at
    Time.utc - rotated_at > ROTATION_PERIOD
  end
  
  def rotate! : String
    new_token = SecureToken.generate(48)
    
    self.previous_token_digest = token_digest
    self.token_digest = SecureToken.digest(new_token)
    self.rotated_at = Time.utc
    save!
    
    new_token
  end
  
  def self.authenticate(raw_token : String) : RotatingToken?
    digest = SecureToken.digest(raw_token)
    
    # Try current token
    token = find_by(token_digest: digest)
    return token if token && !token.expired?
    
    # Try previous token within grace period
    token = find_by(previous_token_digest: digest)
    if token && !token.expired? && token.rotated_at
      if Time.utc - token.rotated_at < GRACE_PERIOD
        return token
      end
    end
    
    nil
  end
  
  def expired? : Bool
    Time.utc > expires_at
  end
end
```

## Testing

```crystal
describe SecureToken do
  describe "generation" do
    it "generates unique tokens" do
      tokens = 100.times.map { SecureToken.generate }.to_a
      tokens.uniq.size.should eq(100)
    end
    
    it "generates tokens of correct length" do
      token = SecureToken.generate(48)
      Base64.decode(token).bytesize.should eq(48)
    end
  end
  
  describe "authentication" do
    it "authenticates valid tokens" do
      user = User.create!(email: "test@example.com")
      token, raw = AccessToken.create_for_user(user)
      
      authenticated = AccessToken.authenticate(raw)
      authenticated.should eq(token)
    end
    
    it "rejects expired tokens" do
      user = User.create!(email: "test@example.com")
      token, raw = AccessToken.create_for_user(user, expires_in: 0.seconds)
      
      sleep 0.1
      AccessToken.authenticate(raw).should be_nil
    end
    
    it "handles rate limiting" do
      5.times do
        RateLimitedToken.verify_token("wrong", "test")
      end
      
      token = RateLimitedToken.create_token("test", "identifier")
      token.should be_nil  # Locked out
    end
  end
end
```

## Next Steps

- [Signed IDs](signed-ids.md)
- [Encrypted Attributes](encrypted-attributes.md)
- [Authentication Patterns](../../patterns/authentication.md)
- [API Security](../../patterns/api-security.md)