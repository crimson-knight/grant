# Enum Attributes

Grant provides Rails-style enum attributes that make working with enumerated values more convenient and idiomatic. This feature generates helper methods, scopes, and validations for Crystal enum types.

## Overview

Enum attributes provide:
- Predicate methods (`draft?`, `published?`)
- Bang methods to set values (`draft!`, `published!`)
- Automatic scopes for each enum value
- Type-safe enum handling with Crystal's type system
- Flexible storage options (string, integer)
- Default value support

## Basic Usage

### Defining an Enum Attribute

```crystal
class Article < Granite::Base
  connection postgres
  table articles
  
  column id : Int64, primary: true
  column title : String
  
  # Define the enum type
  enum Status
    Draft
    Published
    Archived
  end
  
  # Create enum attribute with default value
  enum_attribute status : Status = :draft
end
```

This automatically:
1. Creates a column with appropriate converter
2. Generates helper methods for each enum value
3. Creates scopes for querying
4. Sets up default value handling

### Using Enum Attributes

```crystal
article = Article.new(title: "My Article")

# Check current status
article.draft?      # => true
article.published?  # => false

# Change status using bang methods
article.published!
article.published?  # => true
article.status      # => Article::Status::Published

# Direct assignment
article.status = Article::Status::Archived
article.archived?   # => true
```

### Querying with Scopes

Each enum value automatically gets a scope:

```crystal
# Find all draft articles
Article.draft.each do |article|
  puts article.title
end

# Find published articles with additional conditions
Article.published
  .where("created_at > ?", 30.days.ago)
  .order(created_at: :desc)

# Count by status
puts "Draft: #{Article.draft.count}"
puts "Published: #{Article.published.count}"
```

## Advanced Usage

### Custom Column Types

By default, enums are stored as strings. You can use integers for better performance:

```crystal
class User < Granite::Base
  enum Role
    Guest = 0
    Member = 1
    Admin = 2
  end
  
  # Store as integer in database
  enum_attribute role : Role = :member, column_type: Int32
end
```

### Multiple Enum Attributes

You can define multiple enums using `enum_attributes`:

```crystal
class Task < Granite::Base
  enum Status
    Pending
    InProgress
    Completed
    Cancelled
  end
  
  enum Priority
    Low
    Medium
    High
    Urgent
  end
  
  # Define multiple enum attributes at once
  enum_attributes status: {type: Status, default: :pending},
                  priority: {type: Priority, default: :medium}
end

task = Task.new
task.pending?  # => true
task.medium?   # => true
task.urgent!   # Sets priority to urgent
```

### Optional Enums

Enum attributes can be nilable:

```crystal
class Product < Granite::Base
  enum Category
    Electronics
    Clothing
    Food
    Other
  end
  
  # Optional enum with no default
  enum_attribute category : Category?
end

product = Product.new
product.category    # => nil
product.electronics!
product.category    # => Product::Category::Electronics
```

### Custom Converters

If you need custom serialization logic:

```crystal
class Order < Granite::Base
  enum Status
    Pending
    Processing
    Shipped
    Delivered
  end
  
  # Use a custom converter
  enum_attribute status : Status, 
    converter: MyCustomStatusConverter
end
```

## Validations

Enum attributes automatically validate that values are within the allowed set:

```crystal
class Post < Granite::Base
  enum Visibility
    Public
    Private
    Unlisted
  end
  
  enum_attribute visibility : Visibility = :public
  
  # Additional custom validation
  validate "visibility must be public for featured posts" do |post|
    !post.featured? || post.public?
  end
end
```

## Class Methods

Enum attributes provide useful class methods:

```crystal
# Get all possible values
Article.statuses  # => [Status::Draft, Status::Published, Status::Archived]

# Get string mapping
Article.status_mapping
# => {"draft" => Status::Draft, "published" => Status::Published, ...}

# Useful for form selects
Article.status_mapping.map { |k, v| {k.titleize, v} }
```

## Database Migrations

When creating tables with enum columns:

```sql
-- String storage (default)
CREATE TABLE articles (
  id SERIAL PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  status VARCHAR(50) DEFAULT 'draft'
);

-- Integer storage
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  role INTEGER DEFAULT 1
);
```

Add indexes for better query performance:

```sql
CREATE INDEX idx_articles_status ON articles(status);
CREATE INDEX idx_users_role ON users(role);
```

## Best Practices

### 1. Use Descriptive Names

```crystal
# Good
enum ArticleStatus
  Draft
  UnderReview
  Published
  Archived
end

# Less clear
enum Status
  A
  B
  C
  D
end
```

### 2. Consider Storage Type

- Use **strings** when:
  - You need human-readable database values
  - You might add/remove enum values frequently
  - You're debugging database directly

- Use **integers** when:
  - Performance is critical
  - Storage space is important
  - Enum values are stable

### 3. Set Appropriate Defaults

```crystal
# Good - sensible default
enum_attribute status : Status = :draft

# Consider if nil is appropriate
enum_attribute category : Category?  # No default, can be nil
```

### 4. Use Scopes for Complex Queries

```crystal
class Article < Granite::Base
  enum Status
    Draft
    Published
    Archived
  end
  
  enum_attribute status : Status = :draft
  
  # Combine enum scopes with other scopes
  scope :recent, -> { where("created_at > ?", 7.days.ago) }
  scope :featured, -> { where(featured: true) }
  
  # Usage
  Article.published.recent.featured
end
```

## Comparison with Rails

Grant's enum implementation is similar to Rails but leverages Crystal's type system:

### Rails
```ruby
class Article < ApplicationRecord
  enum status: { draft: 0, published: 1, archived: 2 }
end
```

### Grant
```crystal
class Article < Granite::Base
  enum Status
    Draft = 0
    Published = 1
    Archived = 2
  end
  
  enum_attribute status : Status = :draft, column_type: Int32
end
```

Key differences:
- Grant uses Crystal's native enum types (type-safe)
- Explicit type declarations required
- Converter pattern for serialization
- Compile-time checking of enum values

## Troubleshooting

### Enum Value Not Found

If you get errors about enum values not being found:

```crystal
# This might happen with string storage if case doesn't match
Article.find_by(status: "DRAFT")  # Database has "draft"

# Solution: Use the enum directly
Article.find_by(status: Article::Status::Draft)
```

### Migration from Raw Columns

If migrating from a regular string/integer column:

```crystal
# Before
column status : String

# After migration
enum Status
  Draft
  Published
  Archived
end

enum_attribute status : Status = :draft

# Ensure existing data matches enum values exactly
```

### Custom Value Mapping

For legacy databases with specific values:

```crystal
enum Status
  Draft = 10      # Maps to 10 in database
  Published = 20  # Maps to 20 in database
  Archived = 99   # Maps to 99 in database
end
```

## Future Enhancements

Potential future additions:
- `_before_type_cast` methods
- Enum value translations/i18n
- Multiple values selection (flags)
- Automatic GraphQL enum type generation