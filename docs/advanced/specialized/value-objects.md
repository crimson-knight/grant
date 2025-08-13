---
title: "Value Objects and DDD Aggregations"
category: "advanced"
subcategory: "specialized"
tags: ["value-objects", "ddd", "domain-driven-design", "aggregations", "immutable", "composition"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../../core-features/models-and-columns.md", "../../core-features/relationships.md"]
related_docs: ["enum-attributes.md", "serialized-columns.md", "../../core-features/models-and-columns.md"]
last_updated: "2025-01-13"
estimated_read_time: "18 minutes"
use_cases: ["domain-modeling", "complex-types", "business-logic", "data-integrity"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Value Objects and DDD Aggregations

Comprehensive guide to implementing value objects and Domain-Driven Design patterns in Grant, allowing you to compose multiple database columns into cohesive, immutable objects that represent domain concepts.

## Overview

Value objects are fundamental building blocks in Domain-Driven Design (DDD). They are small, immutable objects that represent descriptive aspects of the domain with no conceptual identity. Unlike entities, value objects are defined by their attributes rather than an identity.

### Key Characteristics

- **Immutability**: Once created, value objects cannot be changed
- **Equality by Value**: Two value objects with same values are considered equal
- **Side-Effect Free**: Methods don't modify state
- **Self-Contained**: Encapsulate related data and behavior

### Common Examples

- **Address**: Street, city, state, zip code
- **Money**: Amount and currency
- **DateRange**: Start and end dates
- **Coordinates**: Latitude and longitude
- **PhoneNumber**: Country code, area code, number
- **Email**: Local part and domain

## Basic Implementation

### Defining Value Objects

```crystal
# Simple value object using struct (immutable by default)
struct Address
  getter street : String
  getter city : String
  getter state : String
  getter zip_code : String
  getter country : String
  
  def initialize(@street : String, @city : String, @state : String, 
                 @zip_code : String, @country : String = "USA")
  end
  
  # Equality by value
  def ==(other : Address) : Bool
    street == other.street &&
    city == other.city &&
    state == other.state &&
    zip_code == other.zip_code &&
    country == other.country
  end
  
  # String representation
  def to_s(io)
    io << "#{street}, #{city}, #{state} #{zip_code}, #{country}"
  end
  
  # Validation
  def valid?
    !street.empty? && !city.empty? && 
    !state.empty? && zip_code.matches?(/^\d{5}(-\d{4})?$/)
  end
  
  # Domain logic
  def domestic?
    country == "USA"
  end
  
  def international?
    !domestic?
  end
end
```

### Money Value Object

```crystal
struct Money
  include Comparable(Money)
  
  getter amount : BigDecimal
  getter currency : String
  
  def initialize(amount : Number, @currency : String = "USD")
    @amount = BigDecimal.new(amount.to_s)
  end
  
  # Arithmetic operations return new instances
  def +(other : Money) : Money
    ensure_same_currency!(other)
    Money.new(amount + other.amount, currency)
  end
  
  def -(other : Money) : Money
    ensure_same_currency!(other)
    Money.new(amount - other.amount, currency)
  end
  
  def *(multiplier : Number) : Money
    Money.new(amount * multiplier, currency)
  end
  
  def /(divisor : Number) : Money
    Money.new(amount / divisor, currency)
  end
  
  # Comparison
  def <=>(other : Money)
    ensure_same_currency!(other)
    amount <=> other.amount
  end
  
  # Formatting
  def to_s(io)
    io << currency << " " << formatted_amount
  end
  
  def formatted_amount
    "%.2f" % amount
  end
  
  # Currency conversion
  def convert_to(target_currency : String, rate : Float64) : Money
    Money.new(amount * rate, target_currency)
  end
  
  private def ensure_same_currency!(other : Money)
    unless currency == other.currency
      raise ArgumentError.new("Cannot operate on different currencies: #{currency} and #{other.currency}")
    end
  end
end
```

## Using Aggregations in Models

### Basic Aggregation Mapping

```crystal
class Customer < Grant::Base
  connection pg
  table customers
  
  column id : Int64, primary: true
  column name : String
  column email : String
  
  # Database columns for address
  column address_street : String
  column address_city : String
  column address_state : String
  column address_zip : String
  column address_country : String
  
  # Database columns for balance
  column balance_amount : Float64
  column balance_currency : String
  
  # Map columns to value objects
  aggregation :address, Address,
    mapping: {
      address_street: :street,
      address_city: :city,
      address_state: :state,
      address_zip: :zip_code,
      address_country: :country
    }
  
  aggregation :balance, Money,
    mapping: {
      balance_amount: :amount,
      balance_currency: :currency
    }
end

# Usage
customer = Customer.new(name: "John Doe", email: "john@example.com")
customer.address = Address.new("123 Main St", "Boston", "MA", "02101")
customer.balance = Money.new(1500.50, "USD")
customer.save!

# Access value object properties
puts customer.address.city       # => "Boston"
puts customer.balance.amount     # => 1500.50
puts customer.address.domestic?  # => true
```

### Custom Constructor and Converter

```crystal
class PhoneNumber
  getter country_code : String
  getter area_code : String
  getter number : String
  getter extension : String?
  
  def initialize(@country_code, @area_code, @number, @extension = nil)
  end
  
  # Parse from string
  def self.parse(str : String) : PhoneNumber
    # Parse "+1-555-123-4567 ext 890"
    match = str.match(/^\+?(\d+)-(\d{3})-(\d{3})-(\d{4})(?:\s+ext\s+(\d+))?$/)
    raise ArgumentError.new("Invalid phone number format") unless match
    
    new(
      match[1],
      match[2], 
      "#{match[3]}-#{match[4]}",
      match[5]?
    )
  end
  
  def to_s(io)
    io << "+#{country_code}-#{area_code}-#{number}"
    io << " ext #{extension}" if extension
  end
  
  def international?
    country_code != "1"
  end
end

class Contact < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  # Store as single column
  column phone_number_str : String
  
  # Custom converter for aggregation
  aggregation :phone_number, PhoneNumber,
    constructor: ->(str : String) { PhoneNumber.parse(str) },
    converter: ->(phone : PhoneNumber) { phone.to_s }
end
```

## Complex Value Objects

### Date Range Value Object

```crystal
struct DateRange
  getter start_date : Time
  getter end_date : Time
  
  def initialize(@start_date : Time, @end_date : Time)
    raise ArgumentError.new("End date must be after start date") if @end_date < @start_date
  end
  
  def duration : Time::Span
    end_date - start_date
  end
  
  def days : Int32
    duration.days.to_i
  end
  
  def includes?(date : Time) : Bool
    date >= start_date && date <= end_date
  end
  
  def overlaps?(other : DateRange) : Bool
    start_date <= other.end_date && end_date >= other.start_date
  end
  
  def to_s(io)
    io << start_date.to_s("%Y-%m-%d") << " to " << end_date.to_s("%Y-%m-%d")
  end
end

class Reservation < Grant::Base
  column id : Int64, primary: true
  column guest_name : String
  column check_in : Time
  column check_out : Time
  
  aggregation :stay_period, DateRange,
    mapping: {
      check_in: :start_date,
      check_out: :end_date
    }
  
  def conflicts_with?(other : Reservation) : Bool
    stay_period.overlaps?(other.stay_period)
  end
  
  def nights : Int32
    stay_period.days
  end
end
```

### Composite Value Objects

```crystal
struct Dimensions
  getter length : Float64
  getter width : Float64
  getter height : Float64
  getter unit : String
  
  def initialize(@length, @width, @height, @unit = "cm")
  end
  
  def volume : Float64
    length * width * height
  end
  
  def surface_area : Float64
    2 * (length * width + length * height + width * height)
  end
  
  def weight_estimate(density : Float64) : Float64
    volume * density
  end
  
  def shipping_size : String
    case volume
    when 0..1000 then "Small"
    when 1001..10000 then "Medium"
    when 10001..100000 then "Large"
    else "Oversized"
    end
  end
end

struct Weight
  getter value : Float64
  getter unit : String
  
  def initialize(@value, @unit = "kg")
  end
  
  def in_kg : Float64
    case unit
    when "kg" then value
    when "g" then value / 1000
    when "lb" then value * 0.453592
    else raise "Unknown unit: #{unit}"
    end
  end
end

class Product < Grant::Base
  column id : Int64, primary: true
  column name : String
  column sku : String
  
  # Dimension columns
  column length : Float64
  column width : Float64
  column height : Float64
  column dimension_unit : String
  
  # Weight columns
  column weight_value : Float64
  column weight_unit : String
  
  aggregation :dimensions, Dimensions,
    mapping: {
      length: :length,
      width: :width,
      height: :height,
      dimension_unit: :unit
    }
  
  aggregation :weight, Weight,
    mapping: {
      weight_value: :value,
      weight_unit: :unit
    }
  
  def shipping_cost : Money
    base_cost = case dimensions.shipping_size
    when "Small" then 5.99
    when "Medium" then 12.99
    when "Large" then 24.99
    else 49.99
    end
    
    # Add weight surcharge
    weight_surcharge = weight.in_kg > 10 ? (weight.in_kg - 10) * 2 : 0
    
    Money.new(base_cost + weight_surcharge, "USD")
  end
end
```

## Advanced Patterns

### Nested Value Objects

```crystal
struct GeoCoordinate
  getter latitude : Float64
  getter longitude : Float64
  
  def initialize(@latitude, @longitude)
    raise ArgumentError.new("Invalid latitude") unless (-90..90).includes?(latitude)
    raise ArgumentError.new("Invalid longitude") unless (-180..180).includes?(longitude)
  end
  
  def distance_to(other : GeoCoordinate) : Float64
    # Haversine formula
    r = 6371 # Earth's radius in km
    
    lat1_rad = latitude * Math::PI / 180
    lat2_rad = other.latitude * Math::PI / 180
    delta_lat = (other.latitude - latitude) * Math::PI / 180
    delta_lon = (other.longitude - longitude) * Math::PI / 180
    
    a = Math.sin(delta_lat/2) ** 2 +
        Math.cos(lat1_rad) * Math.cos(lat2_rad) *
        Math.sin(delta_lon/2) ** 2
    
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
    r * c
  end
end

struct Location
  getter name : String
  getter coordinate : GeoCoordinate
  getter address : Address
  
  def initialize(@name, @coordinate, @address)
  end
  
  def distance_to(other : Location) : Float64
    coordinate.distance_to(other.coordinate)
  end
end

class Store < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  # Nested aggregation columns
  column location_name : String
  column latitude : Float64
  column longitude : Float64
  column address_street : String
  column address_city : String
  column address_state : String
  column address_zip : String
  column address_country : String
  
  # Complex nested aggregation
  aggregation :location, Location,
    constructor: ->(name, lat, lon, street, city, state, zip, country) {
      coord = GeoCoordinate.new(lat, lon)
      addr = Address.new(street, city, state, zip, country)
      Location.new(name, coord, addr)
    },
    mapping: {
      location_name: 0,
      latitude: 1,
      longitude: 2,
      address_street: 3,
      address_city: 4,
      address_state: 5,
      address_zip: 6,
      address_country: 7
    }
  
  def nearby_stores(radius_km : Float64)
    Store.all.select do |store|
      next false if store.id == self.id
      location.distance_to(store.location) <= radius_km
    end
  end
end
```

### Value Object Collections

```crystal
struct Tag
  getter name : String
  getter color : String
  
  def initialize(@name, @color = "#000000")
  end
  
  def to_s(io)
    io << name
  end
end

class Article < Grant::Base
  column id : Int64, primary: true
  column title : String
  column content : String
  
  # Store as JSON
  column tags_json : JSON::Any
  
  # Collection aggregation
  aggregation :tags, Array(Tag),
    constructor: ->(json : JSON::Any) {
      json.as_a.map { |t| Tag.new(t["name"].as_s, t["color"].as_s) }
    },
    converter: ->(tags : Array(Tag)) {
      JSON.parse(tags.map { |t| {name: t.name, color: t.color} }.to_json)
    }
  
  def has_tag?(name : String) : Bool
    tags.any? { |t| t.name == name }
  end
  
  def tags_by_color(color : String) : Array(Tag)
    tags.select { |t| t.color == color }
  end
end
```

### Validation and Business Rules

```crystal
struct EmailAddress
  getter value : String
  
  def initialize(value : String)
    @value = value.downcase.strip
    validate!
  end
  
  private def validate!
    unless @value.matches?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
      raise ArgumentError.new("Invalid email format: #{@value}")
    end
  end
  
  def domain : String
    value.split("@").last
  end
  
  def local_part : String
    value.split("@").first
  end
  
  def corporate? : Bool
    !domain.in?(["gmail.com", "yahoo.com", "hotmail.com", "outlook.com"])
  end
end

struct Password
  getter hash : String
  getter salt : String
  
  def initialize(plain_text : String)
    validate_strength!(plain_text)
    @salt = Random::Secure.hex(16)
    @hash = hash_password(plain_text, @salt)
  end
  
  def self.from_hash(hash : String, salt : String)
    instance = allocate
    instance.initialize_from_hash(hash, salt)
    instance
  end
  
  protected def initialize_from_hash(@hash, @salt)
  end
  
  def verify(plain_text : String) : Bool
    hash == hash_password(plain_text, salt)
  end
  
  private def hash_password(text : String, salt : String) : String
    Digest::SHA256.hexdigest("#{text}:#{salt}")
  end
  
  private def validate_strength!(text : String)
    raise ArgumentError.new("Password too short") if text.size < 8
    raise ArgumentError.new("Password needs uppercase") unless text.matches?(/[A-Z]/)
    raise ArgumentError.new("Password needs lowercase") unless text.matches?(/[a-z]/)
    raise ArgumentError.new("Password needs number") unless text.matches?(/\d/)
  end
end

class User < Grant::Base
  column id : Int64, primary: true
  column username : String
  column email_value : String
  column password_hash : String
  column password_salt : String
  
  aggregation :email, EmailAddress,
    constructor: ->(value : String) { EmailAddress.new(value) },
    converter: ->(email : EmailAddress) { email.value }
  
  aggregation :password, Password,
    constructor: ->(hash : String, salt : String) { Password.from_hash(hash, salt) },
    converter: ->(pwd : Password) { {pwd.hash, pwd.salt} },
    mapping: {
      password_hash: 0,
      password_salt: 1
    }
  
  def corporate_email? : Bool
    email.corporate?
  end
  
  def authenticate(password_attempt : String) : Bool
    password.verify(password_attempt)
  end
  
  def change_password(new_password : String)
    self.password = Password.new(new_password)
  end
end
```

## Testing Value Objects

```crystal
describe Address do
  describe "initialization" do
    it "creates valid address" do
      address = Address.new("123 Main St", "Boston", "MA", "02101", "USA")
      address.street.should eq("123 Main St")
      address.valid?.should be_true
    end
    
    it "validates zip code format" do
      address = Address.new("123 Main St", "Boston", "MA", "invalid", "USA")
      address.valid?.should be_false
    end
  end
  
  describe "equality" do
    it "compares by value" do
      addr1 = Address.new("123 Main St", "Boston", "MA", "02101")
      addr2 = Address.new("123 Main St", "Boston", "MA", "02101")
      
      addr1.should eq(addr2)
      addr1.object_id.should_not eq(addr2.object_id)
    end
  end
  
  describe "immutability" do
    it "cannot be modified after creation" do
      address = Address.new("123 Main St", "Boston", "MA", "02101")
      # Struct fields are immutable by default
      # address.street = "456 Oak St" # Compilation error
    end
  end
end

describe Customer do
  describe "aggregations" do
    it "persists value objects to columns" do
      customer = Customer.create!(
        name: "John Doe",
        email: "john@example.com",
        address: Address.new("123 Main St", "Boston", "MA", "02101"),
        balance: Money.new(1000, "USD")
      )
      
      # Check database columns
      customer.address_street.should eq("123 Main St")
      customer.balance_amount.should eq(1000.0)
      
      # Check value objects
      customer.address.should be_a(Address)
      customer.balance.should be_a(Money)
    end
    
    it "loads value objects from database" do
      customer = Customer.create!(
        name: "John Doe",
        email: "john@example.com",
        address: Address.new("123 Main St", "Boston", "MA", "02101"),
        balance: Money.new(1000, "USD")
      )
      
      loaded = Customer.find!(customer.id)
      loaded.address.city.should eq("Boston")
      loaded.balance.currency.should eq("USD")
    end
  end
end
```

## Best Practices

### 1. Keep Value Objects Small and Focused

```crystal
# Good: Single responsibility
struct Temperature
  getter value : Float64
  getter unit : String
  
  def in_celsius : Float64
    case unit
    when "C" then value
    when "F" then (value - 32) * 5/9
    when "K" then value - 273.15
    end
  end
end

# Bad: Too many responsibilities
struct Weather
  getter temperature : Float64
  getter humidity : Float64
  getter pressure : Float64
  getter wind_speed : Float64
  # Too complex for a value object
end
```

### 2. Make Value Objects Immutable

```crystal
# Good: Immutable struct
struct Price
  getter amount : BigDecimal
  getter currency : String
  
  def with_discount(percent : Float64) : Price
    Price.new(amount * (1 - percent/100), currency)
  end
end

# Bad: Mutable class
class MutablePrice
  property amount : BigDecimal
  property currency : String
  
  def apply_discount!(percent : Float64)
    @amount = @amount * (1 - percent/100)
  end
end
```

### 3. Implement Meaningful Equality

```crystal
struct Color
  getter red : UInt8
  getter green : UInt8
  getter blue : UInt8
  
  def ==(other : Color) : Bool
    red == other.red && green == other.green && blue == other.blue
  end
  
  def similar_to?(other : Color, tolerance : Int32 = 10) : Bool
    (red - other.red).abs <= tolerance &&
    (green - other.green).abs <= tolerance &&
    (blue - other.blue).abs <= tolerance
  end
end
```

### 4. Provide Factory Methods

```crystal
struct Duration
  getter seconds : Int64
  
  def initialize(@seconds)
  end
  
  # Factory methods for common cases
  def self.minutes(n : Int32) : Duration
    new(n * 60)
  end
  
  def self.hours(n : Int32) : Duration
    new(n * 3600)
  end
  
  def self.days(n : Int32) : Duration
    new(n * 86400)
  end
  
  def self.parse(str : String) : Duration
    # Parse "2h 30m" format
    # Implementation...
  end
end
```

## Performance Considerations

### Caching Value Objects

```crystal
class Product < Grant::Base
  @dimensions_cache : Dimensions?
  @weight_cache : Weight?
  
  aggregation :dimensions, Dimensions,
    mapping: {length: :length, width: :width, height: :height}
  
  # Override getter for caching
  def dimensions : Dimensions
    @dimensions_cache ||= build_dimensions
  end
  
  # Clear cache on save
  after_save :clear_value_object_cache
  
  private def clear_value_object_cache
    @dimensions_cache = nil
    @weight_cache = nil
  end
end
```

### Lazy Loading

```crystal
class Order < Grant::Base
  # Load expensive value objects only when needed
  aggregation :shipping_address, Address,
    lazy: true,
    mapping: {
      ship_street: :street,
      ship_city: :city,
      ship_state: :state,
      ship_zip: :zip_code
    }
end
```

## Next Steps

- [Enum Attributes](enum-attributes.md)
- [Polymorphic Associations](polymorphic-associations.md)
- [Serialized Columns](serialized-columns.md)
- [Models and Columns](../../core-features/models-and-columns.md)