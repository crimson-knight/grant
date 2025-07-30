# Granite ORM - Current Features Documentation

This document provides a comprehensive overview of all current features and methods available in Granite ORM as of the current codebase review.

## Table of Contents
1. [Core Components](#core-components)
2. [Model Definition](#model-definition)
3. [Database Connections](#database-connections)
4. [Column Types and Definitions](#column-types-and-definitions)
5. [Query Interface](#query-interface)
6. [Associations/Relationships](#associationsrelationships)
7. [Validations](#validations)
8. [Callbacks](#callbacks)
9. [Transactions](#transactions)
10. [Migrations](#migrations)
11. [Additional Features](#additional-features)

## Core Components

### Base Class
- `Granite::Base` - Abstract base class for all models
- Includes modules: Associations, Callbacks, Columns, Tables, Transactions, Validators, ValidationHelpers, Migrator, Select, Querying, ConnectionManagement

### Supported Adapters
- MySQL (`Granite::Adapter::Mysql`)
- PostgreSQL (`Granite::Adapter::Pg`)
- SQLite (`Granite::Adapter::Sqlite`)

## Model Definition

### Basic Model Structure
```crystal
class Post < Granite::Base
  connection mysql
  table posts
  
  column id : Int64, primary: true
  column title : String
  column body : String?
  timestamps
end
```

### Key Features
- `connection` - Specifies which database connection to use
- `table` - Sets custom table name (defaults to pluralized class name)
- `column` - Defines a database column
- `timestamps` - Adds created_at and updated_at columns

## Database Connections

### Multiple Connections Support
```crystal
Granite::Connections << Granite::Adapter::Mysql.new(name: "mysql", url: "DATABASE_URL")
Granite::Connections << Granite::Adapter::Pg.new(name: "pg", url: "POSTGRES_URL")
```

### Connection Switching
- Automatic reader/writer connection support
- Methods: `switch_to_writer_adapter`, `switch_to_reader_adapter`

## Column Types and Definitions

### Supported Column Types
- Basic types: `String`, `Int32`, `Int64`, `Float32`, `Float64`, `Bool`, `Time`, `UUID`
- Nilable types: `String?`, `Int64?`, etc.
- Array types: `Array(String)`, `Array(Int32)`, `Array(Int64)`, `Array(Float32)`, `Array(Float64)`, `Array(Bool)`, `Array(UUID)`
- Bytes/Blob: `Bytes`

### Column Options
- `primary: true` - Marks column as primary key
- `auto: true/false` - Auto-increment (default true for primary keys)
- `column_type: "VARCHAR(100)"` - Custom database column type
- `converter: ConverterClass` - Custom type converter

### Special Column Types

#### Primary Keys
- Default: `id : Int64` with auto-increment
- Custom: Can use `Int32`, `UUID`, or natural keys with `auto: false`

#### UUID Primary Keys
```crystal
column id : UUID, primary: true
```

#### Timestamps
```crystal
timestamps # Adds created_at and updated_at
```

### Converters
- `Granite::Converters::Enum(EnumType, DBType)` - Enum converter
- `Granite::Converters::Json(ObjectType, DBType)` - JSON converter
- `Granite::Converters::PgNumeric` - PostgreSQL numeric to Float64

## Query Interface

### Basic Queries
- `Model.all` - Returns all records
- `Model.first` - Returns first record
- `Model.find(id)` - Find by primary key
- `Model.find!(id)` - Find by primary key, raises if not found
- `Model.find_by(**attributes)` - Find by attributes
- `Model.find_by!(**attributes)` - Find by attributes, raises if not found
- `Model.exists?(id)` - Check if record exists
- `Model.count` - Count all records

### Query Builder Methods
- `where(field: value)` - Add WHERE clause
- `where(field, :operator, value)` - WHERE with operators
- `where("SQL", params)` - Raw SQL WHERE
- `and(conditions)` - Add AND condition
- `or(conditions)` - Add OR condition
- `order(field)` - Order by field
- `order(field: :desc)` - Order with direction
- `group_by(field)` - Group by field
- `limit(n)` - Limit results
- `offset(n)` - Offset results

### Supported WHERE Operators
- `:eq` - Equal (default)
- `:neq` - Not equal
- `:gt` - Greater than
- `:lt` - Less than
- `:gteq` - Greater than or equal
- `:lteq` - Less than or equal
- `:nlt` - Not less than
- `:ngt` - Not greater than
- `:ltgt` - Less than or greater than
- `:in` - In array
- `:nin` - Not in array
- `:like` - SQL LIKE
- `:nlike` - SQL NOT LIKE

### Advanced Queries
- `Model.raw_all(sql, params)` - Execute raw SQL
- `Model.exec(sql)` - Execute arbitrary SQL
- `Model.query(sql, params)` - Execute query with block
- `Model.scalar(sql)` - Execute scalar query

### Batch Processing
- `find_each(batch_size: 100)` - Process records in batches
- `find_in_batches(batch_size: 100)` - Get batches of records

### Custom SELECT
```crystal
select_statement <<-SQL
  SELECT custom_fields FROM table
SQL
```

## Associations/Relationships

### belongs_to
```crystal
belongs_to :user
belongs_to :user, foreign_key: custom_id : Int64
belongs_to :user, primary_key: :uuid
```

### has_one
```crystal
has_one :profile
has_one :profile, foreign_key: :custom_id
```

### has_many
```crystal
has_many :posts
has_many :posts, class_name: Post
has_many :posts, foreign_key: :author_id
```

### has_many through
```crystal
has_many :participants
has_many :rooms, through: :participants
```

### Association Methods
- `model.association` - Get associated record(s)
- `model.association=` - Set associated record
- `model.association!` - Get associated record, raises if not found

## Validations

### Built-in Validators
- Custom validation blocks
- Validation with custom messages

### Validation Methods
```crystal
validate :field, "error message" do |model|
  # validation logic returning boolean
end

validate "error message" do |model|
  # validation logic for :base field
end
```

### Validation Helpers
- `validates_presence_of` - Via ValidationHelpers::Nil
- `validates_uniqueness_of` - Via ValidationHelpers::Uniqueness
- `validates_length_of` - Via ValidationHelpers::Length
- `validates_inclusion_of` - Via ValidationHelpers::Choice
- `validates_exclusion_of` - Via ValidationHelpers::Exclusion
- Custom validators via ValidationHelpers modules

### Validation API
- `valid?` - Run validations and return boolean
- `errors` - Array of validation errors

## Callbacks

### Available Callbacks
- `before_save`
- `after_save`
- `before_create`
- `after_create`
- `before_update`
- `after_update`
- `before_destroy`
- `after_destroy`

### Callback Definition
```crystal
before_save :method_name
after_create { puts "Created!" }
```

### Callback Control
- `abort!` - Abort callback chain and operation

## Transactions

### CRUD Operations
- `create(**attributes)` - Create new record
- `create!(**attributes)` - Create, raises on failure
- `save` - Save record
- `save!` - Save, raises on failure
- `save(validate: false)` - Skip validations
- `save(skip_timestamps: true)` - Skip timestamp updates
- `update(**attributes)` - Update attributes and save
- `update!(**attributes)` - Update, raises on failure
- `destroy` - Delete record
- `destroy!` - Delete, raises on failure

### Bulk Operations
- `Model.import(array)` - Bulk insert records
- `Model.import(array, batch_size: 1000)` - Bulk insert with batch size
- `Model.import(array, update_on_duplicate: true, columns: ["field"])` - Upsert
- `Model.import(array, ignore_on_duplicate: true)` - Insert ignore

### Additional Methods
- `Model.clear` - Delete all records
- `touch` - Update updated_at timestamp
- `touch(:field)` - Update specific timestamp field

### Database Transaction Support
Via Crystal's DB module transaction support

## Migrations

### Migrator API
```crystal
Model.migrator.create
Model.migrator.drop
Model.migrator.drop_and_create
Model.migrator(table_options: "ENGINE=InnoDB").create
```

### Generated SQL
- Automatic schema generation based on model columns
- Support for different column types per adapter
- Primary key handling
- NOT NULL constraints
- Custom table options

## Additional Features

### Serialization
- JSON serialization via `JSON::Serializable`
- YAML serialization via `YAML::Serializable`
- `to_json` / `from_json`
- `to_yaml` / `from_yaml`
- `to_h` - Convert to hash

### Model State
- `new_record?` - Check if record is unsaved
- `persisted?` - Check if record is saved
- `destroyed?` - Check if record was destroyed
- `reload` - Reload from database (test mode only)

### Attribute Access
- `read_attribute(name)` - Read attribute value
- `set_attributes(hash)` - Mass assignment
- `primary_key_value` - Get primary key value

### Type System
- `Granite::Columns::Type` - Union type for all column types
- `Granite::Type` - Type conversion utilities
- Strong typing with compile-time checks

### Error Handling
- `Granite::Error` - Base error class
- `Granite::ConversionError` - Type conversion errors
- `Granite::RecordNotSaved` - Save failures
- `Granite::RecordNotDestroyed` - Destroy failures
- `Granite::RecordInvalid` - Validation failures
- `Granite::Querying::NotFound` - Record not found

### Integrators
- `find_or_create_by(**attributes)` - Find or create record
- `find_or_initialize_by(**attributes)` - Find or initialize record

### Collections
- `Granite::Collection` - Lazy-loaded collection wrapper
- `Granite::AssociationCollection` - Association collection handling

### Query Executors
- List executor for collections
- Value executor for single values
- Multi-value executor for multiple single values

### Adapter Features
- Connection pooling via crystal-db
- Prepared statements
- Query logging
- Multiple connection support
- Read/write splitting capabilities

### Settings
- `Granite.settings.default_timezone` - Default timezone for timestamps

### Annotations Support
- `@[JSON::Field]` annotations on columns
- `@[YAML::Field]` annotations on columns
- Custom annotations support

This comprehensive list represents the current state of Granite ORM's features. When comparing to ActiveRecord v8, we can identify gaps and plan implementations to achieve feature parity.
## Dirty Tracking API (Phase 1 - COMPLETE)

Grant now includes a comprehensive dirty tracking API that provides full compatibility with Rails ActiveRecord's dirty tracking functionality.

### Core Dirty Tracking Methods

#### Instance Methods
- `changed?` - Returns true if any attributes have been changed
- `changes` - Returns hash of changed attributes with {original, new} values
- `changed_attributes` - Returns array of changed attribute names
- `previous_changes` - Returns changes from last save
- `saved_changes` - Alias for previous_changes (Rails compatibility)
- `attribute_changed?(name)` - Check if specific attribute changed
- `attribute_was(name)` - Get original value of attribute
- `saved_change_to_attribute?(name)` - Check if attribute changed in last save
- `attribute_before_last_save(name)` - Get value before last save
- `restore_attributes(attrs = nil)` - Restore changed attributes to original values

### Per-Attribute Methods

For each column, the following methods are automatically generated:

```crystal
class User < Granite::Base
  column name : String
  column email : String
end

user = User.find\!(1)
user.name = "New Name"

# Generated methods:
user.name_changed?           # => true
user.name_was               # => "Original Name"
user.name_change            # => {"Original Name", "New Name"}
user.name_before_last_save  # => "Original Name" (after save)
```

### Usage Examples

#### Basic Change Tracking
```crystal
user = User.find\!(1)
user.changed? # => false

user.name = "Jane"
user.email = "jane@example.com"

user.changed? # => true
user.changed_attributes # => ["name", "email"]
user.changes # => {"name" => {"John", "Jane"}, "email" => {"john@example.com", "jane@example.com"}}
```

#### Working with Saves
```crystal
user.name = "Jane"
user.save

user.changed? # => false (cleared after save)
user.previous_changes # => {"name" => {"John", "Jane"}}
user.saved_change_to_attribute?("name") # => true
```

#### Restoring Changes
```crystal
user.name = "Jane"
user.email = "jane@example.com"

user.restore_attributes(["name"]) # Restore only name
user.name # => "John"
user.email # => "jane@example.com"

user.restore_attributes # Restore all
user.email # => "john@example.com"
```

### Implementation Details

- Dirty tracking is built directly into the column macro
- Compatible with JSON::Serializable and YAML::Serializable
- Works with all column types including enums with converters
- Minimal performance impact with lazy initialization
- Full Rails ActiveRecord API compatibility

For comprehensive documentation, see [docs/dirty_tracking.md](docs/dirty_tracking.md).

## Polymorphic Associations (Phase 2 - COMPLETE)

Grant now supports polymorphic associations, allowing a model to belong to more than one other model type.

### Usage

```crystal
class Comment < Granite::Base
  belongs_to :commentable, polymorphic: true
end

class Post < Granite::Base
  has_many :comments, as: :commentable
end

class Photo < Granite::Base
  has_many :comments, as: :commentable
end
```

This creates:
- `commentable_id` (Int64?) - stores the associated record ID
- `commentable_type` (String?) - stores the associated record class name

For detailed documentation, see [docs/polymorphic_associations.md](docs/polymorphic_associations.md).

## Advanced Association Options (Phase 2 - COMPLETE)

Grant now includes comprehensive association options for fine-grained control:

### Dependent Options
- `dependent: :destroy` - Destroy associated records
- `dependent: :nullify` - Set foreign keys to NULL
- `dependent: :restrict` - Prevent deletion if associations exist

### Other Options
- `optional: true` - Allow nil foreign keys on belongs_to
- `counter_cache: true` - Maintain count on parent model
- `touch: true` - Update parent timestamps on changes
- `autosave: true` - Save associations automatically

### Example
```crystal
class Author < Granite::Base
  has_many :posts, dependent: :destroy, counter_cache: true
end

class Post < Granite::Base
  belongs_to :author, optional: true, touch: true
end
```

For comprehensive documentation, see [docs/advanced_associations.md](docs/advanced_associations.md).