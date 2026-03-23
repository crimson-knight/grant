---
name: grant-generate-model
description: Generate a new Grant ORM model file with proper structure, column definitions, validations, associations, and callbacks.
allowed-tools: Bash, Read, Write, Glob
user-invocable: true
argument-hint: <ModelName> [column:type ...] [--with-validations] [--with-associations]
---

# Generate Grant Model

This skill generates a new Grant ORM model file with proper structure, following the conventions established in the project.

## Procedure

### Step 1: Parse the Request

Extract from the user's request:
- **Model name** (e.g., `Product`, `UserProfile`)
- **Columns** with types (e.g., `name:String`, `price:Float64`, `active:Bool`)
- **Options**: `--with-validations`, `--with-associations`, or specific association/validation requests

### Step 2: Check Existing Models for Conventions

Before generating, scan the project to understand existing conventions:

1. Look in `src/` for existing model files to determine:
   - Which connection name is used (e.g., `pg`, `sqlite`, `mysql`)
   - Whether the project uses `timestamps` consistently
   - Naming conventions for files and classes
   - Common validation patterns
   - Common association patterns

2. Check `spec/` for test file conventions.

### Step 3: Generate the Model File

Create the model file at `src/models/<model_name_snake_case>.cr` (or the location matching existing models).

#### Basic Model Template

```crystal
class ModelName < Grant::Base
  connection <connection_name>
  table <table_name_pluralized>

  column id : Int64, primary: true
  # ... user-specified columns ...

  timestamps
end
```

#### With Validations

Add appropriate validators based on column types:
- `String` columns: `validate_not_blank` for required fields
- `String` email fields: `validates_email`
- Numeric columns: `validates_numericality_of` with appropriate constraints
- Unique fields: `validate_uniqueness`

#### With Associations

Add association macros based on the user's request:
- `belongs_to` with foreign key columns
- `has_many` with appropriate class names
- `has_one` for single-record associations
- `has_many :through` for many-to-many

### Step 4: Generate Column Type Mapping

Use these Crystal-to-Grant type mappings:

| User Input | Crystal Type | Notes |
|-----------|-------------|-------|
| `string`, `text` | `String` | VARCHAR/TEXT |
| `string?` | `String?` | Nullable |
| `int`, `integer` | `Int32` | INTEGER |
| `bigint`, `int64` | `Int64` | BIGINT |
| `float`, `decimal` | `Float64` | DOUBLE |
| `bool`, `boolean` | `Bool` | BOOLEAN |
| `time`, `datetime` | `Time?` | TIMESTAMP |
| `json` | `JSON::Any?` | JSON/JSONB/TEXT |
| `uuid` | `UUID` | UUID type |
| `bytes`, `binary` | `Bytes?` | BLOB |

### Step 5: Explain the Generated Code

After generating, provide a brief explanation of:
- Each section of the model (connection, table, columns, validations, associations)
- Any conventions that were followed from existing project models
- Suggested next steps (migration, adding specs)

## Examples

### Simple Model

Request: `Product name:String price:Float64 active:Bool`

```crystal
class Product < Grant::Base
  connection sqlite
  table products

  column id : Int64, primary: true
  column name : String
  column price : Float64
  column active : Bool = true

  timestamps
end
```

### Model with Validations

Request: `User email:String username:String age:Int32 --with-validations`

```crystal
class User < Grant::Base
  connection sqlite
  table users

  column id : Int64, primary: true
  column email : String
  column username : String
  column age : Int32

  timestamps

  # Validations
  validate_not_blank :email
  validates_email :email
  validate_uniqueness :email
  validate_not_blank :username
  validates_length_of :username, minimum: 3, maximum: 30
  validate_uniqueness :username
  validates_numericality_of :age, greater_than: 0
end
```

### Model with Associations

Request: `Post title:String content:String published:Bool --with-associations belongs_to:User has_many:Comment`

```crystal
class Post < Grant::Base
  connection sqlite
  table posts

  belongs_to :user
  has_many :comments, dependent: :destroy

  column id : Int64, primary: true
  column title : String
  column content : String
  column published : Bool = false
  column user_id : Int64

  timestamps

  # Validations
  validate_not_blank :title
  validate_not_blank :content

  # Scopes
  scope :published, -> { where(published: true) }
  scope :drafts, -> { where(published: false) }
end
```

### Model with Enum

Request: `Article title:String status:enum(Draft,Published,Archived)`

```crystal
class Article < Grant::Base
  connection sqlite
  table articles

  column id : Int64, primary: true
  column title : String

  timestamps

  enum Status
    Draft
    Published
    Archived
  end

  enum_attribute status : Status = :draft

  # Validations
  validate_not_blank :title

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
end
```

## Important Notes

- Always check the project's existing connection name before generating
- Use `timestamps` unless the user specifically excludes them
- Add `column user_id : Int64` (or appropriate FK column) when adding `belongs_to` associations
- For `has_many :through`, generate the join model as well
- Default boolean columns to `false` unless the user specifies otherwise
- Place association macros before column definitions (Grant convention)
- Place validations after column definitions
- Place scopes after validations
