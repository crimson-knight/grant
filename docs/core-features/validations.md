---
title: "Validations"
category: "core-features"
subcategory: "validations"
tags: ["validations", "data-integrity", "errors", "validators", "constraints"]
complexity: "beginner"
version: "1.0.0"
prerequisites: ["models-and-columns.md", "crud-operations.md"]
related_docs: ["relationships.md", "callbacks-lifecycle.md", "../advanced/data-management/migrations.md"]
last_updated: "2025-01-13"
estimated_read_time: "18 minutes"
use_cases: ["data-validation", "form-validation", "business-rules", "data-integrity"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Validations

Comprehensive guide to Grant's validation system, including built-in validators, custom validations, and error handling.

## Overview

Grant provides a robust validation system that ensures data integrity before persisting to the database. Validations run automatically when saving records and populate an `errors` array when validation fails.

```crystal
class User < Grant::Base
  column email : String
  column age : Int32
  
  validates_email :email
  validates_numericality_of :age, greater_than: 0
end

user = User.new(email: "invalid", age: -5)
user.valid?  # => false
user.errors  # => Array of validation errors
user.save    # => false (won't save invalid records)
```

## Basic Validation Syntax

### Custom Validations

Define custom validations using the `validate` macro:

```crystal
class Post < Grant::Base
  column title : String
  column content : String
  
  validate :title, "can't be blank" do |post|
    !post.title.to_s.blank?
  end
  
  validate :content, "must be at least 10 characters" do |post|
    post.content.size >= 10
  end
end
```

### Validation Execution

Validations run automatically on:
- `save` and `save!`
- `update` and `update!`
- `valid?` (runs validations without saving)

```crystal
post = Post.new(title: "", content: "short")
post.valid?   # => false (runs validations)
post.save     # => false (validations prevent save)
post.save!    # => raises Grant::RecordInvalid

# Skip validations (use carefully!)
post.save(validate: false)  # => true
```

## Built-in Validators

### Presence and Absence

```crystal
class Product < Grant::Base
  column name : String
  column description : String?
  column internal_notes : String?
  
  # Validates field is not nil or blank
  validates_presence_of :name
  validate_not_blank :name
  
  # Validates field IS nil or blank  
  validates_absence_of :internal_notes
  validate_is_blank :internal_notes, if: :public?
end
```

### Numericality

```crystal
class Order < Grant::Base
  column total : Float64
  column quantity : Int32
  column discount : Float64
  column priority : Int32
  
  validates_numericality_of :total, greater_than: 0
  validates_numericality_of :quantity, 
    only_integer: true,
    greater_than: 0
  validates_numericality_of :discount,
    greater_than_or_equal_to: 0,
    less_than_or_equal_to: 100
  validates_numericality_of :priority,
    in: 1..5,
    even: true
end
```

#### Numericality Options:
- `greater_than: value`
- `greater_than_or_equal_to: value`
- `less_than: value`
- `less_than_or_equal_to: value`
- `equal_to: value`
- `other_than: value`
- `odd: true` - Must be odd
- `even: true` - Must be even
- `only_integer: true` - No decimals
- `in: range` - Within range
- `allow_nil: true`
- `allow_blank: true`

### Format Validation

```crystal
class User < Grant::Base
  column username : String
  column phone : String
  column zip_code : String
  column ssn : String
  
  # Match pattern
  validates_format_of :username, with: /\A[a-zA-Z0-9_]+\z/
  validates_format_of :phone, with: /\A\d{3}-\d{3}-\d{4}\z/
  
  # Exclude pattern
  validates_format_of :username, without: /\A(admin|root)\z/,
    message: "is reserved"
  
  # Multiple patterns
  validates_format_of :ssn, 
    with: /\A\d{3}-\d{2}-\d{4}\z/,
    message: "must be XXX-XX-XXXX format"
end
```

### Length/Size Validation

```crystal
class Article < Grant::Base
  column title : String
  column body : String
  column tags : Array(String)
  column slug : String
  
  # String length
  validates_length_of :title, minimum: 5, maximum: 100
  validates_length_of :body, minimum: 100
  validates_length_of :slug, is: 8  # Exactly 8
  
  # Array size
  validates_size_of :tags, maximum: 10
  validates_size_of :tags, in: 1..10  # Range
end
```

#### Length Options:
- `minimum: value`
- `maximum: value`
- `is: value` - Exact length
- `in: range` - Within range
- `allow_nil: true`
- `allow_blank: true`

### Email and URL

```crystal
class Contact < Grant::Base
  column email : String
  column website : String?
  column backup_email : String?
  
  # Email validation
  validates_email :email
  validates_email :backup_email, allow_nil: true
  
  # URL validation (http/https)
  validates_url :website, allow_blank: true
end
```

### Confirmation

```crystal
class Account < Grant::Base
  column email : String
  column password : String
  
  validates_confirmation_of :email
  validates_confirmation_of :password
end

# Usage requires confirmation fields
account = Account.new(
  email: "user@example.com",
  password: "secret123"
)
account.email_confirmation = "user@example.com"
account.password_confirmation = "secret123"
account.valid?  # => true
```

### Acceptance

```crystal
class Registration < Grant::Base
  column email : String
  
  validates_acceptance_of :terms_of_service
  validates_acceptance_of :privacy_policy, 
    accept: ["yes", "accepted", "1"]
  validates_acceptance_of :age_verification,
    message: "You must be 18 or older"
end

# Usage
reg = Registration.new(email: "user@example.com")
reg.terms_of_service = "1"  # Accepted values: "1", "true", "yes", "on"
reg.privacy_policy = "yes"
reg.age_verification = true
reg.valid?  # => true
```

### Inclusion and Exclusion

```crystal
class Subscription < Grant::Base
  column plan : String
  column status : String
  column payment_method : String
  column username : String
  
  # Must be in list
  validates_inclusion_of :plan, 
    in: ["free", "basic", "premium", "enterprise"]
  validates_inclusion_of :status,
    in: VALID_STATUSES  # Constant array
  
  # Must NOT be in list
  validates_exclusion_of :payment_method,
    in: ["cash", "check"],
    message: "is not accepted"
  validates_exclusion_of :username,
    in: RESERVED_USERNAMES
end
```

### Uniqueness

```crystal
class User < Grant::Base
  column email : String
  column username : String
  column company_id : Int64
  column employee_id : String
  
  # Simple uniqueness
  validate_uniqueness :email
  validate_uniqueness :username
  
  # Scoped uniqueness (unique within scope)
  validate_uniqueness :employee_id, scope: :company_id
end
```

### Associated Validations

```crystal
class Order < Grant::Base
  has_many :line_items
  has_one :shipping_address
  belongs_to :customer
  
  # Validates associated objects are valid
  validates_associated :line_items
  validates_associated :shipping_address
  validates_associated :customer
end

# Order is only valid if all associations are valid
```

## Validation Helpers

Quick macros for common validations:

```crystal
class User < Grant::Base
  column name : String
  column email : String
  column age : Int32
  column bio : String?
  
  # Nil checks
  validate_not_nil :name
  validate_is_nil :deleted_at
  
  # Blank checks (nil or empty)
  validate_not_blank :email
  validate_is_blank :bio, if: :new_user?
  
  # Length helpers
  validate_min_length :password, 8
  validate_max_length :username, 20
  
  # Numeric helpers
  validate_greater_than :age, 0
  validate_less_than :age, 120
  
  # Choice validation
  validate_is_valid_choice :role, ["admin", "user", "guest"]
  validate_exclusion :status, ["banned", "suspended"]
end
```

## Conditional Validations

### Using Symbols

```crystal
class Post < Grant::Base
  column title : String
  column content : String
  column published : Bool
  
  validates_length_of :title, minimum: 10, if: :published?
  validates_presence_of :content, unless: :draft?
  
  def published?
    published == true
  end
  
  def draft?
    !published
  end
end
```

### Using Procs/Lambdas

```crystal
class Order < Grant::Base
  column total : Float64
  column payment_method : String
  column credit_card : String?
  
  validates_presence_of :credit_card,
    if: ->(order : Order) { order.payment_method == "credit" }
  
  validates_numericality_of :total,
    greater_than: 100,
    if: ->(o : Order) { o.express_shipping? }
end
```

### Complex Conditions

```crystal
class Product < Grant::Base
  column price : Float64
  column sale_price : Float64?
  column on_sale : Bool
  
  validate :sale_price, "must be less than regular price" do |product|
    next true unless product.on_sale
    next true if product.sale_price.nil?
    
    product.sale_price.not_nil! < product.price
  end
end
```

## Custom Validators

### Reusable Validators

```crystal
module CustomValidators
  # Phone number validator
  macro validates_phone_number(field, **options)
    validates_format_of {{field}},
      with: /\A\+?[1-9]\d{1,14}\z/,
      message: "is not a valid international phone number",
      {{**options}}
  end
  
  # Strong password validator
  macro validates_strong_password(field, **options)
    validate {{field}}, "must be a strong password" do |record|
      password = record.{{field.id}}
      next true if password.nil? && {{options[:allow_nil]}}
      
      password.size >= 8 &&
      password.matches?(/[A-Z]/) &&
      password.matches?(/[a-z]/) &&
      password.matches?(/[0-9]/) &&
      password.matches?(/[^A-Za-z0-9]/)
    end
  end
end

class User < Grant::Base
  extend CustomValidators
  
  column phone : String
  column password : String
  
  validates_phone_number :phone
  validates_strong_password :password
end
```

### Validator Classes

```crystal
class EmailValidator
  def self.validate(record, field, options = {} of Symbol => String)
    value = record.read_attribute(field)
    
    return if value.nil? && options[:allow_nil]?
    return if value.blank? && options[:allow_blank]?
    
    unless value.matches?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
      record.errors.add(field, options[:message]? || "is not a valid email")
    end
  end
end

class User < Grant::Base
  validate do |user|
    EmailValidator.validate(user, :email)
    EmailValidator.validate(user, :backup_email, allow_nil: true)
  end
end
```

## Error Messages

### Custom Messages

```crystal
class User < Grant::Base
  column age : Int32
  column email : String
  column username : String
  
  validates_numericality_of :age,
    greater_than_or_equal_to: 18,
    message: "You must be at least 18 years old"
  
  validates_format_of :email,
    with: /@company\.com\z/,
    message: "must be a company email address"
  
  validate_uniqueness :username,
    message: "has already been taken. Please choose another."
end
```

### Working with Errors

```crystal
user = User.new(email: "invalid", age: 10)

# Check if valid
user.valid?  # => false

# Get all errors
user.errors  # => Array(Grant::Error)

# Get errors for specific field
email_errors = user.errors.select { |e| e.field == :email }

# Get error messages
user.errors.map(&.message)
# => ["is not a valid email", "You must be at least 18 years old"]

# Full error messages
user.errors.map { |e| "#{e.field} #{e.message}" }
# => ["email is not a valid email", "age You must be at least 18 years old"]

# Add custom errors
user.errors.add(:base, "Something went wrong")
user.errors.add(:email, "is not allowed")
```

### Internationalization

```crystal
module I18n
  MESSAGES = {
    en: {
      blank: "can't be blank",
      invalid: "is invalid",
      too_short: "is too short (minimum is %{min} characters)",
      too_long: "is too long (maximum is %{max} characters)"
    },
    es: {
      blank: "no puede estar en blanco",
      invalid: "es inválido",
      too_short: "es demasiado corto (mínimo %{min} caracteres)",
      too_long: "es demasiado largo (máximo %{max} caracteres)"
    }
  }
  
  def self.t(key, locale = :en, **params)
    message = MESSAGES[locale][key]
    params.each do |k, v|
      message = message.gsub("%{#{k}}", v.to_s)
    end
    message
  end
end

class User < Grant::Base
  validates_length_of :name,
    minimum: 3,
    message: ->{ I18n.t(:too_short, min: 3) }
end
```

## Validation Options

### allow_nil vs allow_blank

```crystal
class Profile < Grant::Base
  column bio : String?
  column website : String?
  column age : Int32?
  
  # Skips only if nil
  validates_length_of :bio, minimum: 10, allow_nil: true
  # Invalid: ""  (empty string)
  # Valid: nil
  
  # Skips if nil, empty string, or whitespace
  validates_url :website, allow_blank: true
  # Valid: nil, "", "   "
  
  # Numeric with allow_nil
  validates_numericality_of :age,
    greater_than: 0,
    allow_nil: true
end
```

### on: Option (Context)

```crystal
class User < Grant::Base
  column email : String
  column password : String
  
  # Only on create
  validates_presence_of :password, on: :create
  
  # Only on update
  validates_confirmation_of :password, on: :update
  
  # Custom contexts
  validate :email, "must be corporate email", on: :corporate do |user|
    user.email.ends_with?("@company.com")
  end
end

# Usage with context
user.valid?(:corporate)
user.save(context: :corporate)
```

## Validation Callbacks

```crystal
class User < Grant::Base
  before_validation :normalize_email
  after_validation :set_defaults
  
  private def normalize_email
    self.email = email.downcase.strip if email
  end
  
  private def set_defaults
    self.role ||= "user" if errors.empty?
  end
end
```

## Best Practices

### 1. Layer Validations

```crystal
class CreditCard < Grant::Base
  # Format validation
  validates_format_of :number, with: /\A\d{16}\z/
  
  # Business logic validation
  validate :number, "must pass Luhn check" do |card|
    LuhnValidator.valid?(card.number)
  end
  
  # Database constraint (migration)
  # ADD CONSTRAINT valid_card_number CHECK (char_length(number) = 16)
end
```

### 2. Group Related Validations

```crystal
class User < Grant::Base
  # Authentication
  validates_presence_of :email
  validates_email :email
  validates_confirmation_of :email
  
  # Password requirements
  validates_length_of :password, minimum: 8
  validates_format_of :password, with: /[A-Z]/,
    message: "must contain uppercase"
  validates_format_of :password, with: /[0-9]/,
    message: "must contain number"
  
  # Profile
  validates_length_of :username, in: 3..20
  validates_format_of :username, with: /\A\w+\z/
  validate_uniqueness :username
end
```

### 3. Use Database Constraints

```crystal
# Model validation
validate_uniqueness :email

# Also add database constraint
# CREATE UNIQUE INDEX users_email_unique ON users(email);
```

### 4. Performance Considerations

```crystal
class Product < Grant::Base
  # Expensive validation last
  validates_presence_of :name       # Fast
  validates_length_of :name, in: 1..100  # Fast
  validate_uniqueness :sku          # Database query
  
  validate :image, "must be valid" do |product|
    # Expensive image processing
    ImageValidator.valid?(product.image_data) if product.image_data
  end
end
```

## Testing Validations

```crystal
describe User do
  describe "validations" do
    it "requires email" do
      user = User.new(name: "John")
      user.valid?.should be_false
      user.errors.any? { |e| e.field == :email }.should be_true
    end
    
    it "validates email format" do
      user = User.new(email: "invalid")
      user.valid?.should be_false
      
      user.email = "valid@example.com"
      user.valid?  # Check other validations
    end
    
    it "enforces unique email" do
      User.create!(email: "taken@example.com", name: "First")
      
      duplicate = User.new(email: "taken@example.com", name: "Second")
      duplicate.valid?.should be_false
      duplicate.errors.any? { |e| 
        e.field == :email && e.message.includes?("taken")
      }.should be_true
    end
  end
end
```

## Troubleshooting

### Validations Not Running
```crystal
# Ensure you call valid? or save
user.errors  # => [] (empty, not run yet)
user.valid?  # => false (runs validations)
user.errors  # => [errors...]
```

### Uniqueness Validation Race Condition
```crystal
# Add database constraint as backup
validate_uniqueness :email
# CREATE UNIQUE INDEX users_email_unique ON users(email);
```

### Custom Validation Not Working
```crystal
# Ensure proper return value
validate :field, "message" do |record|
  # Must return boolean
  return false if condition_fails
  true
end
```

## Next Steps

- [Callbacks and Lifecycle](callbacks-lifecycle.md)
- [Relationships](relationships.md)
- [Migrations](../advanced/data-management/migrations.md)
- [Error Handling](../advanced/error-handling.md)