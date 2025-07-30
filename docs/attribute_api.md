# Attribute API

The Attribute API provides a flexible way to define custom attributes with type casting, default values, and virtual attributes that aren't backed by database columns.

## Overview

The Attribute API extends Grant's column functionality with:
- Virtual attributes not stored in the database
- Default values with static values or dynamic procs
- Custom type casting (planned)
- Integration with dirty tracking
- Support for custom types with converters

## Basic Usage

### Virtual Attributes

Virtual attributes are attributes that exist on your model but aren't backed by database columns:

```crystal
class Product < Granite::Base
  column id : Int64, primary: true
  column name : String
  
  # Virtual attribute for price calculation
  attribute price_in_cents : Int32, virtual: true
  
  # Convenience methods using virtual attributes
  def price : Float64?
    price_in_cents.try { |cents| cents / 100.0 }
  end
  
  def price=(value : Float64)
    self.price_in_cents = (value * 100).to_i32
  end
end

product = Product.new(name: "Widget")
product.price = 19.99
product.price_in_cents # => 1999
product.price          # => 19.99
```

### Default Values

Attributes can have default values that are applied when the attribute is nil:

```crystal
class Article < Granite::Base
  column id : Int64, primary: true
  column title : String
  
  # Static default value
  attribute status : String?, default: "draft"
  
  # Dynamic default with proc
  attribute code : String?, default: ->(article : Granite::Base) { 
    "ART-#{article.as(Article).id || "NEW"}" 
  }
end

article = Article.new(title: "My Article")
article.status # => "draft"
article.code   # => "ART-NEW"

article.save!
article.code   # => "ART-1" (assuming id is 1)
```

**Important:** When using default values, the attribute type should be nilable (e.g., `String?` instead of `String`) to avoid conflicts with Grant's internal handling.

### Custom Types with Converters

You can use custom types with the attribute macro by providing a converter:

```crystal
# Define your custom type
class ProductMetadata
  include JSON::Serializable
  
  property version : String
  property features : Array(String)
  
  def initialize(@version : String, @features : Array(String))
  end
end

# Define a converter
module ProductMetadataConverter
  extend self
  
  def to_db(value : ProductMetadata?) : Granite::Columns::Type
    value.try(&.to_json)
  end
  
  def from_rs(result : DB::ResultSet) : ProductMetadata?
    if json = result.read(String?)
      ProductMetadata.from_json(json)
    end
  end
end

# Use in your model
class Product < Granite::Base
  column id : Int64, primary: true
  column name : String
  
  # Custom type stored as TEXT in database
  attribute metadata : ProductMetadata?, 
    converter: ProductMetadataConverter, 
    column_type: "TEXT"
end

product = Product.new(name: "Widget")
product.metadata = ProductMetadata.new("1.0", ["waterproof", "durable"])
product.save!
```

## Advanced Features

### Dirty Tracking

Virtual attributes integrate with Grant's dirty tracking:

```crystal
product = Product.create!(name: "Widget")
product.price_in_cents_changed? # => false

product.price_in_cents = 2500
product.price_in_cents_changed? # => true
product.price_in_cents_was      # => nil
product.price_in_cents_change   # => {nil, 2500}
```

### Multiple Attribute Definition

You can define multiple attributes at once:

```crystal
class User < Granite::Base
  column id : Int64, primary: true
  column email : String
  
  # Define multiple virtual attributes
  attribute first_name : String, virtual: true
  attribute last_name : String, virtual: true
  attribute age : Int32?, virtual: true
  
  def full_name : String?
    return nil unless first_name || last_name
    "#{first_name} #{last_name}".strip
  end
end
```

### Checking Virtual Attributes

You can query which attributes are virtual:

```crystal
user = User.new(email: "user@example.com")

# Get all virtual attribute names
user.virtual_attribute_names # => ["first_name", "last_name", "age"]

# Check if specific attribute is virtual
user.virtual_attribute?("age")   # => true
user.virtual_attribute?("email") # => false

# Get all custom attribute names (virtual and non-virtual)
user.custom_attribute_names # => ["first_name", "last_name", "age", ...]
```

## Type Casters

The Attribute API includes helper methods for common type conversions:

```crystal
# String casting
Granite::AttributeApi::TypeCasters.to_string(123)      # => "123"
Granite::AttributeApi::TypeCasters.to_string(nil)      # => nil

# Integer casting
Granite::AttributeApi::TypeCasters.to_int32("123")     # => 123
Granite::AttributeApi::TypeCasters.to_int32("invalid") # => nil

# Float casting
Granite::AttributeApi::TypeCasters.to_float64("123.45") # => 123.45
Granite::AttributeApi::TypeCasters.to_float64(42)       # => 42.0

# Boolean casting
Granite::AttributeApi::TypeCasters.to_bool("true")  # => true
Granite::AttributeApi::TypeCasters.to_bool("1")     # => true
Granite::AttributeApi::TypeCasters.to_bool("false") # => false
Granite::AttributeApi::TypeCasters.to_bool(0)       # => false
```

## Best Practices

### 1. Use Nilable Types with Defaults

When using default values, always use nilable types:

```crystal
# Good
attribute status : String?, default: "active"

# Problematic - may cause issues
attribute status : String, default: "active"
```

### 2. Virtual Attributes for Computed Values

Use virtual attributes for values that can be computed from other attributes:

```crystal
class Order < Granite::Base
  column subtotal : Float64
  column tax_rate : Float64
  
  attribute total : Float64?, virtual: true
  
  def total
    return nil unless subtotal && tax_rate
    subtotal * (1 + tax_rate)
  end
end
```

### 3. Prefer Existing Converters

For complex types, prefer using Grant's existing converter pattern over creating custom casting:

```crystal
# Good - using converter
attribute preferences : UserPreferences?, 
  converter: Granite::Converters::Json(UserPreferences, String),
  column_type: "TEXT"

# Less ideal - manual casting
attribute preferences_json : String?
def preferences
  UserPreferences.from_json(preferences_json) if preferences_json
end
```

## Limitations

1. **Query Scope**: Virtual attributes cannot be used in database queries since they don't exist in the database
2. **Default Value Evaluation**: Default procs are evaluated each time the getter is called when the value is nil
3. **Type Restrictions**: Custom types must be compatible with Grant's type system or use converters

## Migration from Rails

If you're coming from Rails ActiveRecord:

### Rails
```ruby
class Product < ApplicationRecord
  attribute :price_in_cents, :integer, default: 0
  attribute :metadata, :json, default: {}
end
```

### Grant
```crystal
class Product < Granite::Base
  attribute price_in_cents : Int32?, default: 0, virtual: true
  attribute metadata : Hash(String, JSON::Any)?, 
    converter: Granite::Converters::Json(Hash(String, JSON::Any), String),
    column_type: "TEXT",
    default: {} of String => JSON::Any
end
```

## Future Enhancements

The Attribute API is designed to be extended with:
- Custom type casting with the `:cast` option
- Attribute normalization
- Computed attributes with caching
- Integration with form builders

For now, focus on using the existing converter pattern for complex type handling, which provides type-safe serialization and deserialization.