# Grant ORM - Current Features Documentation

This document provides a comprehensive overview of all current features and methods available in Grant ORM as of the current codebase review.

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
- `Grant::Base` - Abstract base class for all models
- Includes modules: Associations, Callbacks, Columns, Tables, Transactions, Validators, ValidationHelpers, Migrator, Select, Querying, ConnectionManagement

### Supported Adapters
- MySQL (`Grant::Adapter::Mysql`)
- PostgreSQL (`Grant::Adapter::Pg`)
- SQLite (`Grant::Adapter::Sqlite`)

## Model Definition

### Basic Model Structure
```crystal
class Post < Grant::Base
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
Grant::Connections << Grant::Adapter::Mysql.new(name: "mysql", url: "DATABASE_URL")
Grant::Connections << Grant::Adapter::Pg.new(name: "pg", url: "POSTGRES_URL")
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
- `Grant::Converters::Enum(EnumType, DBType)` - Enum converter
- `Grant::Converters::Json(ObjectType, DBType)` - JSON converter
- `Grant::Converters::PgNumeric` - PostgreSQL numeric to Float64

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
- `Grant::Columns::Type` - Union type for all column types
- `Grant::Type` - Type conversion utilities
- Strong typing with compile-time checks

### Error Handling
- `Grant::Error` - Base error class
- `Grant::ConversionError` - Type conversion errors
- `Grant::RecordNotSaved` - Save failures
- `Grant::RecordNotDestroyed` - Destroy failures
- `Grant::RecordInvalid` - Validation failures
- `Grant::Querying::NotFound` - Record not found

### Integrators
- `find_or_create_by(**attributes)` - Find or create record
- `find_or_initialize_by(**attributes)` - Find or initialize record

### Collections
- `Grant::Collection` - Lazy-loaded collection wrapper
- `Grant::AssociationCollection` - Association collection handling

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
- `Grant.settings.default_timezone` - Default timezone for timestamps

### Annotations Support
- `@[JSON::Field]` annotations on columns
- `@[YAML::Field]` annotations on columns
- Custom annotations support

This comprehensive list represents the current state of Grant ORM's features. When comparing to ActiveRecord v8, we can identify gaps and plan implementations to achieve feature parity.
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
class User < Grant::Base
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
class Comment < Grant::Base
  belongs_to :commentable, polymorphic: true
end

class Post < Grant::Base
  has_many :comments, as: :commentable
end

class Photo < Grant::Base
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
class Author < Grant::Base
  has_many :posts, dependent: :destroy, counter_cache: true
end

class Post < Grant::Base
  belongs_to :author, optional: true, touch: true
end
```

For comprehensive documentation, see [docs/advanced_associations.md](docs/advanced_associations.md).

## Enum Attributes (Phase 3 - COMPLETE)

Grant now provides Rails-style enum attributes with full helper method support.

### Usage

```crystal
class Article < Grant::Base
  enum Status
    Draft
    Published
    Archived
  end
  
  enum_attribute status : Status = :draft
  
  # Multiple enums at once
  enum_attributes(
    category : Category = :general,
    visibility : Visibility = :public
  )
end
```

### Generated Methods

For each enum attribute, the following methods are automatically generated:

```crystal
article = Article.new

# Predicate methods
article.draft?      # => true
article.published?  # => false

# Bang methods to set values
article.published!  # Sets status to published
article.draft!      # Sets status to draft

# Class methods
Article.statuses         # => [:draft, :published, :archived]
Article.status_mapping   # => {draft: 0, published: 1, archived: 2}

# Scopes
Article.draft.count     # Count draft articles
Article.published       # Get published articles
Article.not_archived    # Get non-archived articles
```

### Features
- Automatic converter integration
- Default value support
- String and integer storage
- Query scope generation
- Full Rails API compatibility

For comprehensive documentation, see [docs/enum_attributes.md](docs/enum_attributes.md).

## Built-in Validators (Phase 3 - COMPLETE)

Grant now includes a comprehensive set of Rails-compatible validators with conditional support.

### Available Validators

#### Numericality
```crystal
validates_numericality_of :price, greater_than: 0
validates_numericality_of :age, in: 18..65
validates_numericality_of :quantity, only_integer: true
```

#### Format
```crystal
validates_format_of :phone, with: /\A\d{3}-\d{3}-\d{4}\z/
validates_format_of :username, without: /\A(admin|root)\z/
```

#### Length
```crystal
validates_length_of :username, in: 3..20
validates_length_of :bio, maximum: 500
validates_length_of :code, is: 4
```

