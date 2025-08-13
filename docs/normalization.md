# Data Normalization

Grant provides automatic data normalization that runs before validation. This ensures your data is consistently formatted before it's validated or saved to the database.

## Basic Usage

Include the `Grant::Normalization` module and use the `normalizes` macro to define normalization rules:

```crystal
class User < Grant::Base
  include Grant::Normalization
  
  connection sqlite
  table users
  
  column id : Int64, primary: true
  column email : String?
  column phone : String?
  
  # Normalize email to lowercase and strip whitespace
  normalizes :email do |value|
    value.downcase.strip
  end
  
  # Remove non-digits from phone numbers
  normalizes :phone do |value|
    value.gsub(/\D/, "")
  end
end
```

## When Normalizations Run

**Important:** Normalizations are **NOT** applied at the time of assignment. They are only applied when validation occurs.

Normalizations are automatically applied:
- Before validation (via `before_validation` callback)
- Before saving to the database (since validation runs before save)
- When you explicitly call `valid?`

This means:
```crystal
user = User.new
user.email = "  JOHN@EXAMPLE.COM  "
user.email # => "  JOHN@EXAMPLE.COM  " (unchanged - normalization hasn't run yet)

user.valid?
user.email # => "john@example.com" (normalized after validation)
```

### Opting Out of Normalization

You can skip normalization by passing `skip_normalization: true` to the `valid?` method:

```crystal
user = User.new
user.email = "  JOHN@EXAMPLE.COM  "

# Skip normalization for this validation
user.valid?(skip_normalization: true)
user.email # => "  JOHN@EXAMPLE.COM  " (unchanged)

# Subsequent validations will normalize unless you opt out again
user.valid?
user.email # => "john@example.com" (normalized)
```

This is useful when:
- You need to validate the raw user input
- You want to display validation errors with the original input
- You're comparing values before and after normalization

### Timing Implications

Since normalizations run during validation, not assignment:

1. **Display values may differ from stored values** - If you display a form field before validation, it will show the original input
2. **Comparisons before validation use original values** - Be careful when comparing attributes before validation
3. **Multiple validations re-run normalizations** - Each call to `valid?` will re-apply normalizations
4. **Save triggers normalization** - Calling `save` or `save!` will normalize values even if you haven't called `valid?`

Example:
```crystal
user = User.new(email: "  TEST@EXAMPLE.COM  ")

# Before validation
user.email # => "  TEST@EXAMPLE.COM  "
user.email == "test@example.com" # => false

# After validation
user.valid?
user.email # => "test@example.com"
user.email == "test@example.com" # => true

# Save also triggers normalization
user2 = User.new(email: "  ANOTHER@EXAMPLE.COM  ")
user2.save # This normalizes before saving
user2.email # => "another@example.com"
```

## Examples

### Email Normalization

```crystal
normalizes :email do |value|
  value.downcase.strip
end

user = User.new
user.email = "  JOHN@EXAMPLE.COM  "
user.valid?
user.email # => "john@example.com"
```

### Phone Number Normalization

```crystal
normalizes :phone do |value|
  value.gsub(/\D/, "")
end

user = User.new
user.phone = "(555) 123-4567"
user.valid?
user.phone # => "5551234567"
```

### Username Normalization

```crystal
normalizes :username do |value|
  value.downcase.gsub(/[^a-z0-9_]/, "")
end

user = User.new
user.username = "John_Doe!"
user.valid?
user.username # => "john_doe"
```

## Conditional Normalization

You can specify conditions for when normalizations should run:

```crystal
class User < Grant::Base
  include Grant::Normalization
  
  column website : String?
  
  normalizes :website, if: :website_present? do |value|
    value.starts_with?("http") ? value : "https://#{value}"
  end
  
  def website_present?
    !website.nil? && !website.try(&.empty?)
  end
end

user = User.new
user.website = "example.com"
user.valid?
user.website # => "https://example.com"

user.website = "http://example.com"
user.valid?
user.website # => "http://example.com" (unchanged)
```

## Integration with Dirty Tracking

Normalizations work seamlessly with Grant's dirty tracking:

```crystal
user = User.create(email: "old@example.com")
user.email = "  NEW@EXAMPLE.COM  "
user.valid?

user.email # => "new@example.com"
user.email_changed? # => true
user.email_was # => "old@example.com"
```

### Special Cases

1. **Normalization back to original value**: If normalization returns the value to its original state, the attribute is not considered changed:
```crystal
user = User.create(email: "test@example.com")
user.email = "  TEST@EXAMPLE.COM  "
user.email_changed? # => true

user.valid?
user.email # => "test@example.com" (normalized back to original)
user.email_changed? # => false
```

2. **New records**: For new records, normalization doesn't mark attributes as changed:
```crystal
user = User.new
user.email = "  TEST@EXAMPLE.COM  "
user.valid?
user.email # => "test@example.com"
user.email_changed? # => false (new record, no "original" to compare)
```

## Common Use Cases

### URL Normalization

```crystal
normalizes :website do |value|
  uri = URI.parse(value)
  uri.scheme ? value : "https://#{value}"
rescue
  value
end
```

### Whitespace Trimming

```crystal
normalizes :name do |value|
  value.strip
end
```

### Case Normalization

```crystal
normalizes :country_code do |value|
  value.upcase
end
```

### Complex Transformations

```crystal
normalizes :slug do |value|
  value.downcase
    .gsub(/[^a-z0-9\-]/, "-")
    .gsub(/\-+/, "-")
    .strip("-")
end
```

## Best Practices

1. **Keep normalizations simple**: Complex logic should be in separate methods
2. **Only normalize strings**: The macro only processes String values
3. **Test edge cases**: Include tests for nil values and empty strings
4. **Use conditions wisely**: Only normalize when it makes sense
5. **Document your normalizations**: Explain why each normalization exists

## Implementation Notes

- Normalizations only apply to String attributes
- The normalization block receives the current value and should return the normalized value
- Normalizations run in the order they are defined
- If a normalization raises an exception, it's silently caught and the value remains unchanged
- Normalizations are run every time validation occurs, so keep them efficient