---
name: grant-validations
description: Grant ORM validation system including built-in validators, custom validations, conditional validations, error handling, and validation contexts.
user-invocable: false
---

# Grant Validations

## Overview

Grant provides a robust validation system that ensures data integrity before persisting to the database. Validations run automatically on `save`, `save!`, `update`, `update!`, and `valid?`. Invalid records are not saved, and errors are populated on the model's `errors` array.

```crystal
user = User.new(email: "invalid", age: -5)
user.valid?   # => false
user.errors   # => Array(Grant::Error)
user.save     # => false
user.save!    # Raises Grant::RecordInvalid
```

## Custom Validations (validate block)

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

## Built-in Validators

### Presence and Absence

```crystal
validates_presence_of :name
validate_not_blank :name       # Not nil or blank
validate_not_nil :field        # Not nil
validate_is_nil :field         # Must be nil
validate_is_blank :field       # Must be blank
```

### Numericality

```crystal
validates_numericality_of :price, greater_than: 0
validates_numericality_of :quantity, only_integer: true, greater_than: 0
validates_numericality_of :discount,
  greater_than_or_equal_to: 0,
  less_than_or_equal_to: 100
validates_numericality_of :priority, in: 1..5, even: true
```

**Options**: `greater_than`, `greater_than_or_equal_to`, `less_than`, `less_than_or_equal_to`, `equal_to`, `other_than`, `odd: true`, `even: true`, `only_integer: true`, `in: range`, `allow_nil: true`, `allow_blank: true`

### Format

```crystal
validates_format_of :username, with: /\A[a-zA-Z0-9_]+\z/
validates_format_of :phone, with: /\A\d{3}-\d{3}-\d{4}\z/
validates_format_of :username, without: /\A(admin|root)\z/, message: "is reserved"
```

**Options**: `with: regex`, `without: regex`, `message:`, `allow_nil:`, `allow_blank:`

### Length / Size

```crystal
validates_length_of :title, minimum: 5, maximum: 100
validates_length_of :body, minimum: 100
validates_length_of :slug, is: 8            # Exactly 8
validates_size_of :tags, maximum: 10        # Array size
validates_size_of :tags, in: 1..10          # Range
```

**Options**: `minimum:`, `maximum:`, `is:`, `in: range`, `allow_nil:`, `allow_blank:`

### Email

```crystal
validates_email :email
validates_email :backup_email, allow_nil: true
```

### URL

```crystal
validates_url :website
validates_url :canonical_url, allow_blank: true
```

### Confirmation

Validates that a field matches its `_confirmation` counterpart:

```crystal
validates_confirmation_of :email
validates_confirmation_of :password

# Usage
account.email = "user@example.com"
account.email_confirmation = "user@example.com"
account.password = "secret123"
account.password_confirmation = "secret123"
account.valid?  # => true
```

### Acceptance

```crystal
validates_acceptance_of :terms_of_service
validates_acceptance_of :privacy_policy, accept: ["yes", "accepted"]
validates_acceptance_of :age_verification, message: "You must be 18 or older"
```

Default accepted values: `"1"`, `"true"`, `"yes"`, `"on"`

### Inclusion and Exclusion

```crystal
validates_inclusion_of :plan, in: ["free", "basic", "premium", "enterprise"]
validates_exclusion_of :payment_method, in: ["cash", "check"], message: "is not accepted"
```

### Uniqueness

```crystal
validate_uniqueness :email
validate_uniqueness :username
validate_uniqueness :employee_id, scope: :company_id  # Scoped uniqueness
```

### Associated

```crystal
validates_associated :line_items
validates_associated :shipping_address
# Order is only valid if all associated records are also valid
```

## Validation Helpers (Quick Macros)

```crystal
validate_not_nil :name
validate_is_nil :deleted_at
validate_not_blank :email
validate_is_blank :bio
validate_min_length :password, 8
validate_max_length :username, 20
validate_greater_than :age, 0
validate_less_than :age, 120
validate_is_valid_choice :role, ["admin", "user", "guest"]
validate_exclusion :status, ["banned", "suspended"]
```

## Conditional Validations

### Using Symbols

```crystal
validates_length_of :title, minimum: 10, if: :published?
validates_presence_of :content, unless: :draft?

def published?
  published == true
end
```

### Using Procs/Lambdas

```crystal
validates_presence_of :credit_card,
  if: ->(order : Order) { order.payment_method == "credit" }
```

### Validation Contexts (on:)

```crystal
validates_presence_of :password, on: :create
validates_confirmation_of :password, on: :update

validate :email, "must be corporate email", on: :corporate do |user|
  user.email.ends_with?("@company.com")
end

# Usage
user.valid?(:corporate)
user.save(context: :corporate)
```

## Custom Error Messages

```crystal
validates_numericality_of :age,
  greater_than_or_equal_to: 18,
  message: "You must be at least 18 years old"

validates_format_of :email,
  with: /@company\.com\z/,
  message: "must be a company email address"

validate_uniqueness :username,
  message: "has already been taken. Please choose another."
```

## Working with Errors

```crystal
user = User.new(email: "invalid", age: 10)
user.valid?  # => false

# All errors
user.errors  # => Array(Grant::Error)

# Filter by field
email_errors = user.errors.select { |e| e.field == :email }

# Error messages
user.errors.map(&.message)
# => ["is not a valid email", "You must be at least 18 years old"]

# Full messages with field name
user.errors.map { |e| "#{e.field} #{e.message}" }

# Add custom errors
user.errors.add(:base, "Something went wrong")
user.errors.add(:email, "is not allowed")
```

## Validation Callbacks

```crystal
before_validation :normalize_email
after_validation :set_defaults

private def normalize_email
  self.email = email.downcase.strip if email
end

private def set_defaults
  self.role ||= "user" if errors.empty?
end
```

## allow_nil vs allow_blank

- `allow_nil: true` -- Skips validation only if value is `nil`
- `allow_blank: true` -- Skips if `nil`, empty string, or whitespace

```crystal
validates_length_of :bio, minimum: 10, allow_nil: true
# Invalid: "" (empty string)
# Valid: nil

validates_url :website, allow_blank: true
# Valid: nil, "", "   "
```

## Custom Reusable Validators

```crystal
module CustomValidators
  macro validates_phone_number(field, **options)
    validates_format_of {{field}},
      with: /\A\+?[1-9]\d{1,14}\z/,
      message: "is not a valid international phone number",
      {{**options}}
  end
end

class User < Grant::Base
  extend CustomValidators
  column phone : String
  validates_phone_number :phone
end
```

## Skipping Validation

```crystal
post.save(validate: false)   # Saves even with invalid data
```

## Best Practices

1. **Layer validations**: Format validation + business logic validation + DB constraint
2. **Group related validations** by feature area in the model
3. **Use DB constraints as backup**: `validate_uniqueness` should have a matching `UNIQUE INDEX`
4. **Put expensive validations last**: Uniqueness checks (DB query) after presence checks (in-memory)
5. **Always return boolean** from custom validate blocks
