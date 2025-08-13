---
title: "Signed IDs"
category: "advanced"
subcategory: "security"
tags: ["security", "signed-ids", "global-ids", "urls", "references", "cryptography"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../../core-features/models-and-columns.md", "secure-tokens.md"]
related_docs: ["secure-tokens.md", "encrypted-attributes.md", "../../core-features/relationships.md"]
last_updated: "2025-01-13"
estimated_read_time: "14 minutes"
use_cases: ["unsubscribe-links", "file-downloads", "public-references", "share-links", "api-references"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Signed IDs

Comprehensive guide to implementing signed global IDs in Grant for secure, tamper-proof references to database records in URLs, APIs, and external systems.

## Overview

Signed IDs provide a secure way to reference database records in public contexts without exposing internal IDs or allowing tampering. They are useful for:

- Unsubscribe links in emails
- Secure file download URLs
- Shareable links with expiration
- API resource references
- Preventing ID enumeration attacks
- Temporary access grants

## Basic Implementation

### Simple Signed IDs

```crystal
require "base64"
require "json"
require "openssl/hmac"

module SignedId
  extend self
  
  SECRET_KEY = ENV["SIGNED_ID_SECRET"] || raise "Missing SIGNED_ID_SECRET"
  
  # Generate signed ID for a model
  def generate(model : Grant::Base, expires_in : Time::Span? = nil, purpose : String? = nil) : String
    payload = {
      "gid" => "#{model.class.name}/#{model.id}",
      "exp" => expires_in ? (Time.utc + expires_in).to_unix : nil,
      "pur" => purpose
    }.compact
    
    encoded = Base64.urlsafe_encode(payload.to_json)
    signature = sign(encoded)
    
    "#{encoded}.#{signature}"
  end
  
  # Verify and decode signed ID
  def verify(signed_id : String, purpose : String? = nil) : Grant::Base?
    parts = signed_id.split(".")
    return nil unless parts.size == 2
    
    encoded, signature = parts
    return nil unless valid_signature?(encoded, signature)
    
    payload = JSON.parse(Base64.decode_string(encoded))
    
    # Check expiration
    if exp = payload["exp"]?.try(&.as_i64)
      return nil if Time.utc.to_unix > exp
    end
    
    # Check purpose
    if purpose
      return nil unless payload["pur"]? == purpose
    end
    
    # Parse global ID
    parse_gid(payload["gid"].as_s)
  rescue
    nil
  end
  
  private def sign(data : String) : String
    Base64.urlsafe_encode(
      OpenSSL::HMAC.digest(:sha256, SECRET_KEY, data)
    )
  end
  
  private def valid_signature?(data : String, signature : String) : Bool
    expected = sign(data)
    secure_compare(expected, signature)
  end
  
  private def secure_compare(a : String, b : String) : Bool
    return false unless a.bytesize == b.bytesize
    
    result = 0_u8
    a.bytes.zip(b.bytes) do |byte_a, byte_b|
      result |= byte_a ^ byte_b
    end
    result == 0
  end
  
  private def parse_gid(gid : String) : Grant::Base?
    parts = gid.split("/")
    return nil unless parts.size == 2
    
    class_name, id = parts
    
    # Find the model class
    case class_name
    when "User"
      User.find?(id.to_i64)
    when "Post"
      Post.find?(id.to_i64)
    # Add more models as needed
    else
      nil
    end
  end
end

# Module to include in models
module HasSignedId
  macro included
    def signed_id(expires_in : Time::Span? = nil, purpose : String? = nil) : String
      SignedId.generate(self, expires_in, purpose)
    end
    
    def self.find_signed(signed_id : String, purpose : String? = nil) : self?
      record = SignedId.verify(signed_id, purpose)
      record.as?(self)
    end
  end
end

class User < Grant::Base
  include HasSignedId
  
  column id : Int64, primary: true
  column email : String
  column name : String
  
  # Generate various signed IDs
  def unsubscribe_token : String
    signed_id(expires_in: 30.days, purpose: "unsubscribe")
  end
  
  def password_reset_token : String
    signed_id(expires_in: 2.hours, purpose: "password_reset")
  end
  
  def email_confirmation_token : String
    signed_id(expires_in: 7.days, purpose: "email_confirmation")
  end
end
```

### Advanced Signed ID System

```crystal
class SignedGlobalId
  property model_class : String
  property model_id : Int64
  property expires_at : Time?
  property purpose : String?
  property metadata : Hash(String, String)
  
  def initialize(@model_class, @model_id, @expires_at = nil, @purpose = nil, @metadata = {} of String => String)
  end
  
  # Encode to signed string
  def to_s : String
    payload = {
      "class" => model_class,
      "id" => model_id,
      "exp" => expires_at.try(&.to_unix),
      "pur" => purpose,
      "meta" => metadata.empty? ? nil : metadata
    }.compact
    
    json = payload.to_json
    encoded = Base64.urlsafe_encode(json)
    signature = generate_signature(encoded)
    
    "sgid:#{encoded}.#{signature}"
  end
  
  # Decode from signed string
  def self.parse(signed_id : String) : SignedGlobalId?
    return nil unless signed_id.starts_with?("sgid:")
    
    signed_id = signed_id[5..]  # Remove prefix
    parts = signed_id.split(".")
    return nil unless parts.size == 2
    
    encoded, signature = parts
    return nil unless verify_signature(encoded, signature)
    
    json = Base64.decode_string(encoded)
    payload = JSON.parse(json)
    
    # Check expiration
    if exp = payload["exp"]?.try(&.as_i64)
      return nil if Time.utc.to_unix > exp
    end
    
    new(
      payload["class"].as_s,
      payload["id"].as_i64,
      payload["exp"]?.try { |e| Time.unix(e.as_i64) },
      payload["pur"]?.try(&.as_s),
      payload["meta"]?.try(&.as_h.transform_values(&.as_s)) || {} of String => String
    )
  rescue
    nil
  end
  
  # Find the actual model
  def find : Grant::Base?
    Registry.find(model_class, model_id)
  end
  
  # Verify purpose matches
  def for_purpose?(check_purpose : String) : Bool
    purpose == check_purpose
  end
  
  # Check if expired
  def expired? : Bool
    expires_at ? Time.utc > expires_at : false
  end
  
  private def generate_signature(data : String) : String
    key = SignedIdConfig.secret_key
    Base64.urlsafe_encode(
      OpenSSL::HMAC.digest(:sha256, key, data)
    )
  end
  
  private def self.verify_signature(data : String, signature : String) : Bool
    expected = new("", 0).generate_signature(data)
    secure_compare(expected, signature)
  end
  
  private def self.secure_compare(a : String, b : String) : Bool
    return false unless a.bytesize == b.bytesize
    
    result = 0_u8
    a.bytes.zip(b.bytes) do |byte_a, byte_b|
      result |= byte_a ^ byte_b
    end
    result == 0
  end
end

# Registry for model lookups
module Registry
  @@models = {} of String => Proc(Int64, Grant::Base?)
  
  def self.register(class_name : String, &block : Int64 -> Grant::Base?)
    @@models[class_name] = block
  end
  
  def self.find(class_name : String, id : Int64) : Grant::Base?
    @@models[class_name]?.try(&.call(id))
  end
end

# Configuration
module SignedIdConfig
  @@secret_key : String = ENV["SIGNED_ID_SECRET"]
  
  def self.secret_key : String
    @@secret_key
  end
  
  def self.secret_key=(key : String)
    @@secret_key = key
  end
end
```

## Use Cases

### Unsubscribe Links

```crystal
class Subscription < Grant::Base
  include HasSignedId
  
  column id : Int64, primary: true
  column user_id : Int64
  column list_id : Int64
  column active : Bool = true
  
  belongs_to :user
  belongs_to :mailing_list, foreign_key: :list_id
  
  def unsubscribe_url : String
    token = signed_id(expires_in: 30.days, purpose: "unsubscribe")
    "https://example.com/unsubscribe/#{token}"
  end
  
  def self.unsubscribe_by_token(token : String) : Bool
    subscription = find_signed(token, purpose: "unsubscribe")
    return false unless subscription
    
    subscription.update!(active: false)
    true
  end
end

# In controller
class UnsubscribeController
  def show(token : String)
    if Subscription.unsubscribe_by_token(token)
      render "Successfully unsubscribed"
    else
      render "Invalid or expired link", status: 404
    end
  end
end
```

### Secure File Downloads

```crystal
class Attachment < Grant::Base
  include HasSignedId
  
  column id : Int64, primary: true
  column filename : String
  column content_type : String
  column size : Int64
  column path : String
  column access_level : String  # "public", "private", "restricted"
  
  def download_url(expires_in : Time::Span = 1.hour) : String
    return public_url if access_level == "public"
    
    token = signed_id(expires_in: expires_in, purpose: "download")
    "https://example.com/files/#{token}"
  end
  
  def public_url : String
    "https://cdn.example.com/#{path}"
  end
  
  def self.find_for_download(token : String) : Attachment?
    find_signed(token, purpose: "download")
  end
end

class FileController
  def download(token : String)
    attachment = Attachment.find_for_download(token)
    
    unless attachment
      return render_404("File not found or link expired")
    end
    
    # Log download
    DownloadLog.create!(
      attachment_id: attachment.id,
      ip_address: request.ip,
      downloaded_at: Time.utc
    )
    
    send_file(attachment.path, 
      filename: attachment.filename,
      content_type: attachment.content_type)
  end
end
```

### Shareable Links

```crystal
class ShareableLink < Grant::Base
  column id : Int64, primary: true
  column resource_type : String
  column resource_id : Int64
  column created_by_id : Int64
  column expires_at : Time?
  column max_uses : Int32?
  column uses_count : Int32 = 0
  column password_hash : String?
  column permissions : Array(String) = ["read"],
    converter: Grant::Converters::Json(Array(String))
  
  belongs_to :created_by, class_name: "User"
  
  def generate_link : String
    sgid = SignedGlobalId.new(
      self.class.name,
      id,
      expires_at,
      "share",
      {
        "resource" => "#{resource_type}/#{resource_id}",
        "perms" => permissions.join(",")
      }
    )
    
    "https://example.com/shared/#{sgid}"
  end
  
  def self.access_resource(token : String, password : String? = nil) : Grant::Base?
    sgid = SignedGlobalId.parse(token)
    return nil unless sgid
    return nil unless sgid.for_purpose?("share")
    return nil if sgid.expired?
    
    link = sgid.find.as?(ShareableLink)
    return nil unless link
    return nil if link.exceeded_max_uses?
    
    # Check password if required
    if link.password_hash
      return nil unless password && link.verify_password(password)
    end
    
    # Increment usage
    link.increment_usage!
    
    # Find and return the actual resource
    Registry.find(link.resource_type, link.resource_id)
  end
  
  def exceeded_max_uses? : Bool
    max_uses ? uses_count >= max_uses : false
  end
  
  def increment_usage!
    update!(uses_count: uses_count + 1)
  end
  
  def verify_password(password : String) : Bool
    # Implementation depends on your password hashing
    BCrypt::Password.new(password_hash.not_nil!) == password
  end
end
```

### API Resource References

```crystal
module ApiSignedId
  extend self
  
  # Generate versioned API reference
  def generate(model : Grant::Base, version : String = "v1") : String
    sgid = SignedGlobalId.new(
      model.class.name,
      model.id,
      nil,  # No expiration for API references
      "api",
      {"v" => version}
    )
    
    sgid.to_s
  end
  
  # Parse API reference
  def parse(reference : String, version : String = "v1") : Grant::Base?
    sgid = SignedGlobalId.parse(reference)
    return nil unless sgid
    return nil unless sgid.for_purpose?("api")
    return nil unless sgid.metadata["v"]? == version
    
    sgid.find
  end
end

class ApiController
  def show(id : String)
    # Accept either regular ID or signed ID
    resource = if id.starts_with?("sgid:")
      ApiSignedId.parse(id, "v1")
    else
      Post.find?(id.to_i64)
    end
    
    unless resource
      return render_json({error: "Resource not found"}, status: 404)
    end
    
    render_json(resource.to_api_json)
  end
end

class Post < Grant::Base
  def to_api_json
    {
      id: ApiSignedId.generate(self),
      title: title,
      content: content,
      author: {
        id: ApiSignedId.generate(author),
        name: author.name
      }
    }
  end
end
```

## Advanced Patterns

### Polymorphic Signed IDs

```crystal
class PolymorphicSignedId
  def self.generate(model : Grant::Base, **options) : String
    sgid = SignedGlobalId.new(
      model.class.name,
      model.id,
      options[:expires_in]?.try { |span| Time.utc + span },
      options[:purpose]?.try(&.to_s),
      options[:metadata]?.try(&.transform_values(&.to_s)) || {} of String => String
    )
    
    sgid.to_s
  end
  
  def self.find(token : String) : Grant::Base?
    sgid = SignedGlobalId.parse(token)
    return nil unless sgid
    return nil if sgid.expired?
    
    # Dynamic model lookup
    sgid.find
  end
end

# Usage with different models
user = User.find!(1)
post = Post.find!(1)
comment = Comment.find!(1)

user_token = PolymorphicSignedId.generate(user, expires_in: 1.day)
post_token = PolymorphicSignedId.generate(post, purpose: "share")
comment_token = PolymorphicSignedId.generate(comment, metadata: {"notify" => "true"})

# Find any model type
model = PolymorphicSignedId.find(user_token)  # Returns User
model = PolymorphicSignedId.find(post_token)  # Returns Post
```

### Batch Signed IDs

```crystal
class BatchSignedId
  def self.generate(models : Array(Grant::Base), expires_in : Time::Span? = nil) : String
    ids = models.map { |m| "#{m.class.name}/#{m.id}" }
    
    payload = {
      "ids" => ids,
      "exp" => expires_in ? (Time.utc + expires_in).to_unix : nil,
      "pur" => "batch"
    }.compact
    
    encoded = Base64.urlsafe_encode(payload.to_json)
    signature = generate_signature(encoded)
    
    "batch:#{encoded}.#{signature}"
  end
  
  def self.find_all(token : String) : Array(Grant::Base)
    return [] of Grant::Base unless token.starts_with?("batch:")
    
    token = token[6..]
    parts = token.split(".")
    return [] of Grant::Base unless parts.size == 2
    
    encoded, signature = parts
    return [] of Grant::Base unless verify_signature(encoded, signature)
    
    payload = JSON.parse(Base64.decode_string(encoded))
    
    # Check expiration
    if exp = payload["exp"]?.try(&.as_i64)
      return [] of Grant::Base if Time.utc.to_unix > exp
    end
    
    # Find all models
    ids = payload["ids"].as_a.map(&.as_s)
    ids.compact_map do |gid|
      parts = gid.split("/")
      next unless parts.size == 2
      
      Registry.find(parts[0], parts[1].to_i64)
    end
  rescue
    [] of Grant::Base
  end
end

# Usage
posts = Post.where(featured: true).limit(5).to_a
token = BatchSignedId.generate(posts, expires_in: 1.hour)

# Later...
featured_posts = BatchSignedId.find_all(token)
```

### Revocable Signed IDs

```crystal
class RevocableSignedId < Grant::Base
  column id : Int64, primary: true
  column token_digest : String
  column model_class : String
  column model_id : Int64
  column expires_at : Time?
  column revoked_at : Time?
  column purpose : String?
  column created_at : Time = Time.utc
  
  def self.generate(model : Grant::Base, **options) : String
    token = Random::Secure.hex(32)
    
    create!(
      token_digest: Digest::SHA256.hexdigest(token),
      model_class: model.class.name,
      model_id: model.id,
      expires_at: options[:expires_in]?.try { |span| Time.utc + span },
      purpose: options[:purpose]?.try(&.to_s)
    )
    
    # Include record ID for quick lookup
    "revocable:#{id}:#{token}"
  end
  
  def self.find_model(token_string : String) : Grant::Base?
    return nil unless token_string.starts_with?("revocable:")
    
    parts = token_string.split(":")
    return nil unless parts.size == 3
    
    id = parts[1].to_i64
    token = parts[2]
    
    record = find?(id)
    return nil unless record
    return nil if record.revoked?
    return nil if record.expired?
    
    # Verify token
    digest = Digest::SHA256.hexdigest(token)
    return nil unless record.token_digest == digest
    
    Registry.find(record.model_class, record.model_id)
  end
  
  def revoked? : Bool
    !revoked_at.nil?
  end
  
  def expired? : Bool
    expires_at ? Time.utc > expires_at : false
  end
  
  def revoke!
    update!(revoked_at: Time.utc)
  end
  
  # Cleanup old records
  def self.cleanup
    where.lt(:expires_at, Time.utc).delete_all
    where.lt(:created_at, 90.days.ago).delete_all
  end
end
```

## Security Considerations

### Preventing Enumeration

```crystal
module SecureSignedId
  extend self
  
  # Add random padding to prevent length analysis
  def generate_padded(model : Grant::Base) : String
    padding_size = Random.rand(8..24)
    padding = Random::Secure.hex(padding_size)
    
    sgid = SignedGlobalId.new(
      model.class.name,
      model.id,
      metadata: {"p" => padding}
    )
    
    sgid.to_s
  end
  
  # Rate limit verification attempts
  @@attempts = {} of String => Array(Time)
  
  def verify_with_rate_limit(token : String, ip : String) : Grant::Base?
    key = "#{ip}:#{token[0...10]}"  # Group by IP and token prefix
    
    @@attempts[key] ||= [] of Time
    @@attempts[key].select! { |t| t > Time.utc - 1.minute }
    
    if @@attempts[key].size >= 10
      Log.warn { "Rate limit exceeded for signed ID verification from #{ip}" }
      return nil
    end
    
    @@attempts[key] << Time.utc
    
    SignedGlobalId.parse(token).try(&.find)
  end
end
```

### Signature Rotation

```crystal
class RotatingSignature
  @@keys = [
    ENV["SIGNED_ID_KEY_CURRENT"],
    ENV["SIGNED_ID_KEY_PREVIOUS"]?
  ].compact
  
  def self.sign(data : String) : String
    key = @@keys.first
    Base64.urlsafe_encode(
      OpenSSL::HMAC.digest(:sha256, key, data)
    )
  end
  
  def self.verify(data : String, signature : String) : Bool
    # Try all keys (current and previous)
    @@keys.any? do |key|
      expected = Base64.urlsafe_encode(
        OpenSSL::HMAC.digest(:sha256, key, data)
      )
      secure_compare(expected, signature)
    end
  end
  
  private def self.secure_compare(a : String, b : String) : Bool
    return false unless a.bytesize == b.bytesize
    
    result = 0_u8
    a.bytes.zip(b.bytes) do |byte_a, byte_b|
      result |= byte_a ^ byte_b
    end
    result == 0
  end
end
```

## Testing

```crystal
describe SignedId do
  describe "generation and verification" do
    it "generates valid signed IDs" do
      user = User.create!(email: "test@example.com", name: "Test")
      signed_id = user.signed_id
      
      signed_id.should_not be_empty
      signed_id.should contain(".")
    end
    
    it "verifies valid signed IDs" do
      user = User.create!(email: "test@example.com", name: "Test")
      signed_id = user.signed_id
      
      found = User.find_signed(signed_id)
      found.should eq(user)
    end
    
    it "rejects tampered signed IDs" do
      user = User.create!(email: "test@example.com", name: "Test")
      signed_id = user.signed_id
      
      # Tamper with ID
      tampered = signed_id.gsub(/^[^.]+/, Base64.urlsafe_encode("tampered"))
      
      User.find_signed(tampered).should be_nil
    end
    
    it "respects expiration" do
      user = User.create!(email: "test@example.com", name: "Test")
      signed_id = user.signed_id(expires_in: 0.seconds)
      
      sleep 0.1
      User.find_signed(signed_id).should be_nil
    end
    
    it "validates purpose" do
      user = User.create!(email: "test@example.com", name: "Test")
      reset_token = user.signed_id(purpose: "password_reset")
      
      User.find_signed(reset_token, purpose: "password_reset").should eq(user)
      User.find_signed(reset_token, purpose: "email_confirm").should be_nil
    end
  end
end
```

## Best Practices

### 1. Always Set Expiration

```crystal
# Good: Time-limited tokens
user.signed_id(expires_in: 24.hours, purpose: "download")

# Risky: No expiration
user.signed_id  # Vulnerable to long-term replay
```

### 2. Use Purpose Parameter

```crystal
# Good: Purpose-specific tokens
def password_reset_url
  token = signed_id(expires_in: 2.hours, purpose: "password_reset")
  "https://example.com/reset/#{token}"
end

# Verify with purpose
User.find_signed(token, purpose: "password_reset")
```

### 3. Rotate Keys Regularly

```crystal
# Store multiple keys for rotation
SignedIdConfig.keys = [
  ENV["SIGNED_ID_KEY_2024"],
  ENV["SIGNED_ID_KEY_2023"]  # Previous key for grace period
]
```

### 4. Log Suspicious Activity

```crystal
def verify_signed_id(token : String, ip : String)
  result = SignedId.verify(token)
  
  if result.nil?
    Log.warn { "Invalid signed ID attempt from #{ip}: #{token[0...20]}..." }
    SecurityEvent.create!(
      event_type: "invalid_signed_id",
      ip_address: ip,
      metadata: {"token_prefix" => token[0...20]}
    )
  end
  
  result
end
```

## Next Steps

- [Secure Tokens](secure-tokens.md)
- [Encrypted Attributes](encrypted-attributes.md)
- [API Security](../../patterns/api-security.md)
- [URL Design](../../patterns/url-design.md)