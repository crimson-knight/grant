---
title: "Models and Columns"
category: "core-features"
subcategory: "models"
tags: ["models", "columns", "orm", "database", "schema", "types"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../getting-started/installation.md", "../getting-started/first-model.md"]
related_docs: ["crud-operations.md", "validations.md", "relationships.md", "../advanced/specialized/serialized-columns.md"]
last_updated: "2025-01-13"
estimated_read_time: "12 minutes"
use_cases: ["database-modeling", "schema-design", "data-types"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Models and Columns

Comprehensive guide to defining models, configuring columns, and working with data types in Grant ORM.

## Model Basics

Models in Grant represent database tables and provide an object-oriented interface for data interaction.

### Basic Model Definition

```crystal
class User < Grant::Base
  connection pg        # Database connection to use
  table users         # Table name (optional, defaults to pluralized class name)
  
  column id : Int64, primary: true
  column name : String
  column email : String
  
  timestamps          # Adds created_at and updated_at
end
```

### Model Components

- **Inheritance**: All models inherit from `Grant::Base`
- **Connection**: Specifies which database adapter to use
- **Table**: Maps to a database table
- **Columns**: Define the schema and data types
- **Behavior**: Validations, callbacks, associations, scopes

## Column Definition

### Basic Syntax

```crystal
column column_name : ColumnType, options
```

### Column Options

| Option | Description | Example |
|--------|-------------|---------|
| `primary: true` | Marks as primary key | `column id : Int64, primary: true` |
| `auto: false` | Disables auto-increment | `column uuid : String, primary: true, auto: false` |
| `converter:` | Custom type converter | `column data : JSON::Any, converter: Grant::Converters::Json` |
| `nil: false` | Makes column required | `column name : String, nil: false` |
| Default value | Sets default | `column active : Bool = true` |

## Supported Data Types

### Primitive Types

```crystal
class Product < Grant::Base
  connection pg
  
  # Integer types
  column id : Int64, primary: true      # BIGINT
  column quantity : Int32                # INTEGER
  column position : Int16                # SMALLINT
  column status_code : Int8              # TINYINT
  
  # Floating point
  column price : Float64                 # DOUBLE PRECISION
  column rating : Float32                # FLOAT
  
  # String types
  column name : String                   # VARCHAR/TEXT
  column description : String?           # Nullable string
  
  # Boolean
  column active : Bool = true            # BOOLEAN
  column featured : Bool = false
  
  # Time/Date
  column published_at : Time?            # TIMESTAMP
  column expires_on : Time?
  
  timestamps                             # created_at, updated_at
end
```

### Special Types

```crystal
class AdvancedModel < Grant::Base
  connection pg
  
  # UUID (PostgreSQL, MySQL 8+)
  column id : UUID, primary: true
  
  # JSON (PostgreSQL JSONB, MySQL JSON, SQLite TEXT)
  column metadata : JSON::Any?
  column settings : JSON::Any = JSON.parse("{}")
  
  # Arrays (PostgreSQL only)
  column tags : Array(String)?
  column scores : Array(Int32)?
  column prices : Array(Float64)?
  
  # Binary data
  column file_data : Bytes?
  
  # Enums (stored as strings or integers)
  column status : String  # For enum handling
end
```

### Exact Decimals and Money

`Grant::Decimal128` is an exact decimal of up to 38 digits, and
`Grant::Money` is a `Grant::Decimal128` amount in one ISO 4217
`Grant::Currency`. Both come from Mica (vendored under `Grant::Mica`), need no
C library and no `big`, and are always available: an app that uses them links
no GMP.

```crystal
class Invoice < Grant::Base
  connection pg
  table invoices

  column id : Int64, primary: true
  column subtotal : Grant::Decimal128, precision: 12, scale: 2
  column tax_rate : Grant::Decimal128?                      # precision 18, scale 4
  column total : Grant::Money, precision: 14, scale: 2      # + total_currency VARCHAR(3)
  column shipping : Grant::Money?, scale: 2, currency: "USD" # currency fixed, no companion column
end

invoice = Invoice.new(subtotal: "19.99", total: Grant::Money.new("21.59", "USD"))
invoice.save!
Invoice.where(subtotal: Grant::Decimal128.parse("19.99")).count # exact equality
Invoice.sum(:subtotal)                                          # => Grant::Decimal128 at scale 2
```

`precision:` is 1 to 38 and `scale:` 0 to the precision (defaults 18 and 4);
anything else stops the build with a message naming the column.

**Storage.** Each database keeps every digit:

| Database   | Column type                | Stored value                              |
|------------|----------------------------|-------------------------------------------|
| PostgreSQL | `NUMERIC(p, s)`            | the decimal                               |
| MySQL      | `DECIMAL(p, s)`            | the decimal                               |
| SQLite     | `INTEGER` when p <= 18     | the coefficient at scale s (12.30 at scale 2 is 1230) |
| SQLite     | `TEXT` when 19 <= p <= 38  | the plain decimal at scale s (`"12.30"`)  |

SQLite's own NUMERIC type converts a value to a 64-bit float or integer and
keeps only about 15 significant digits, so Grant uses neither. Both SQLite
forms are written by Grant's C-library driver and by Grant's own SQLite engine
alike. The migration DSL builds the same types: `t.decimal128 :subtotal,
precision: 12, scale: 2` and `t.money_amount :total, precision: 14, scale: 2`
(add `fixed_currency: true` for a column with `currency:`). `t.money` remains
PostgreSQL's native `money` type.

**Reading.** A value read back is at the column scale: `12.0` stored in a
scale-2 column reads `12.00`, and `12.30` reads `12.30`. Comparison and
hashing are by value (`12.30 == 12.3`), so dirty tracking sees no change when
the same amount is assigned at another scale.

**Values past the scale are an error, never rounded.** Assigning a value with
more fractional digits than the column scale (`1.005` to a scale-2 column), or
more digits than the precision allows, raises `Grant::DecimalColumnError` (an
`ArgumentError`) at the assignment, and the attribute keeps its old value.
Round explicitly first (`value.round(2, :ties_even)`). Mass assignment
(`new`, `set_attributes`, `update`) reports the same error as a conversion
error on the attribute, so `save` returns false with the message in `errors`,
as for any value Grant cannot convert. A trailing zero past the scale is not
lost information: `1.500` is stored as `1.50`.

**Mass assignment from params.** A String parses: `"19.99"` for a
`Grant::Decimal128` column; `"19.99 USD"` for a `Grant::Money` column, or a
bare `"19.99"` in the fixed `currency:` (or in the record's current
`<name>_currency`).

**Money.** The amount is stored like a `Grant::Decimal128` column and the
currency code in the companion column `<name>_currency`, which assigning the
Money column sets; `currency: "USD"` fixes the currency instead, and assigning
Money in another currency to that column raises `Grant::DecimalColumnError`.
A Money column read in a query that does not select its companion column is
nil.

**Queries.** `where(subtotal: value)`, `where(subtotal: [a, b])`, `find_by`,
`where(:subtotal, :gt, value)` and the `where.gt`/`lt`/`gteq`/`lteq` chain
bind the column's stored form, so they compare exactly on every database
(on SQLite an `INTEGER` column compares coefficients). Raw SQL fragments
(`where("subtotal > ?", value)`) bind a `Grant::Decimal128` as its plain text,
which PostgreSQL and MySQL compare exactly; on SQLite compare against the
stored form yourself (`Invoice.coerce_exact_decimal_value("subtotal", value)`).

**Sums.** `sum(:subtotal)` (and `sum(:subtotal, as: Grant::Decimal128)`) is an
exact `Grant::Decimal128` at the column scale. PostgreSQL and MySQL sum
NUMERIC/DECIMAL exactly. On SQLite an `INTEGER` column sums coefficients
exactly (a total past Int64 is a database error, never a rounded result); a
`TEXT` column (precision 19 to 38) would sum as a float there, so Grant reads
its values and adds them as `Grant::Decimal128`, raising
`Grant::Mica::Decimal128::OverflowError` past 38 digits; a grouped sum of such
a column on SQLite raises `ArgumentError`. A Money column sums its amounts;
filter by currency first.

## Primary Keys

### Standard Primary Key

```crystal
class User < Grant::Base
  connection pg
  
  # Auto-incrementing integer (default)
  column id : Int64, primary: true
end
```

### Custom Primary Key

```crystal
class Product < Grant::Base
  connection pg
  
  # Custom name and type
  column sku : String, primary: true, auto: false
  column name : String
end
```

### UUID Primary Key

```crystal
class Document < Grant::Base
  connection pg
  
  # Auto-generated UUID
  column id : UUID, primary: true
  column title : String
end

doc = Document.new(title: "Report")
doc.id # => nil
doc.save
doc.id # => "550e8400-e29b-41d4-a716-446655440000"
```

### Composite Primary Keys

```crystal
class OrderItem < Grant::Base
  connection pg
  table order_items
  
  # Composite primary key support
  column order_id : Int64, primary: true
  column product_id : Int64, primary: true
  column quantity : Int32
  
  # Define composite key
  composite_primary_key [:order_id, :product_id]
end
```

### Natural Keys

```crystal
class Country < Grant::Base
  connection pg
  
  # Natural key (not auto-generated)
  column iso_code : String, primary: true, auto: false
  column name : String
end

country = Country.new(iso_code: "US", name: "United States")
country.save
```

## Default Values

### Static Defaults

```crystal
class Article < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column title : String
  column status : String = "draft"
  column views : Int32 = 0
  column featured : Bool = false
  column tags : Array(String) = [] of String
end
```

### Dynamic Defaults via Callbacks

```crystal
class Token < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column value : String?
  column expires_at : Time?
  
  before_create :set_defaults
  
  private def set_defaults
    self.value ||= Random::Secure.hex(32)
    self.expires_at ||= 24.hours.from_now
  end
end
```

## Timestamps

### Automatic Timestamps

```crystal
class Post < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column title : String
  
  timestamps  # Adds created_at and updated_at
end
```

### Manual Timestamp Control

```crystal
class CustomModel < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  
  # Define explicitly
  column created_at : Time?
  column updated_at : Time?
  column deleted_at : Time?  # For soft deletes
  
  # Custom names
  column inserted_at : Time?
  column modified_at : Time?
end
```

## Multiple Database Connections

### Registering Connections

```crystal
# config/database.cr
Grant::Connections << Grant::Adapter::Pg.new(
  name: "primary",
  url: ENV["PRIMARY_DATABASE_URL"]
)

Grant::Connections << Grant::Adapter::Mysql.new(
  name: "legacy",
  url: ENV["LEGACY_DATABASE_URL"]
)

Grant::Connections << Grant::Adapter::Sqlite.new(
  name: "cache",
  url: "sqlite3://./cache.db"
)
```

### Using Different Connections

```crystal
# Modern PostgreSQL database
class User < Grant::Base
  connection primary
  table users
  
  column id : Int64, primary: true
  column email : String
  timestamps
end

# Legacy MySQL database
class LegacyCustomer < Grant::Base
  connection legacy
  table customers
  
  column customer_id : Int32, primary: true
  column customer_email : String
end

# SQLite cache database
class CacheEntry < Grant::Base
  connection cache
  table cache_entries
  
  column key : String, primary: true, auto: false
  column value : String
  column expires_at : Time
end
```

## Type Converters

### Built-in Converters

```crystal
# Enum converter
enum Status
  Active
  Inactive
  Pending
end

class Account < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column status : Status, converter: Grant::Converters::Enum(Status, String)
end

# JSON converter
class Settings
  include JSON::Serializable
  
  property theme : String = "light"
  property notifications : Bool = true
end

class User < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column preferences : Settings, converter: Grant::Converters::Json(Settings, String)
end

# PostgreSQL Numeric converter
class Transaction < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column amount : Float64, converter: Grant::Converters::PgNumeric
end
```

### Custom Converters

```crystal
# Create a custom converter
module Grant::Converters
  class EncryptedString < Grant::Converters::Base(String, String)
    def self.from_db(value : String) : String
      # Decrypt value from database
      decrypt(value)
    end
    
    def self.to_db(value : String) : String
      # Encrypt value for database
      encrypt(value)
    end
    
    private def self.encrypt(value)
      # Encryption logic
      Base64.encode(value)  # Simplified example
    end
    
    private def self.decrypt(value)
      # Decryption logic
      Base64.decode_string(value)  # Simplified example
    end
  end
end

class SecureModel < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column secret : String, converter: Grant::Converters::EncryptedString
end
```

## Annotations

### JSON/YAML Serialization

```crystal
class ApiModel < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  
  @[JSON::Field(key: "user_name")]
  @[YAML::Field(key: "user_name")]
  column name : String
  
  @[JSON::Field(ignore: true)]
  column internal_notes : String?
  
  @[JSON::Field(emit_null: false)]
  column optional_field : String?
end

model = ApiModel.find(1)
model.to_json  # name serialized as "user_name", internal_notes excluded
```

### Custom Annotations

```crystal
annotation MyAnnotation
end

class CustomModel < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  
  @[MyAnnotation(important: true)]
  column critical_field : String
end
```

## Serialization

### JSON Serialization

```crystal
class User < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column name : String
  column email : String
  
  # Grant includes JSON::Serializable by default
end

# Serialize to JSON
user = User.find(1)
json = user.to_json
# => {"id":1,"name":"John","email":"john@example.com"}

# Deserialize from JSON
user = User.from_json(json)
```

### YAML Serialization

```crystal
# Serialize to YAML
user = User.find(1)
yaml = user.to_yaml
# => "---\nid: 1\nname: John\nemail: john@example.com\n"

# Deserialize from YAML
user = User.from_yaml(yaml)
```

### Custom Serialization

```crystal
class User < Grant::Base
  connection pg
  
  column id : Int64, primary: true
  column first_name : String
  column last_name : String
  column email : String
  column password_hash : String
  
  # Custom JSON representation
  def to_public_json
    {
      id: id,
      name: "#{first_name} #{last_name}",
      email: email
      # password_hash excluded
    }.to_json
  end
end
```

## Documentation

### Generating Docs

```bash
# Include Grant methods in documentation
crystal docs -D grant_docs
```

### Documenting Columns

```crystal
class Product < Grant::Base
  connection pg
  
  # Unique product identifier
  column id : Int64, primary: true
  
  # Product SKU for inventory tracking
  column sku : String
  
  # Current price in cents to avoid floating point issues
  column price_cents : Int32
  
  # Whether the product is available for purchase
  column available : Bool = true
  
  # Number of items in stock
  # Returns nil if inventory is not tracked
  column stock_quantity : Int32?
end
```

## Database-Specific Features

### PostgreSQL

```crystal
class PgModel < Grant::Base
  connection pg
  
  # Arrays
  column tags : Array(String)
  column scores : Array(Int32)
  
  # JSONB
  column metadata : JSON::Any
  
  # UUID with extension
  column id : UUID, primary: true
  
  # Full-text search
  scope search, ->(query : String) {
    where("to_tsvector('english', content) @@ plainto_tsquery('english', ?)", [query])
  }
end
```

### MySQL

```crystal
class MysqlModel < Grant::Base
  connection mysql
  
  # JSON column (MySQL 5.7+)
  column settings : JSON::Any
  
  # ENUM (stored as string)
  column status : String  # ENUM('active', 'inactive', 'pending')
  
  # Full-text search
  scope search, ->(query : String) {
    where("MATCH(title, content) AGAINST(? IN NATURAL LANGUAGE MODE)", [query])
  }
end
```

### SQLite

```crystal
class SqliteModel < Grant::Base
  connection sqlite
  
  # JSON stored as TEXT
  column data : JSON::Any
  
  # Boolean stored as INTEGER (0/1)
  column active : Bool
  
  # Limited type support - be aware of conversions
  column amount : Float64  # Stored as REAL
end
```

## Best Practices

### 1. Choose Appropriate Types
```crystal
# Good: Use specific types
column price : Grant::Decimal128, precision: 12, scale: 2 # Exact money amounts
column email : String            # Validated elsewhere
column published : Bool          # Clear boolean

# Avoid: Ambiguous types
column price : Float64           # Floating point money issues
column status : String          # Consider enum
column data : String            # Consider JSON::Any
```

### 2. Use Nullability Appropriately
```crystal
# Required fields (not nilable)
column email : String
column name : String

# Optional fields (nilable)
column bio : String?
column deleted_at : Time?
```

### 3. Set Sensible Defaults
```crystal
column status : String = "pending"
column retry_count : Int32 = 0
column active : Bool = true
column tags : Array(String) = [] of String
```

### 4. Document Complex Columns
```crystal
# Stores the user's preference as a bitmask
# Bit 0: Email notifications
# Bit 1: SMS notifications  
# Bit 2: Push notifications
column notification_preferences : Int32 = 0
```

## Migration Considerations

When defining models, consider the corresponding migration:

```crystal
# Model definition
class User < Grant::Base
  connection pg
  column id : Int64, primary: true
  column email : String
  column active : Bool = true
  timestamps
end

# Corresponding migration
create_table :users do |t|
  t.bigint :id, primary: true
  t.string :email, null: false
  t.boolean :active, default: true
  t.timestamps
  
  t.index :email, unique: true
end
```

## Next Steps

- [CRUD Operations](crud-operations.md)
- [Querying and Scopes](querying-and-scopes.md)
- [Validations](validations.md)
- [Relationships](relationships.md)
- [Callbacks and Lifecycle](callbacks-lifecycle.md)