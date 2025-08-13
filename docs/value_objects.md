# Value Objects (Domain-Driven Design Aggregations)

Grant provides support for value objects following Domain-Driven Design patterns. Value objects allow you to compose multiple database columns into cohesive, immutable objects that represent domain concepts.

## Overview

Value objects are small, immutable objects that represent descriptive aspects of the domain with no conceptual identity. They are often composed of multiple attributes that together form a meaningful whole.

Common examples include:
- Address (street, city, zip code)
- Money (amount, currency)
- Temperature (value, unit)
- Coordinates (latitude, longitude)

## Basic Usage

### Defining Value Objects

Value objects are typically defined as structs in Crystal:

```crystal
struct Address
  getter street : String
  getter city : String
  getter zip : String
  
  def initialize(@street : String, @city : String, @zip : String)
  end
  
  def to_s(io)
    io << "#{street}, #{city} #{zip}"
  end
end

struct Money
  getter amount : Float64
  getter currency : String
  
  def initialize(@amount : Float64, @currency : String = "USD")
  end
  
  def to_s(io)
    io << "#{currency} #{amount}"
  end
end
```

### Using Aggregations in Models

Use the `aggregation` macro to map value objects to database columns:

```crystal
class Customer < Grant::Base
  connection pg
  table customers
  
  column id : Int64, primary: true
  column name : String
  
  # Map multiple columns to a value object
  aggregation :address, Address,
    mapping: {
      address_street: :street,    # column_name: :attribute_name
      address_city: :city,
      address_zip: :zip
    }
    
  # Another aggregation
  aggregation :balance, Money,
    mapping: {
      balance_amount: :amount,
      balance_currency: :currency
    }
end
```

### Working with Value Objects

```crystal
# Creating records with value objects
customer = Customer.new(name: "John Doe")
customer.address = Address.new("123 Main St", "Boston", "02101")
customer.balance = Money.new(1000.50, "USD")
customer.save

# Accessing value objects
puts customer.address.city      # => "Boston"
puts customer.balance.amount    # => 1000.5

# Value objects are automatically persisted to columns
puts customer.address_street    # => "123 Main St"
puts customer.balance_amount    # => "1000.5"
```

## Advanced Features

### Custom Constructors

For complex value object initialization, you can provide custom constructors:

```crystal
struct Temperature
  getter celsius : Float64
  
  def initialize(@celsius : Float64)
  end
  
  def fahrenheit
    (celsius * 9.0 / 5.0) + 32.0
  end
end

class Weather < Grant::Base
  aggregation :temperature, Temperature,
    mapping: {
      temp_fahrenheit: :fahrenheit
    },
    constructor: ->(fahrenheit : String?) do
      return nil if fahrenheit.nil?
      # Convert from Fahrenheit to Celsius for storage
      f = fahrenheit.to_f
      celsius = (f - 32.0) * 5.0 / 9.0
      Temperature.new(celsius)
    end
end
```

### Allow Nil Values

By default, aggregations return `nil` if any mapped column is `nil`. Use `allow_nil: true` to return `nil` only when all columns are `nil`:

```crystal
class Order < Grant::Base
  # Returns nil only if both amount and currency are nil
  aggregation :total, Money,
    mapping: {
      total_amount: :amount,
      total_currency: :currency
    },
    allow_nil: true
end
```

### Multiple Aggregations

Models can have multiple aggregations:

```crystal
class Person < Grant::Base
  aggregation :home_address, Address,
    mapping: {
      home_street: :street,
      home_city: :city,
      home_zip: :zip
    }
    
  aggregation :work_address, Address,
    mapping: {
      work_street: :street,
      work_city: :city,
      work_zip: :zip
    }
end
```

## Validation

Value objects can implement validation that integrates with Grant's validation system:

```crystal
struct Email
  getter value : String
  
  def initialize(@value : String)
  end
  
  def validate
    errors = [] of Grant::Error
    unless value.matches?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
      errors << Grant::Error.new(:value, "is not a valid email")
    end
    errors
  end
end

class User < Grant::Base
  aggregation :email, Email,
    mapping: {
      email_address: :value
    }
end

user = User.new
user.email_address = "invalid-email"
user.valid? # => false
user.errors # => includes email validation error
```

## Dirty Tracking

Aggregations support dirty tracking:

```crystal
customer = Customer.find(1)
original_address = customer.address

customer.address = Address.new("456 Elm St", "Cambridge", "02139")

customer.address_changed?      # => true
customer.changed?              # => true
customer.address_was           # => returns original address

customer.save
customer.address_changed?      # => false
```

## Type Conversions

When using value objects, Grant automatically handles type conversions between database strings and value object attributes:

```crystal
struct Price
  getter amount : Float64
  getter tax_rate : Float64
  
  def initialize(@amount : Float64, @tax_rate : Float64)
  end
  
  # Constructor for string arguments (used by Grant)
  def self.new(*, amount : String, tax_rate : String)
    new(amount.to_f64, tax_rate.to_f64)
  end
  
  def total
    amount * (1 + tax_rate)
  end
end
```

## Implementation Details

### Column Storage

All aggregation columns are stored as strings in the database. This provides flexibility but means you need to handle type conversions in your value objects.

### Caching

Value objects are cached per instance to avoid repeated instantiation. The cache is cleared when any mapped column changes.

### Performance

Value objects are instantiated on-demand when accessed. If you don't access an aggregation, the value object won't be created.

## Best Practices

1. **Keep Value Objects Immutable**: Use structs and only provide getters
2. **Implement Equality**: Override `==` for proper comparisons
3. **Provide String Representation**: Implement `to_s` for debugging
4. **Validate in Value Objects**: Put domain validation in the value object
5. **Use Meaningful Names**: Column names should clearly indicate they're part of an aggregation

## Limitations

- All columns are stored as strings (plan for type conversions)
- Value objects cannot have their own persistence logic
- Nested value objects are not supported
- Array/collection aggregations are not supported

## Migration Example

```crystal
class CreateCustomers < Grant::Migration
  def up
    create_table :customers do |t|
      t.string :name, null: false
      
      # Address aggregation columns
      t.string :address_street
      t.string :address_city
      t.string :address_zip
      
      # Balance aggregation columns
      t.string :balance_amount
      t.string :balance_currency
      
      t.timestamps
    end
  end
  
  def down
    drop_table :customers
  end
end
```