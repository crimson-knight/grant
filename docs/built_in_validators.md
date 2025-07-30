# Built-in Validators

Grant provides a comprehensive set of Rails-style validators for common validation needs. All validators support conditional validation with `:if` and `:unless` options.

## Overview

Built-in validators provide:
- Familiar Rails API for easy migration
- Type-safe validation with Crystal's type system
- Conditional validation support
- Custom error messages
- Flexible options for common use cases

## Available Validators

### validates_numericality_of

Validates that attributes have numeric values and optionally match specific criteria.

```crystal
class Product < Granite::Base
  column price : Float64
  column quantity : Int32
  column discount : Float64
  
  validates_numericality_of :price, greater_than: 0
  validates_numericality_of :quantity, only_integer: true
  validates_numericality_of :discount, 
    greater_than_or_equal_to: 0,
    less_than_or_equal_to: 100
end
```

#### Options:
- `greater_than: value` - Value must be > the specified value
- `greater_than_or_equal_to: value` - Value must be >= the specified value
- `less_than: value` - Value must be < the specified value
- `less_than_or_equal_to: value` - Value must be <= the specified value
- `equal_to: value` - Value must be exactly equal
- `other_than: value` - Value must not equal the specified value
- `odd: true` - Value must be odd
- `even: true` - Value must be even
- `only_integer: true` - Value must be an integer
- `in: range` - Value must be within the range
- `allow_nil: true` - Skip validation if value is nil
- `allow_blank: true` - Skip validation if value is blank

### validates_format_of

Validates attributes match or don't match a regular expression.

```crystal
class User < Granite::Base
  column username : String
  column phone : String
  column zip_code : String
  
  validates_format_of :username, with: /\A[a-zA-Z0-9_]+\z/
  validates_format_of :phone, with: /\A\d{3}-\d{3}-\d{4}\z/
  validates_format_of :username, without: /\A(admin|root)\z/, 
    message: "is reserved"
end
```

#### Options:
- `with: regex` - Attribute must match this pattern
- `without: regex` - Attribute must not match this pattern
- `message: string` - Custom error message
- `allow_nil: true` - Skip validation if nil
- `allow_blank: true` - Skip validation if blank

### validates_length_of / validates_size_of

Validates the length of string attributes or size of arrays.

```crystal
class Article < Granite::Base
  column title : String
  column body : String
  column tags : Array(String)
  
  validates_length_of :title, minimum: 5, maximum: 100
  validates_length_of :body, minimum: 100
  validates_size_of :tags, maximum: 10
  validates_length_of :slug, is: 8  # Exactly 8 characters
end
```

#### Options:
- `minimum: value` - Must have at least this many characters/elements
- `maximum: value` - Must have at most this many characters/elements
- `is: value` - Must be exactly this length
- `in: range` - Length must be within the range
- `allow_nil: true` - Skip if nil
- `allow_blank: true` - Skip if blank

### validates_email

Validates email format using a standard email regex.

```crystal
class Contact < Granite::Base
  column email : String
  column backup_email : String?
  
  validates_email :email
  validates_email :backup_email, allow_nil: true
end
```

### validates_url

Validates URL format for http/https URLs.

```crystal
class Link < Granite::Base
  column url : String
  column canonical_url : String?
  
  validates_url :url
  validates_url :canonical_url, allow_blank: true
end
```

### validates_confirmation_of

Validates that a field matches its confirmation field.

```crystal
class Account < Granite::Base
  column email : String
  column password : String
  
  validates_confirmation_of :email
  validates_confirmation_of :password
end

# Usage:
account = Account.new(
  email: "user@example.com",
  password: "secret123"
)
account.email_confirmation = "user@example.com"
account.password_confirmation = "secret123"
account.valid? # => true
```

### validates_acceptance_of

Validates acceptance of terms, agreements, etc.

```crystal
class Signup < Granite::Base
  column email : String
  
  validates_acceptance_of :terms_of_service
  validates_acceptance_of :privacy_policy, accept: ["yes", "accepted"]
end

# Usage:
signup = Signup.new(email: "user@example.com")
signup.terms_of_service = "1"  # or "true", "yes", "on"
signup.privacy_policy = "yes"
signup.valid? # => true
```

#### Options:
- `accept: array` - Custom values to accept (default: ["1", "true", "yes", "on"])
- `allow_nil: true` - Allow nil as accepted

### validates_inclusion_of

Validates that values are included in a given set.

```crystal
class Subscription < Granite::Base
  column plan : String
  column status : String
  
  validates_inclusion_of :plan, in: ["free", "basic", "premium", "enterprise"]
  validates_inclusion_of :status, in: ["active", "suspended", "cancelled"]
end
```

### validates_exclusion_of

Validates that values are NOT in a given set.

```crystal
class User < Granite::Base
  column username : String
  column subdomain : String
  
  validates_exclusion_of :username, in: ["admin", "root", "superuser"]
  validates_exclusion_of :subdomain, in: RESERVED_SUBDOMAINS
end
```

### validates_associated

Validates that associated objects are also valid.

