# Features Grant Should Implement

## 1. SQL Sanitization 🛡️ (Critical)

### Why Important
When executing raw SQL queries, we need protection against SQL injection attacks.

### Use Cases
```crystal
# Unsafe - SQL injection risk
User.raw_query("SELECT * FROM users WHERE name = '#{params[:name]}'")

# Safe - need sanitization
User.raw_query("SELECT * FROM users WHERE name = ?", [params[:name]])
```

### Proposed Grant Implementation
```crystal
module Grant::Sanitization
  def self.quote(value)
    case value
    when Nil then "NULL"
    when String then "'#{value.gsub("'", "''")}'"
    when Number then value.to_s
    when Bool then value ? "TRUE" : "FALSE"
    when Time then "'#{value.to_s("%Y-%m-%d %H:%M:%S")}'"
    else raise "Cannot quote #{value.class}"
    end
  end
  
  def self.quote_identifier(name : String)
    # Database-specific
    %("#{name.gsub('"', '""')}")
  end
  
  def self.sanitize_sql_array(ary : Array)
    sql = ary[0].as(String)
    values = ary[1..-1]
    
    values.each do |value|
      sql = sql.sub("?", quote(value))
    end
    
    sql
  end
end
```

**Priority**: Critical - Security requirement
**Effort**: Medium - Need database-specific implementations

## 2. Encryption Support 🔐 (Critical)

### Why Important
Modern applications need built-in encryption for sensitive data (PII, credentials, etc.)

### Rails Implementation
```ruby
class User < ActiveRecord::Base
  encrypts :email, :ssn
  encrypts :credit_card, deterministic: true # For searching
end
```

### Proposed Grant Implementation
```crystal
class User < Grant::Base
  include Grant::Encryption
  
  encrypts :email, :ssn
  encrypts :credit_card, deterministic: true
end
```

### Components Needed
- `Grant::Encryption::EncryptableRecord`
- `Grant::Encryption::Cipher`
- `Grant::Encryption::KeyProvider`
- `Grant::Encryption::EncryptedAttribute`

**Priority**: Critical - Security requirement
**Effort**: High - Need key management, cipher selection, attribute handling

## 2. Aggregations 📊

### Why Important
Composed value objects are common in domain modeling

### Rails Implementation
```ruby
class Customer < ActiveRecord::Base
  composed_of :address,
    class_name: "Address",
    mapping: [%w(address_street street), %w(address_city city)]
    
  composed_of :balance,
    class_name: "Money",
    mapping: %w(balance amount)
end
```

### Proposed Grant Implementation
```crystal
class Customer < Grant::Base
  aggregation :address,
    class_name: Address,
    mapping: {
      address_street: :street,
      address_city: :city
    }
end
```

**Priority**: Medium - Useful for DDD
**Effort**: Medium - Need value object support

## 3. Nested Attributes 🎯

### Why Important
Essential for forms that edit multiple related records

### Rails Implementation
```ruby
class User < ActiveRecord::Base
  has_many :posts
  accepts_nested_attributes_for :posts, 
    allow_destroy: true,
    reject_if: :all_blank
end

# Usage
User.create(
  name: "John",
  posts_attributes: [
    { title: "Post 1", content: "..." },
    { title: "Post 2", content: "..." }
  ]
)
```

### Proposed Grant Implementation
```crystal
class User < Grant::Base
  has_many :posts
  accepts_nested_attributes_for :posts,
    allow_destroy: true,
    reject_if: ->(attrs : Hash) { attrs["title"]?.blank? }
end
```

**Priority**: High - Common use case
**Effort**: High - Complex attribute assignment

## 4. Query Logs with Context 📝

### Why Important
Debugging complex applications requires query context

### Rails Implementation
```ruby
ActiveRecord::QueryLogs.tags = [:application, :controller, :action]

# Adds comments to SQL:
# SELECT * FROM users /* application:myapp controller:users action:index */
```

### Proposed Grant Implementation
```crystal
Grant::QueryLogs.tags = [:application, :request_id, :user_id]

# In middleware
Grant::QueryLogs.with_context(
  request_id: request.id,
  user_id: current_user.id
) do
  yield
end
```

**Priority**: Medium - Debugging aid
**Effort**: Low - Extension of existing logging

## 5. Secure Tokens 🎫

### Why Important
Common need for API tokens, password reset tokens, etc.

### Rails Implementation
```ruby
class User < ActiveRecord::Base
  has_secure_token :auth_token
  has_secure_token :password_reset_token, length: 36
end
```

### Proposed Grant Implementation
```crystal
class User < Grant::Base
  include Grant::SecureToken
  
  has_secure_token :auth_token
  has_secure_token :password_reset_token, length: 36
end
```

**Priority**: High - Security feature
**Effort**: Low - Simple implementation

## 6. Signed IDs 🔏

### Why Important
Secure, tamper-proof IDs for public URLs

