---
name: grant-models-and-columns
description: Defining Grant ORM models with columns, types, primary keys, timestamps, connections, converters, and serialization.
user-invocable: false
---

# Grant Models and Columns

## Model Basics

All Grant models inherit from `Grant::Base` and use macros to define their schema:

```crystal
class User < Grant::Base
  connection pg        # Database connection to use
  table users          # Table name (optional, defaults to pluralized class name)

  column id : Int64, primary: true
  column name : String
  column email : String

  timestamps           # Adds created_at and updated_at as Time?
end
```

### Model Components

- **Inheritance**: All models inherit from `Grant::Base`
- **Connection**: `connection` macro specifies which database adapter to use (maps to a registered connection name)
- **Table**: `table` macro maps to a database table (optional -- inferred from class name if omitted)
- **Columns**: `column` macro defines the schema and data types
- **Behavior**: Validations, callbacks, associations, scopes are added via additional macros

## Column Definition

### Syntax

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
| Default value | Crystal expression after `=` | `column active : Bool = true` |

## Supported Data Types

### Primitive Types

```crystal
class Product < Grant::Base
  connection pg

  # Integer types
  column id : Int64, primary: true      # BIGINT
  column quantity : Int32                # INTEGER
  column position : Int16                # SMALLINT
  column status_code : Int8             # TINYINT

  # Floating point
  column price : Float64                 # DOUBLE PRECISION
  column rating : Float32               # FLOAT

  # String types
  column name : String                   # VARCHAR/TEXT
  column description : String?           # Nullable string

  # Boolean
  column active : Bool = true            # BOOLEAN
  column featured : Bool = false

  # Time/Date
  column published_at : Time?            # TIMESTAMP
  column expires_on : Time?

  timestamps                             # created_at, updated_at as Time?
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
end
```

## Primary Keys

### Standard Auto-Incrementing

```crystal
column id : Int64, primary: true
```

### Custom Name and Type

```crystal
column custom_id : Int32, primary: true
```

### Natural Keys (No Auto-Increment)

```crystal
column iso_code : String, primary: true, auto: false
```

### UUID Primary Key

Automatically generates a secure UUID on save:

```crystal
class Document < Grant::Base
  connection pg
  column id : UUID, primary: true
  column title : String
end

doc = Document.new(title: "Report")
doc.id   # => nil
doc.save
doc.id   # => "550e8400-e29b-41d4-a716-446655440000"
```

### Composite Primary Keys

```crystal
class OrderItem < Grant::Base
  connection pg
  table order_items

  column order_id : Int64, primary: true
  column product_id : Int64, primary: true
  column quantity : Int32

  composite_primary_key [:order_id, :product_id]
end
```

### belongs_to as Primary Key

```crystal
class ChatSettings < Grant::Base
  connection mysql
  belongs_to chat : Chat, primary: true
end
```

## Default Values

### Static Defaults

```crystal
column status : String = "draft"
column views : Int32 = 0
column featured : Bool = false
column tags : Array(String) = [] of String
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

The `timestamps` macro adds `created_at : Time?` and `updated_at : Time?`:

```crystal
class Bar < Grant::Base
  connection mysql
  column id : Int64, primary: true
  timestamps
end
```

This is equivalent to explicitly defining:

```crystal
column created_at : Time?
column updated_at : Time?
```

## Multiple Database Connections

### Registering Connections

```crystal
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
class User < Grant::Base
  connection primary
  # ...
end

class LegacyCustomer < Grant::Base
  connection legacy
  table customers
  # ...
end
```

## Type Converters

Grant supports custom types via converters that transform values to/from database-compatible formats.

### Built-in Converters

- `Grant::Converters::Enum(E, T)` -- Converts Crystal enum `E` to/from database type `T` (Number, String, or Bytes)
- `Grant::Converters::Json(M, T)` -- Converts object `M` (must implement `#to_json`/`.from_json`) to/from `T` (String, JSON::Any, or Bytes)
- `Grant::Converters::PgNumeric` -- Converts `PG::Numeric` to `Float64`

```crystal
enum OrderStatus
  Active
  Expired
  Completed
end

class Order < Grant::Base
  connection mysql
  column id : Int64, primary: true
  column status : OrderStatus, converter: Grant::Converters::Enum(OrderStatus, String)
end
```

```crystal
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
```

### Custom Converters

```crystal
module Grant::Converters
  class EncryptedString < Grant::Converters::Base(String, String)
    def self.from_db(value : String) : String
      Base64.decode_string(value)
    end

    def self.to_db(value : String) : String
      Base64.encode(value)
    end
  end
end
```

## Annotations and Serialization

Grant includes `JSON::Serializable` and `YAML::Serializable` by default:

```crystal
class ApiModel < Grant::Base
  connection pg
  column id : Int64, primary: true

  @[JSON::Field(key: "user_name")]
  column name : String

  @[JSON::Field(ignore: true)]
  column internal_notes : String?
end

model = ApiModel.find(1)
model.to_json   # name serialized as "user_name", internal_notes excluded
```

## Database-Specific Features

### PostgreSQL
- Arrays (`Array(String)`, `Array(Int32)`), JSONB, UUID, full-text search scopes

### MySQL
- JSON (5.7+), ENUM stored as String, FULLTEXT search

### SQLite
- JSON stored as TEXT, Boolean stored as INTEGER (0/1), limited type support

## Documentation Generation

By default, `crystal docs` does not include Grant methods. Use the flag:

```bash
crystal docs -D grant_docs
```