```crystal
class Order < Granite::Base
  has_many :line_items
  has_one :shipping_address
  
  validates_associated :line_items
  validates_associated :shipping_address
end

# The order is only valid if all line items and shipping address are valid
```

## Conditional Validation

All validators support conditional execution using `:if` and `:unless` options.

### Using Symbols

```crystal
class Order < Granite::Base
  column total : Float64?
  column status : String
  
  validates_numericality_of :total, greater_than: 0, if: :completed?
  
  def completed?
    status == "completed"
  end
end
```

### Using Procs

```crystal
class Post < Granite::Base
  column title : String
  column published : Bool
  
  validates_length_of :title, minimum: 10, 
    if: ->(post : Post) { post.published }
end
```

## Custom Error Messages

All validators accept a custom `:message` option:

```crystal
class User < Granite::Base
  column age : Int32
  column email : String
  
  validates_numericality_of :age, 
    greater_than: 17, 
    message: "You must be 18 or older"
    
  validates_format_of :email, 
    with: /@company\.com\z/,
    message: "must be a company email address"
end
```

## Combining Multiple Validators

You can use multiple validators on the same field:

```crystal
class Account < Granite::Base
  column username : String
  column password : String
  
  # Username validations
  validates_length_of :username, in: 3..20
  validates_format_of :username, with: /\A[a-zA-Z0-9_]+\z/
  validates_exclusion_of :username, in: RESERVED_NAMES
  
  # Password validations  
  validates_length_of :password, minimum: 8
  validates_format_of :password, with: /[A-Z]/, 
    message: "must contain an uppercase letter"
  validates_format_of :password, with: /[0-9]/, 
    message: "must contain a number"
end
```

## Allow Nil vs Allow Blank

- `allow_nil: true` - Skips validation only if the value is `nil`
- `allow_blank: true` - Skips validation if the value is `nil`, empty string, or whitespace

```crystal
class Profile < Granite::Base
  column bio : String?
  column website : String?
  
  # Bio can be nil but not empty string
  validates_length_of :bio, minimum: 10, allow_nil: true
  
  # Website can be nil or empty
  validates_url :website, allow_blank: true
end
```

## Best Practices

### 1. Use Specific Validators

```crystal
# Better - specific and clear
validates_email :email
validates_url :website

# Less clear - generic format validation
validates_format_of :email, with: EMAIL_REGEX
validates_format_of :website, with: URL_REGEX
```

### 2. Group Related Validations

```crystal
class User < Granite::Base
  # Authentication fields
  validates_presence_of :email
  validates_email :email
  validates_confirmation_of :email
  
  # Profile fields
  validates_length_of :username, in: 3..20
  validates_format_of :username, with: /\A\w+\z/
  
  # Settings
  validates_acceptance_of :terms_of_service
  validates_inclusion_of :timezone, in: VALID_TIMEZONES
end
```

### 3. Use Conditional Validation Wisely

```crystal
class Order < Granite::Base
  # Only validate payment details when order is being finalized
  validates_presence_of :credit_card_number, if: :finalizing?
  validates_length_of :credit_card_number, is: 16, if: :finalizing?
  
  # Always validate core fields
  validates_presence_of :customer_email
  validates_numericality_of :total, greater_than: 0
end
```

### 4. Provide Clear Error Messages

```crystal
class Registration < Granite::Base
  validates_numericality_of :age, 
    greater_than_or_equal_to: 13,
    message: "You must be at least 13 years old to register"
    
  validates_format_of :username,
    without: /[^a-zA-Z0-9_]/,
    message: "can only contain letters, numbers, and underscores"
end
```

## Comparison with Rails

Grant's validators are designed to be familiar to Rails developers:

### Rails
```ruby
class User < ApplicationRecord
  validates :email, presence: true, format: { with: EMAIL_REGEX }
  validates :age, numericality: { greater_than: 17 }
end
```

### Grant
```crystal
class User < Granite::Base
  validates_presence_of :email  # From validation_helpers
  validates_email :email        # Built-in email validator
  validates_numericality_of :age, greater_than: 17
end
```

## Creating Custom Validators

You can create reusable validators by extending the pattern:

```crystal
module MyValidators
  macro validates_phone_number(field, **options)
    validates_format_of {{field}}, 
      with: /\A\+?[1-9]\d{1,14}\z/,
      message: "is not a valid international phone number",
      {{**options}}
  end
end

class Contact < Granite::Base
  extend MyValidators
  
  column phone : String
  validates_phone_number :phone
end
```

## Troubleshooting

### Validation Not Running

Ensure you're calling `valid?` before checking errors:

```crystal
user = User.new(email: "invalid")
user.errors  # => [] (empty, validations haven't run)

user.valid?  # => false (runs validations)
user.errors  # => [Error(@field="email", @message="is not a valid email")]
```

### Multiple Errors on Same Field

Each validator adds its own error:

```crystal
user.valid?
user.errors.select { |e| e.field == "password" }
# => Multiple errors for password field
```

### Performance Considerations

- Validators run in the order they're defined
- Use conditional validation to skip expensive checks
- Consider database constraints for critical validations

```crystal
# Also add database constraint
# ADD CONSTRAINT email_format CHECK (email ~ '^.+@.+\..+$')
validates_email :email
```