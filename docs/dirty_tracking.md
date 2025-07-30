# Dirty Tracking API

Grant (formerly Granite) provides a comprehensive dirty tracking API that allows you to track changes to your model attributes. This feature is inspired by Rails' ActiveRecord dirty tracking and provides full compatibility with the Rails API.

## Overview

Dirty tracking allows you to:
- Check if a model has unsaved changes
- See what attributes have changed
- Access the original values before changes
- Restore attributes to their original values
- Track changes through save operations

## Basic Usage

### Checking for Changes

```crystal
user = User.find!(1)
user.changed? # => false

user.name = "New Name"
user.changed? # => true

user.save
user.changed? # => false
```

### Viewing Changed Attributes

```crystal
user = User.find!(1)
user.name = "Jane"
user.email = "jane@example.com"

user.changed_attributes # => ["name", "email"]
user.changes # => {"name" => {"John", "Jane"}, "email" => {"john@example.com", "jane@example.com"}}
```

## Per-Attribute Methods

For each attribute defined with the `column` macro, Grant automatically generates convenience methods:

### `<attribute>_changed?`

Returns true if the specific attribute has been changed.

```crystal
user.name = "New Name"
user.name_changed? # => true
user.email_changed? # => false
```

### `<attribute>_was`

Returns the original value of the attribute before it was changed.

```crystal
user.name # => "John"
user.name = "Jane"
user.name_was # => "John"
user.name # => "Jane"
```

### `<attribute>_change`

Returns a tuple containing the original and new values, or nil if unchanged.

```crystal
user.name = "Jane"
user.name_change # => {"John", "Jane"}
user.email_change # => nil
```

### `<attribute>_before_last_save`

Returns the value of the attribute before the last save operation.

```crystal
user.name # => "John"
user.name = "Jane"
user.save

user.name = "Jim"
user.name_before_last_save # => "John"
```

## Working with Saved Changes

After a save operation, you can access what was changed:

```crystal
user.name = "Jane"
user.save

# After save, current changes are cleared
user.changed? # => false

# But you can access what was saved
user.previous_changes # => {"name" => {"John", "Jane"}}
user.saved_changes # => {"name" => {"John", "Jane"}} # Alias for previous_changes

# Check if a specific attribute was changed in the last save
user.saved_change_to_attribute?("name") # => true
user.saved_change_to_attribute?("email") # => false

# Get the value before the last save
user.attribute_before_last_save("name") # => "John"
```

## Restoring Changes

You can restore changed attributes to their original values:

```crystal
user = User.find!(1)
original_name = user.name # => "John"
original_email = user.email # => "john@example.com"

user.name = "Jane"
user.email = "jane@example.com"

# Restore specific attributes
user.restore_attributes(["name"])
user.name # => "John"
user.email # => "jane@example.com" (still changed)

# Restore all changed attributes
user.restore_attributes
user.email # => "john@example.com"
```

## Edge Cases

### Setting the Same Value

Setting an attribute to its current value doesn't mark it as changed:

```crystal
user.name # => "John"
user.name = "John"
user.name_changed? # => false
```

### Reverting to Original Value

If you change an attribute and then change it back to its original value, it's no longer considered changed:

```crystal
user.name # => "John"
user.name = "Jane"
user.name_changed? # => true

user.name = "John"
user.name_changed? # => false
user.changed? # => false
```

## Use in Callbacks

Dirty tracking is particularly useful in callbacks:

```crystal
class User < Granite::Base
  column name : String
  column email : String
  column email_verified : Bool = false
  
  before_save :unverify_email_if_changed
  after_save :send_verification_email_if_needed
  
  private def unverify_email_if_changed
    if email_changed?
      self.email_verified = false
    end
  end
  
  private def send_verification_email_if_needed
    if saved_change_to_attribute?("email")
      # Send verification email
      EmailService.send_verification(self)
    end
  end
end
```

## New Records

Newly created records don't track changes until after their first save:

```crystal
user = User.new(name: "John")
user.changed? # => false
user.name_changed? # => false

user.save
user.name = "Jane"
user.name_changed? # => true
```

## Working with Associations

Dirty tracking only tracks changes to the model's own attributes, not to associated models:

```crystal
user.posts.first.title = "New Title"
user.changed? # => false

# But foreign keys are tracked
user.company_id = 5
user.company_id_changed? # => true
```

## Type Conversions

Dirty tracking works with all Grant column types, including those with converters:

```crystal
class Product < Granite::Base
  column price : Float64
  column metadata : JSON::Any, converter: Granite::Converters::Json(JSON::Any)
  column status : ProductStatus, converter: Granite::Converters::Enum(ProductStatus, String)
end

product.price = 19.99
product.price_change # => {9.99, 19.99}

product.status = ProductStatus::Active
product.status_changed? # => true
```

## Performance Considerations

- Dirty tracking has minimal performance impact as it only stores changed values
- Original values are captured lazily when an attribute is first changed
- After save, the tracking state is reset efficiently

## Rails Compatibility

Grant's dirty tracking API is designed to be compatible with Rails' ActiveRecord, making it easier to port Rails applications to Crystal. All the method names and behaviors match Rails' implementation.