### Rails Implementation
```ruby
signed_id = user.signed_id(purpose: :password_reset, expires_in: 1.day)
User.find_signed(signed_id, purpose: :password_reset)
```

### Proposed Grant Implementation
```crystal
signed_id = user.signed_id(purpose: :password_reset, expires_in: 1.day)
User.find_signed(signed_id, purpose: :password_reset)
```

**Priority**: Medium - Security feature
**Effort**: Medium - Need signing infrastructure

## 7. Normalization 🧹

### Why Important
Data consistency and cleaning

### Rails Implementation
```ruby
class User < ActiveRecord::Base
  normalizes :email, with: ->(email) { email.downcase.strip }
  normalizes :phone, with: ->(phone) { phone.gsub(/\D/, "") }
end
```

### Proposed Grant Implementation
```crystal
class User < Grant::Base
  include Grant::Normalization
  
  normalizes :email, &.downcase.strip
  normalizes :phone, &.gsub(/\D/, "")
end
```

**Priority**: Medium - Data quality
**Effort**: Low - Simple callbacks

## 8. Store Accessors 🗄️

### Why Important
Structured access to JSON/JSONB columns

### Rails Implementation
```ruby
class User < ActiveRecord::Base
  store :settings, accessors: [:color, :homepage], coder: JSON
  store_accessor :preferences, :theme, :notifications
end
```

### Proposed Grant Implementation
```crystal
class User < Grant::Base
  include Grant::Store
  
  json_accessor :settings, {
    color: String,
    homepage: String?
  }
  
  json_accessor :preferences, {
    theme: String,
    notifications: Bool
  }
end
```

**Priority**: Medium - Modern apps use JSON columns
**Effort**: Medium - Type-safe implementation

## 9. Token For (Temporary Tokens) 🎟️

### Why Important
Password resets, email confirmations, etc.

### Rails Implementation
```ruby
class User < ActiveRecord::Base
  generates_token_for :password_reset, expires_in: 15.minutes do
    # Token becomes invalid if password changes
    password_salt
  end
end

token = user.generate_token_for(:password_reset)
user = User.find_by_token_for(:password_reset, token)
```

### Proposed Grant Implementation
```crystal
class User < Grant::Base
  include Grant::TokenFor
  
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt
  end
end
```

**Priority**: High - Common requirement
**Effort**: Medium - Need secure token generation

## 10. Result Objects 📦

### Why Important
Efficient handling of raw query results

### Rails Implementation
```ruby
result = User.connection.select_all("SELECT * FROM users")
result.columns # => ["id", "name", "email"]
result.rows    # => [[1, "John", "john@example.com"]]
result.to_a    # => [{"id" => 1, "name" => "John", ...}]
```

### Proposed Grant Implementation
```crystal
result = User.connection.select_all("SELECT * FROM users")
result.columns # => ["id", "name", "email"]
result.rows    # => [[1, "John", "john@example.com"]]
result.to_a    # => [{"id" => 1, "name" => "John", ...}]
```

**Priority**: Low - Advanced use case
**Effort**: Low - Wrapper around DB results

## 11. Where Chain (Advanced Queries) 🔗

### Why Important
More expressive queries

### Rails Implementation
```ruby
User.where.not(name: "John")
User.where.missing(:avatar)
User.where.associated(:posts)
```

### Proposed Grant Implementation
```crystal
User.where.not(name: "John")
User.where.missing(:avatar)
User.where.associated(:posts)
```

**Priority**: Medium - Query expressiveness
**Effort**: Medium - Query builder enhancement

## 12. Relation Methods 🔄

### Why Important
Advanced relation manipulation

### Rails Implementation
```ruby
# Spawn creates a new relation
relation = User.where(active: true)
new_relation = relation.spawn.where(admin: true)

# Merge combines relations
User.where(active: true).merge(User.where(admin: true))
```

### Proposed Grant Implementation
```crystal
relation = User.where(active: true)
new_relation = relation.spawn.where(admin: true)

User.where(active: true).merge(User.where(admin: true))
```

**Priority**: Low - Advanced use
**Effort**: Medium - Query builder work

## Implementation Priority Matrix

### Critical (Implement First)
1. **Encryption** - Security requirement
2. **Explicit Transactions** - Data integrity

### High Priority
1. **Nested Attributes** - Common use case
2. **Secure Tokens** - Security feature
3. **Token For** - Authentication flows
4. **Advanced Query Methods** - Core functionality

### Medium Priority
1. **Aggregations** - DDD support
2. **Query Logs** - Debugging
3. **Signed IDs** - Security
4. **Normalization** - Data quality
5. **Store Accessors** - JSON columns
6. **Where Chain** - Query expressiveness

### Low Priority
1. **Result Objects** - Advanced use
2. **Relation Methods** - Advanced use

## Summary

These features represent the most valuable additions Grant could make to achieve closer parity with Active Record. The security features (encryption, tokens) are particularly important for modern applications, while features like nested attributes and advanced queries would significantly improve developer experience.

Total estimated effort: 6-8 months for full implementation of all features.