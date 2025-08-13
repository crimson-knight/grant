---
title: "Serialized Columns"
category: "advanced"
subcategory: "specialized"
tags: ["serialization", "json", "yaml", "arrays", "hashes", "data-storage", "nosql-in-sql"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../../core-features/models-and-columns.md", "value-objects.md"]
related_docs: ["value-objects.md", "enum-attributes.md", "../../core-features/models-and-columns.md"]
last_updated: "2025-01-13"
estimated_read_time: "16 minutes"
use_cases: ["configuration", "metadata", "flexible-schemas", "user-preferences", "dynamic-attributes"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Serialized Columns

Comprehensive guide to storing and working with serialized data in Grant, including JSON, YAML, arrays, hashes, and custom serialization formats for flexible data storage.

## Overview

Serialized columns allow you to store complex data structures in a single database column. This is useful for:
- Storing configuration or settings
- Flexible schemas that change frequently
- User preferences and metadata
- Arrays and hashes without join tables
- Document-style data in relational databases

Grant provides built-in support for JSON, YAML, and custom serialization formats with type safety and automatic conversion.

## JSON Columns

### Basic JSON Storage

```crystal
class User < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  # JSON column with automatic serialization
  column preferences : JSON::Any = JSON.parse("{}"),
    converter: Grant::Converters::Json(JSON::Any)
  
  # Typed JSON for better safety
  column settings : UserSettings = UserSettings.new,
    converter: Grant::Converters::Json(UserSettings)
end

# Typed JSON structure
struct UserSettings
  include JSON::Serializable
  
  property theme : String = "light"
  property notifications : Bool = true
  property language : String = "en"
  property timezone : String = "UTC"
  property email_frequency : String = "daily"
  
  def initialize(
    @theme = "light",
    @notifications = true,
    @language = "en",
    @timezone = "UTC",
    @email_frequency = "daily"
  )
  end
end

# Usage
user = User.new(name: "John")
user.preferences = JSON.parse(%({
  "dashboard_widgets": ["calendar", "tasks", "notifications"],
  "sidebar_collapsed": false
}))

# Typed settings
user.settings.theme = "dark"
user.settings.notifications = false
user.save!

# Access nested data
widgets = user.preferences["dashboard_widgets"].as_a
puts widgets.first  # => "calendar"
```

### PostgreSQL JSONB

```crystal
class Product < Grant::Base
  connection pg
  table products
  
  column id : Int64, primary: true
  column name : String
  column price : Float64
  
  # JSONB column for better performance and indexing
  column attributes : JSON::Any,
    converter: Grant::Converters::Json(JSON::Any)
  
  column specifications : JSON::Any,
    converter: Grant::Converters::Json(JSON::Any)
  
  # Query JSON data (PostgreSQL)
  scope :with_attribute, ->(key : String, value : String) {
    where("attributes @> ?", {key => value}.to_json)
  }
  
  scope :has_key, ->(key : String) {
    where("attributes ? ?", key)
  }
  
  scope :in_price_range, ->(min : Float64, max : Float64) {
    where("(attributes->>'price')::float BETWEEN ? AND ?", min, max)
  }
end

# Database migration for JSONB
class AddJsonbColumns < Grant::Migration
  def up
    execute <<-SQL
      ALTER TABLE products 
      ADD COLUMN attributes JSONB DEFAULT '{}',
      ADD COLUMN specifications JSONB DEFAULT '{}';
      
      -- Add GIN index for performance
      CREATE INDEX idx_products_attributes ON products USING gin(attributes);
      CREATE INDEX idx_products_specs ON products USING gin(specifications);
    SQL
  end
end
```

### Complex JSON Structures

```crystal
struct Address
  include JSON::Serializable
  
  property street : String
  property city : String
  property state : String
  property zip : String
  property country : String = "USA"
end

struct ContactInfo
  include JSON::Serializable
  
  property email : String
  property phone : String?
  property addresses : Array(Address) = [] of Address
  property social_media : Hash(String, String) = {} of String => String
end

class Customer < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  column contact_info : ContactInfo = ContactInfo.new,
    converter: Grant::Converters::Json(ContactInfo)
  
  def primary_address : Address?
    contact_info.addresses.first?
  end
  
  def add_address(address : Address)
    contact_info.addresses << address
  end
  
  def social_link(platform : String) : String?
    contact_info.social_media[platform]?
  end
end

# Usage
customer = Customer.new(name: "ACME Corp")
customer.contact_info.email = "contact@acme.com"
customer.add_address(Address.new(
  street: "123 Business St",
  city: "New York",
  state: "NY",
  zip: "10001"
))
customer.contact_info.social_media["twitter"] = "@acmecorp"
customer.save!
```

## Array and Hash Columns

### Array Storage

```crystal
class Article < Grant::Base
  column id : Int64, primary: true
  column title : String
  
  # Array of strings
  column tags : Array(String) = [] of String,
    converter: Grant::Converters::Json(Array(String))
  
  # Array of integers
  column related_ids : Array(Int64) = [] of Int64,
    converter: Grant::Converters::Json(Array(Int64))
  
  # Array of custom types
  column authors : Array(Author) = [] of Author,
    converter: Grant::Converters::Json(Array(Author))
  
  def add_tag(tag : String)
    tags << tag unless tags.includes?(tag)
  end
  
  def remove_tag(tag : String)
    tags.delete(tag)
  end
  
  def tagged_with?(tag : String) : Bool
    tags.includes?(tag)
  end
  
  def related_articles
    Article.where(id: related_ids)
  end
end

struct Author
  include JSON::Serializable
  
  property name : String
  property email : String
  property role : String = "writer"
end
```

### Hash Storage

```crystal
class Configuration < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  # Simple hash
  column settings : Hash(String, String) = {} of String => String,
    converter: Grant::Converters::Json(Hash(String, String))
  
  # Nested hash
  column features : Hash(String, JSON::Any) = {} of String => JSON::Any,
    converter: Grant::Converters::Json(Hash(String, JSON::Any))
  
  def get_setting(key : String, default : String? = nil) : String?
    settings[key]? || default
  end
  
  def set_setting(key : String, value : String)
    settings[key] = value
  end
  
  def feature_enabled?(feature : String) : Bool
    features[feature]?.try(&.["enabled"].as_bool) || false
  end
  
  def feature_config(feature : String) : JSON::Any?
    features[feature]?
  end
end

# Usage
config = Configuration.new(name: "app_config")
config.set_setting("theme", "dark")
config.set_setting("language", "en")

config.features["analytics"] = JSON.parse(%({
  "enabled": true,
  "provider": "google",
  "tracking_id": "UA-123456"
}))

config.save!
```

## YAML Serialization

```crystal
require "yaml"

class Template < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  # YAML column for human-readable configuration
  column content : YAML::Any,
    converter: Grant::Converters::Yaml(YAML::Any)
  
  column variables : Hash(String, String),
    converter: Grant::Converters::Yaml(Hash(String, String))
end

# Custom YAML converter
module Grant::Converters
  class Yaml(T)
    def self.from_rs(rs)
      yaml_str = rs.read(String)
      return nil if yaml_str.nil?
      T.from_yaml(yaml_str)
    end
    
    def self.to_db(value : T?)
      return nil if value.nil?
      value.to_yaml
    end
  end
end

# Usage
template = Template.new(name: "email_template")
template.content = YAML.parse(<<-YAML
subject: Welcome to our service
body: |
  Hello {{name}},
  
  Welcome to our platform!
  Your account has been created successfully.
  
sections:
  - header: "Getting Started"
    content: "Here are some tips..."
  - header: "Support"
    content: "Contact us at support@example.com"
YAML
)

template.variables = {
  "name" => "John Doe",
  "company" => "ACME Corp"
}
template.save!
```

## Custom Serialization

### MessagePack Serialization

```crystal
require "message_pack"

struct BinaryData
  include MessagePack::Serializable
  
  property version : Int32
  property compressed : Bool
  property data : Bytes
  property metadata : Hash(String, String)
end

module Grant::Converters
  class MessagePackConverter(T)
    def self.from_rs(rs)
      bytes = rs.read(Bytes)
      return nil if bytes.nil?
      T.from_msgpack(bytes)
    end
    
    def self.to_db(value : T?)
      return nil if value.nil?
      value.to_msgpack
    end
  end
end

class BinaryDocument < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  column payload : BinaryData,
    converter: Grant::Converters::MessagePackConverter(BinaryData)
end
```

### Custom Binary Format

```crystal
struct CompressedData
  getter original_size : Int32
  getter compressed_data : Bytes
  getter algorithm : String
  
  def initialize(@original_size, @compressed_data, @algorithm = "gzip")
  end
  
  def decompress : Bytes
    case algorithm
    when "gzip"
      Compress::Gzip::Reader.open(IO::Memory.new(compressed_data)) do |gzip|
        gzip.gets_to_end.to_slice
      end
    else
      compressed_data
    end
  end
end

module Grant::Converters
  class CompressedConverter
    def self.from_rs(rs)
      bytes = rs.read(Bytes)
      return nil if bytes.nil?
      
      io = IO::Memory.new(bytes)
      original_size = io.read_bytes(Int32)
      algorithm_len = io.read_bytes(Int32)
      algorithm = io.read_string(algorithm_len)
      compressed_data = io.to_slice[io.pos..]
      
      CompressedData.new(original_size, compressed_data, algorithm)
    end
    
    def self.to_db(value : CompressedData?)
      return nil if value.nil?
      
      io = IO::Memory.new
      io.write_bytes(value.original_size)
      io.write_bytes(value.algorithm.bytesize)
      io.write(value.algorithm.to_slice)
      io.write(value.compressed_data)
      io.to_slice
    end
  end
end
```

## Advanced Patterns

### Dynamic Attributes

```crystal
class FlexibleModel < Grant::Base
  column id : Int64, primary: true
  column type : String
  
  # Store dynamic attributes
  column data : JSON::Any = JSON.parse("{}"),
    converter: Grant::Converters::Json(JSON::Any)
  
  # Dynamic getter/setter
  macro method_missing(call)
    {% if call.name.ends_with?("=") %}
      def {{call.name}}(value)
        data_hash = data.as_h
        data_hash[{{call.name.stringify[0...-1]}}] = JSON::Any.new(value)
        self.data = JSON::Any.new(data_hash)
      end
    {% else %}
      def {{call.name}}
        data[{{call.name.stringify}}]?
      end
    {% end %}
  end
  
  def get_attribute(key : String) : JSON::Any?
    data[key]?
  end
  
  def set_attribute(key : String, value : JSON::Any::Type)
    data_hash = data.as_h
    data_hash[key] = JSON::Any.new(value)
    self.data = JSON::Any.new(data_hash)
  end
  
  def attributes_hash : Hash(String, JSON::Any)
    data.as_h
  end
end

# Usage with dynamic attributes
model = FlexibleModel.new(type: "product")
model.set_attribute("price", 29.99)
model.set_attribute("color", "blue")
model.set_attribute("in_stock", true)
model.save!
```

### Versioned Serialization

```crystal
class VersionedData < Grant::Base
  column id : Int64, primary: true
  column schema_version : Int32 = 1
  
  column data : JSON::Any,
    converter: Grant::Converters::Json(JSON::Any)
  
  def migrate_to_latest!
    while schema_version < LATEST_VERSION
      migrate_to_version(schema_version + 1)
      self.schema_version += 1
    end
    save!
  end
  
  private def migrate_to_version(version : Int32)
    case version
    when 2
      # Migrate from v1 to v2
      migrate_v1_to_v2
    when 3
      # Migrate from v2 to v3
      migrate_v2_to_v3
    end
  end
  
  private def migrate_v1_to_v2
    # Example: Rename field
    if old_value = data["old_field"]?
      data_hash = data.as_h
      data_hash["new_field"] = old_value
      data_hash.delete("old_field")
      self.data = JSON::Any.new(data_hash)
    end
  end
  
  private def migrate_v2_to_v3
    # Example: Change structure
    if old_settings = data["settings"]?
      data_hash = data.as_h
      data_hash["config"] = JSON::Any.new({
        "user_settings" => old_settings,
        "app_settings" => JSON::Any.new({} of String => JSON::Any)
      })
      data_hash.delete("settings")
      self.data = JSON::Any.new(data_hash)
    end
  end
  
  LATEST_VERSION = 3
end
```

### Encrypted Serialization

```crystal
require "openssl"

module Grant::Converters
  class EncryptedJson(T)
    @@key = ENV["ENCRYPTION_KEY"]
    
    def self.from_rs(rs)
      encrypted = rs.read(String)
      return nil if encrypted.nil?
      
      decrypted = decrypt(encrypted)
      T.from_json(decrypted)
    end
    
    def self.to_db(value : T?)
      return nil if value.nil?
      
      json = value.to_json
      encrypt(json)
    end
    
    private def self.encrypt(data : String) : String
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      cipher.key = @@key
      iv = cipher.random_iv
      
      encrypted = cipher.update(data) + cipher.final
      Base64.encode(iv + encrypted)
    end
    
    private def self.decrypt(data : String) : String
      decoded = Base64.decode(data)
      iv = decoded[0...16]
      encrypted = decoded[16..]
      
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      cipher.key = @@key
      cipher.iv = iv
      
      String.new(cipher.update(encrypted) + cipher.final)
    end
  end
end

class SecureDocument < Grant::Base
  column id : Int64, primary: true
  
  # Encrypted JSON storage
  column sensitive_data : JSON::Any,
    converter: Grant::Converters::EncryptedJson(JSON::Any)
end
```

## Query Patterns

### JSON Queries (PostgreSQL)

```crystal
class Event < Grant::Base
  column id : Int64, primary: true
  column type : String
  column payload : JSON::Any,
    converter: Grant::Converters::Json(JSON::Any)
  
  # Query JSON fields
  scope :by_user, ->(user_id : Int64) {
    where("payload->>'user_id' = ?", user_id.to_s)
  }
  
  scope :with_tag, ->(tag : String) {
    where("payload->'tags' ? ?", tag)
  }
  
  scope :in_range, ->(field : String, min : Float64, max : Float64) {
    where("(payload->>?)::float BETWEEN ? AND ?", field, min, max)
  }
  
  # Complex JSON queries
  scope :matching_criteria, ->(criteria : Hash(String, String)) {
    conditions = criteria.map { |k, v| "payload->>'#{k}' = '#{v}'" }.join(" AND ")
    where(conditions)
  }
end

# Usage
events = Event.by_user(123)
              .with_tag("important")
              .in_range("score", 80.0, 100.0)
```

### Array Operations (PostgreSQL)

```crystal
class TaggedItem < Grant::Base
  column id : Int64, primary: true
  column tags : Array(String),
    converter: Grant::Converters::Json(Array(String))
  
  # Array contains
  scope :has_tag, ->(tag : String) {
    where("tags @> ?", [tag].to_json)
  }
  
  # Array overlap
  scope :has_any_tag, ->(tags : Array(String)) {
    where("tags && ?", tags.to_json)
  }
  
  # Array length
  scope :tag_count, ->(count : Int32) {
    where("jsonb_array_length(tags) = ?", count)
  }
end
```

## Performance Considerations

### Indexing Strategies

```sql
-- PostgreSQL GIN indexes for JSON
CREATE INDEX idx_json_data ON table_name USING gin(json_column);

-- Index specific JSON path
CREATE INDEX idx_json_field ON table_name USING btree((json_column->>'field_name'));

-- Partial index for JSON conditions
CREATE INDEX idx_active_json ON table_name USING gin(json_column) 
WHERE json_column->>'status' = 'active';

-- Array contains index
CREATE INDEX idx_array_tags ON table_name USING gin(tags);
```

### Query Optimization

```crystal
# Efficient: Use database JSON operators
Product.where("attributes @> ?", {color: "red"}.to_json)

# Inefficient: Load all and filter in memory
Product.all.select { |p| p.attributes["color"] == "red" }

# Efficient: Indexed path query
User.where("(preferences->>'theme')::text = ?", "dark")

# Consider materialized views for complex JSON queries
class MaterializedProductView < Grant::Base
  # Pre-computed JSON extractions
  column id : Int64
  column name : String
  column color : String  # Extracted from JSON
  column size : String   # Extracted from JSON
end
```

## Testing Serialized Columns

```crystal
describe Article do
  describe "serialized columns" do
    it "stores and retrieves arrays" do
      article = Article.create!(
        title: "Test",
        tags: ["crystal", "orm", "database"]
      )
      
      reloaded = Article.find!(article.id)
      reloaded.tags.should eq(["crystal", "orm", "database"])
    end
    
    it "stores complex JSON structures" do
      customer = Customer.create!(
        name: "Test Corp",
        contact_info: ContactInfo.from_json(%({
          "email": "test@example.com",
          "addresses": [{
            "street": "123 Test St",
            "city": "Boston",
            "state": "MA",
            "zip": "02101"
          }]
        }))
      )
      
      reloaded = Customer.find!(customer.id)
      reloaded.primary_address.not_nil!.city.should eq("Boston")
    end
    
    it "queries JSON data" do
      Event.create!(
        type: "click",
        payload: JSON.parse(%({"user_id": 123, "page": "/home"}))
      )
      
      Event.by_user(123).count.should eq(1)
    end
  end
end
```

## Best Practices

### 1. Choose the Right Format

```crystal
# JSON for structured data and queries
column config : JSON::Any

# YAML for human-editable configuration
column template : YAML::Any

# MessagePack for binary efficiency
column binary_data : BinaryData
```

### 2. Use Typed Structures

```crystal
# Good: Type-safe structure
struct Settings
  include JSON::Serializable
  property theme : String
  property notifications : Bool
end

column settings : Settings

# Less ideal: Untyped JSON
column settings : JSON::Any
```

### 3. Consider Database Support

```crystal
# PostgreSQL: Native JSONB support
column data : JSON::Any  # Use JSONB column type

# MySQL: JSON column type (5.7+)
column data : JSON::Any  # Use JSON column type

# SQLite: Store as TEXT
column data : JSON::Any  # Stored as TEXT, parsed in app
```

### 4. Validate Serialized Data

```crystal
class ConfigModel < Grant::Base
  column config : JSON::Any
  
  validate :config_structure
  
  private def config_structure
    required_keys = ["version", "settings", "features"]
    missing_keys = required_keys - config.as_h.keys
    
    if missing_keys.any?
      errors.add(:config, "missing required keys: #{missing_keys.join(", ")}")
    end
  end
end
```

## Next Steps

- [Value Objects](value-objects.md)
- [Enum Attributes](enum-attributes.md)
- [Polymorphic Associations](polymorphic-associations.md)
- [Models and Columns](../../core-features/models-and-columns.md)