---
title: "Creating Your First Model"
category: "core-features"
subcategory: "getting-started"
tags: ["tutorial", "models", "beginner", "orm", "database"]
complexity: "beginner"
version: "1.0.0"
prerequisites: ["installation.md", "database-setup.md"]
related_docs: ["quick-start.md", "../core-features/models-and-columns.md", "../core-features/crud-operations.md"]
last_updated: "2025-01-13"
estimated_read_time: "10 minutes"
use_cases: ["learning", "web-development", "api-development"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Creating Your First Model

Learn how to create, configure, and use Grant models step by step. By the end of this tutorial, you'll understand the fundamentals of working with Grant ORM.

## What is a Model?

A model in Grant represents a database table and provides an object-oriented interface for interacting with your data. Each model:
- Maps to a database table
- Defines columns and their types
- Handles CRUD operations
- Manages relationships
- Enforces validations

## Step 1: Basic Model Definition

Let's create a simple `User` model:

```crystal
require "grant/adapter/pg"  # or mysql, sqlite

class User < Grant::Base
  # Specify which database connection to use
  connection pg
  
  # Specify the table name (optional, defaults to plural of class name)
  table users
  
  # Define columns
  column id : Int64, primary: true
  column name : String
  column email : String
  column age : Int32
  column active : Bool = true
  
  # Automatic timestamp columns
  timestamps
end
```

### Understanding the Components

- **`Grant::Base`**: All models inherit from this base class
- **`connection`**: Specifies which database adapter to use
- **`table`**: Explicitly sets the table name (optional)
- **`column`**: Defines a database column with its type
- **`primary: true`**: Marks the primary key column
- **`timestamps`**: Adds `created_at` and `updated_at` columns

## Step 2: Column Types and Options

Grant supports all Crystal primitive types and several options:

```crystal
class Product < Grant::Base
  connection pg
  table products
  
  # Primary key (auto-incrementing by default)
  column id : Int64, primary: true
  
  # Required fields (not nilable)
  column name : String
  column price : Float64
  column quantity : Int32
  
  # Optional fields (nilable)
  column description : String?
  column discount : Float64?
  
  # With default values
  column status : String = "draft"
  column featured : Bool = false
  column views : Int32 = 0
  
  # Special types
  column uuid : UUID, primary: true  # UUID primary key
  column metadata : JSON::Any?       # JSON column
  column tags : Array(String)?       # Array (PostgreSQL)
  column published_at : Time?        # DateTime
  
  # Automatic timestamps
  timestamps  # adds created_at and updated_at
end
```

### Supported Column Types

| Crystal Type | Database Type | Example |
|-------------|---------------|---------|
| `String` | VARCHAR/TEXT | `column name : String` |
| `Int32` | INTEGER | `column age : Int32` |
| `Int64` | BIGINT | `column id : Int64` |
| `Float32` | FLOAT | `column rating : Float32` |
| `Float64` | DOUBLE | `column price : Float64` |
| `Bool` | BOOLEAN | `column active : Bool` |
| `Time` | TIMESTAMP | `column created_at : Time` |
| `UUID` | UUID/CHAR(36) | `column uuid : UUID` |
| `JSON::Any` | JSON/JSONB/TEXT | `column settings : JSON::Any` |
| `Array(T)` | ARRAY/JSON | `column tags : Array(String)` |

## Step 3: Adding Validations

Ensure data integrity with validations:

```crystal
class User < Grant::Base
  connection pg
  table users
  
  column id : Int64, primary: true
  column name : String
  column email : String
  column age : Int32
  column username : String
  column bio : String?
  column terms_accepted : Bool = false
  
  timestamps
  
  # Built-in validations
  validate_presence :name
  validate_presence :email
  validate_uniqueness :email
  validate_uniqueness :username
  validate_format :email, /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  validate_length :username, min: 3, max: 20
  validate_length :bio, max: 500
  validate_numericality :age, greater_than: 0, less_than: 150
  
  # Custom validations
  validate :terms_accepted, "must be accepted" do |user|
    user.terms_accepted == true
  end
  
  validate :email, "must be from allowed domain" do |user|
    allowed_domains = ["example.com", "company.com"]
    domain = user.email.split("@").last
    allowed_domains.includes?(domain)
  end
end
```

## Step 4: Creating the Database Table

### Option A: Using Migrations (Recommended)

Create a migration file:

```crystal
# db/migrations/001_create_users.cr
class CreateUsers < Grant::Migration
  def up
    create_table :users do |t|
      t.integer :id, primary: true
      t.string :name, null: false
      t.string :email, null: false
      t.string :username, null: false
      t.integer :age, null: false
      t.text :bio
      t.boolean :terms_accepted, default: false
      
      t.timestamps
      
      # Indexes
      t.index :email, unique: true
      t.index :username, unique: true
    end
  end
  
  def down
    drop_table :users
  end
end
```

### Option B: Raw SQL

```crystal
# setup_database.cr
db = Grant::Connections["pg"]

db.exec <<-SQL
  CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    username VARCHAR(255) NOT NULL UNIQUE,
    age INTEGER NOT NULL,
    bio TEXT,
    terms_accepted BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  
  CREATE INDEX idx_users_email ON users(email);
  CREATE INDEX idx_users_username ON users(username);
SQL
```

## Step 5: CRUD Operations

### Create

```crystal
# Create with individual attributes
user = User.new
user.name = "John Doe"
user.email = "john@example.com"
user.username = "johndoe"
user.age = 30
user.terms_accepted = true

if user.save
  puts "User created with ID: #{user.id}"
else
  puts "Errors: #{user.errors.full_messages.join(", ")}"
end

# Create with a block
user = User.new do |u|
  u.name = "Jane Smith"
  u.email = "jane@example.com"
  u.username = "janesmith"
  u.age = 28
  u.terms_accepted = true
end
user.save!  # Raises exception if invalid

# Create directly (saves immediately)
user = User.create(
  name: "Bob Wilson",
  email: "bob@example.com",
  username: "bobwilson",
  age: 35,
  terms_accepted: true
)

# Create with validation check
user = User.create(
  name: "Alice Johnson",
  email: "alice@example.com",
  username: "alice",
  age: 25,
  terms_accepted: true
)

if user.persisted?
  puts "Successfully created user"
else
  puts "Failed to create user: #{user.errors.full_messages}"
end
```

### Read

```crystal
# Find by primary key
user = User.find(1)
user = User.find!(1)  # Raises exception if not found

# Find by attributes
user = User.find_by(email: "john@example.com")
user = User.find_by!(username: "johndoe")

# Get first/last records
first_user = User.first
last_user = User.last

# Get all records
all_users = User.all

# Query with conditions
active_adults = User.where(terms_accepted: true).where("age >= ?", [18])
young_users = User.where("age < ?", [30])

# Ordering
newest_users = User.order(created_at: :desc)
users_by_name = User.order(:name)

# Limiting and offsetting
top_10_users = User.limit(10)
next_10_users = User.limit(10).offset(10)

# Counting
total_users = User.count
adult_count = User.where("age >= ?", [18]).count

# Checking existence
exists = User.exists?(email: "john@example.com")
any_users = User.any?
no_users = User.none?
```

### Update

```crystal
# Find and update
user = User.find(1)
user.email = "newemail@example.com"
user.age = 31

if user.save
  puts "User updated successfully"
else
  puts "Update failed: #{user.errors.full_messages}"
end

# Update with validation
user = User.find(1)
if user.update(email: "updated@example.com", age: 32)
  puts "Updated successfully"
else
  puts "Validation errors: #{user.errors.full_messages}"
end

# Update without validation (use carefully!)
user.update_columns(email: "forced@example.com")

# Mass update
User.where(terms_accepted: false).update_all(active: false)

# Update single attribute
user.update_attribute(:age, 33)
```

### Delete

```crystal
# Find and delete
user = User.find(1)
user.destroy

# Delete by ID
User.delete(1)

# Delete multiple
User.where("created_at < ?", [30.days.ago]).delete_all

# Destroy with callbacks
user = User.find(1)
if user.destroy
  puts "User deleted successfully"
else
  puts "Could not delete user"
end

# Check if deleted
puts user.destroyed?  # => true
```

## Step 6: Using Callbacks

Add behavior that runs at specific points in the model lifecycle:

```crystal
class User < Grant::Base
  connection pg
  table users
  
  column id : Int64, primary: true
  column name : String
  column email : String
  column email_confirmed : Bool = false
  column confirmation_token : String?
  
  timestamps
  
  # Callbacks
  before_create :generate_confirmation_token
  before_save :normalize_email
  after_create :send_welcome_email
  after_update :log_changes
  before_destroy :cleanup_associations
  
  private def generate_confirmation_token
    self.confirmation_token = Random::Secure.hex(16)
  end
  
  private def normalize_email
    self.email = email.downcase.strip
  end
  
  private def send_welcome_email
    # EmailService.deliver_welcome(self)
    puts "Welcome email would be sent to #{email}"
  end
  
  private def log_changes
    if email_changed?
      puts "Email changed from #{email_was} to #{email}"
    end
  end
  
  private def cleanup_associations
    # Clean up related data
    puts "Cleaning up user data..."
  end
end
```

## Step 7: Adding Relationships

Connect your model to other models:

```crystal
class User < Grant::Base
  connection pg
  table users
  
  column id : Int64, primary: true
  column name : String
  column email : String
  
  # One-to-many relationship
  has_many posts : Post
  has_many comments : Comment
  
  # One-to-one relationship
  has_one profile : Profile
  
  # Many-to-many through join table
  has_many user_roles : UserRole
  has_many roles : Role, through: :user_roles
  
  # Methods using relationships
  def admin?
    roles.any? { |r| r.name == "admin" }
  end
  
  def recent_posts
    posts.where("created_at > ?", [7.days.ago])
  end
end

class Post < Grant::Base
  connection pg
  table posts
  
  column id : Int64, primary: true
  column title : String
  column content : String
  column user_id : Int64
  
  # Belongs to relationship
  belongs_to user : User
  has_many comments : Comment
  
  # Validations with association
  validate_presence :user
end
```

## Step 8: Testing Your Model

Create a test file:

```crystal
# spec/models/user_spec.cr
require "../spec_helper"

describe User do
  describe "validations" do
    it "requires a name" do
      user = User.new(email: "test@example.com", age: 25)
      user.valid?.should be_false
      user.errors[:name].should contain("can't be blank")
    end
    
    it "requires a valid email" do
      user = User.new(name: "Test", email: "invalid", age: 25)
      user.valid?.should be_false
      user.errors[:email].should contain("is invalid")
    end
    
    it "enforces unique email" do
      User.create(name: "First", email: "test@example.com", age: 25)
      duplicate = User.new(name: "Second", email: "test@example.com", age: 30)
      duplicate.valid?.should be_false
      duplicate.errors[:email].should contain("has already been taken")
    end
  end
  
  describe "callbacks" do
    it "normalizes email before saving" do
      user = User.create(name: "Test", email: " TEST@EXAMPLE.COM ", age: 25)
      user.email.should eq("test@example.com")
    end
  end
  
  describe "associations" do
    it "has many posts" do
      user = User.create(name: "Author", email: "author@example.com", age: 30)
      post = Post.create(title: "Test", content: "Content", user: user)
      
      user.posts.should contain(post)
    end
  end
end
```

Run tests:
```bash
crystal spec spec/models/user_spec.cr
```

## Complete Example

Here's everything together in a working example:

```crystal
# app.cr
require "grant/adapter/pg"

# Configure database
Grant::Connections << Grant::Adapter::Pg.new(
  name: "pg",
  url: ENV["DATABASE_URL"]
)

# Define User model
class User < Grant::Base
  connection pg
  table users
  
  # Columns
  column id : Int64, primary: true
  column name : String
  column email : String
  column age : Int32
  column active : Bool = true
  timestamps
  
  # Validations
  validate_presence :name
  validate_presence :email
  validate_uniqueness :email
  validate_format :email, /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  
  # Callbacks
  before_save :normalize_email
  
  # Associations
  has_many posts : Post
  
  # Scopes
  scope active { where(active: true) }
  scope adults { where("age >= ?", [18]) }
  
  # Instance methods
  def full_info
    "#{name} (#{email})"
  end
  
  private def normalize_email
    self.email = email.downcase.strip
  end
end

# Define Post model
class Post < Grant::Base
  connection pg
  table posts
  
  column id : Int64, primary: true
  column title : String
  column content : String
  column published : Bool = false
  column user_id : Int64
  timestamps
  
  belongs_to user : User
  
  scope published { where(published: true) }
  scope recent { order(created_at: :desc) }
end

# Use the models
user = User.create(
  name: "John Doe",
  email: "john@example.com",
  age: 30
)

post = user.posts.create(
  title: "My First Post",
  content: "Hello, Grant ORM!",
  published: true
)

# Query data
User.active.adults.each do |user|
  puts "#{user.name}: #{user.posts.published.count} published posts"
end
```

## Best Practices

1. **Always use validations** to ensure data integrity
2. **Use callbacks sparingly** - only for model-specific logic
3. **Create indexes** on frequently queried columns
4. **Use scopes** for commonly used queries
5. **Test your models** thoroughly
6. **Keep models focused** - extract complex logic to service objects
7. **Use transactions** for operations that must succeed together

## Troubleshooting

### Model not finding table
```crystal
# Explicitly specify table name
table :my_custom_table_name
```

### Column type mismatch
```crystal
# Ensure Crystal type matches database type
column age : Int32  # not Int64 for INTEGER columns
```

### Validation not working
```crystal
# Check if you're calling save or valid?
user.valid?  # Runs validations
user.save    # Runs validations and saves if valid
user.save!   # Raises exception if invalid
```

## Next Steps

- [CRUD Operations in depth](../core-features/crud-operations.md)
- [Advanced Querying](../core-features/querying-and-scopes.md)
- [Model Relationships](../core-features/relationships.md)
- [Validations Guide](../core-features/validations.md)
- [Callbacks and Lifecycle](../core-features/callbacks-lifecycle.md)