#### Email and URL
```crystal
validates_email :email
validates_url :website
```

#### Confirmation
```crystal
validates_confirmation_of :password
validates_confirmation_of :email
```

#### Acceptance
```crystal
validates_acceptance_of :terms_of_service
validates_acceptance_of :privacy_policy, accept: ["yes", "accepted"]
```

#### Inclusion/Exclusion
```crystal
validates_inclusion_of :plan, in: ["free", "basic", "premium"]
validates_exclusion_of :username, in: RESERVED_NAMES
```

#### Associated Records
```crystal
validates_associated :line_items
validates_associated :address
```

### Conditional Validation

All validators support `:if` and `:unless` options:

```crystal
validates_numericality_of :total, greater_than: 0, if: :completed?
validates_length_of :bio, minimum: 100, unless: :draft?
```

### Features
- Rails-compatible API
- Custom error messages
- Allow nil/blank options
- Conditional validation
- Type-safe implementation

For comprehensive documentation, see [docs/built_in_validators.md](docs/built_in_validators.md).

## Attribute API (Phase 3 - COMPLETE)

Grant now provides a flexible Attribute API for defining custom attributes with virtual fields, defaults, and custom types.

### Features

#### Virtual Attributes
```crystal
class Product < Grant::Base
  # Virtual attribute not stored in database
  attribute price_in_cents : Int32, virtual: true
  
  def price : Float64?
    price_in_cents.try { |cents| cents / 100.0 }
  end
end
```

#### Default Values
```crystal
class Article < Grant::Base
  # Static default
  attribute status : String?, default: "draft"
  
  # Dynamic default with proc
  attribute code : String?, default: ->(article : Grant::Base) { 
    "ART-#{article.as(Article).id || "NEW"}" 
  }
end
```

#### Custom Types with Converters
```crystal
class Product < Grant::Base
  attribute metadata : ProductMetadata?, 
    converter: ProductMetadataConverter,
    column_type: "TEXT"
end
```

### Features
- Virtual attributes for computed values
- Static and dynamic default values
- Full dirty tracking integration
- Custom type support via converters
- Attribute introspection methods

For comprehensive documentation, see [docs/attribute_api.md](docs/attribute_api.md).

## Phase 4 - Convenience Methods (In Progress)

### Query Methods
- **pluck** - Extract one or more column values without instantiating models
  ```crystal
  User.where(active: true).pluck(:id, :name)
  # => [[1, "John"], [2, "Jane"]]
  ```

- **pick** - Get values from first record
  ```crystal
  User.pick(:id, :name)
  # => [1, "John"]
  ```

- **annotate** - Add SQL comments for debugging
  ```crystal
  User.where(active: true).annotate("Dashboard query").select
  ```

### Batch Processing
- **in_batches** - Process records in configurable batches
  ```crystal
  User.in_batches(of: 100) do |batch|
    batch.each { |user| user.update(processed: true) }
  end
  ```

### Bulk Operations
- **insert_all** - Bulk insert with options
  ```crystal
  User.insert_all([
    {name: "John", email: "john@example.com"},
    {name: "Jane", email: "jane@example.com"}
  ])
  ```

- **upsert_all** - Insert or update on conflict
  ```crystal
  User.upsert_all(
    [{name: "John", email: "john@example.com", age: 26}],
    unique_by: [:email],
    update_only: [:age]
  )
  ```

### Implementation Status
- ✅ Basic implementation complete
- ✅ Range query handling fixed (supports inclusive ranges with :gteq/:lteq operators)
- ✅ Bulk operation parameter passing fixed
- ✅ in_batches with start/finish constraints working correctly
- ⚠️ SQLite-specific upsert behavior differs from PostgreSQL/MySQL
- ⚠️ Some test isolation issues may occur

### Known Issues Resolved
1. **Range Query Support** - Fixed operator mapping for ranges (30..40 now correctly translates to >= and <= queries)
2. **Parameter Passing** - Fixed issue where query parameters weren't being passed to executors by caching assembler instances
3. **Bulk Operations** - Fixed NULL constraint errors by ensuring proper parameter collection
4. **in_batches** - Fixed batch iteration logic to properly handle all records

### Technical Notes
- Query builder now properly uses `:gteq` and `:lteq` operators for range queries
- Assembler instances are cached per query to preserve parameters
- Bulk operations (insert_all/upsert_all) properly collect and pass parameters
- SQLite requires unique indexes for ON CONFLICT clauses in upsert operations