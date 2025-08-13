---
title: "Enum Attributes"
category: "advanced"
subcategory: "specialized"
tags: ["enums", "attributes", "state-machines", "type-safety", "rails-compatible"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../../core-features/models-and-columns.md", "../../core-features/querying-and-scopes.md"]
related_docs: ["value-objects.md", "serialized-columns.md", "../../core-features/validations.md"]
last_updated: "2025-01-13"
estimated_read_time: "14 minutes"
use_cases: ["status-tracking", "state-machines", "categorization", "permissions", "workflows"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Enum Attributes

Comprehensive guide to using enum attributes in Grant, providing Rails-style convenience methods, type-safe enumerations, and automatic scopes for Crystal enum types.

## Overview

Enum attributes provide a powerful way to work with enumerated values in your models. They combine Crystal's type-safe enums with Rails-style convenience methods, making it easy to manage states, statuses, and other categorical data.

### Key Features

- **Type Safety**: Leverage Crystal's compile-time type checking
- **Predicate Methods**: Automatic `status?` methods for each value
- **Bang Methods**: Quick setters like `published!`
- **Automatic Scopes**: Query methods for each enum value
- **Flexible Storage**: Store as strings or integers
- **Default Values**: Built-in default value support
- **Validation**: Automatic validation of enum values

## Basic Implementation

### Defining Enum Attributes

```crystal
class Article < Grant::Base
  connection pg
  table articles
  
  column id : Int64, primary: true
  column title : String
  column content : String
  
  # Define the enum type
  enum Status
    Draft
    UnderReview
    Published
    Archived
  end
  
  # Create enum attribute with default value
  enum_attribute status : Status = :draft
  
  # Alternative: Store as integer for performance
  enum Priority
    Low = 0
    Medium = 1
    High = 2
    Critical = 3
  end
  
  enum_attribute priority : Priority = :medium, column_type: Int32
end
```

### Using Enum Attributes

```crystal
article = Article.new(title: "My Article")

# Check current status
article.draft?         # => true
article.published?     # => false
article.status         # => Article::Status::Draft

# Change status using bang methods
article.published!
article.published?     # => true
article.draft?         # => false

# Direct assignment
article.status = Article::Status::UnderReview
article.under_review?  # => true

# Using enum values
article.priority = Article::Priority::High
article.high?          # => true
article.priority.value # => 2 (underlying integer)
```

### Querying with Scopes

```crystal
# Automatic scopes for each enum value
Article.draft           # All draft articles
Article.published       # All published articles
Article.under_review    # All under review

# Combine with other queries
Article.published
       .where("created_at > ?", 30.days.ago)
       .order(views: :desc)
       .limit(10)

# Query by multiple statuses
Article.where(status: [Article::Status::Draft, Article::Status::UnderReview])

# Exclude certain statuses
Article.where.not(status: Article::Status::Archived)
```

## Advanced Patterns

### State Machines

```crystal
class Order < Grant::Base
  column id : Int64, primary: true
  column total : Float64
  
  enum Status
    Pending
    Processing
    Shipped
    Delivered
    Cancelled
    Refunded
  end
  
  enum_attribute status : Status = :pending
  
  # State transition validations
  validate :valid_status_transition
  
  # Define allowed transitions
  ALLOWED_TRANSITIONS = {
    Status::Pending => [Status::Processing, Status::Cancelled],
    Status::Processing => [Status::Shipped, Status::Cancelled],
    Status::Shipped => [Status::Delivered],
    Status::Delivered => [Status::Refunded],
    Status::Cancelled => [] of Status,
    Status::Refunded => [] of Status
  }
  
  def can_transition_to?(new_status : Status) : Bool
    return true if status == new_status
    ALLOWED_TRANSITIONS[status].includes?(new_status)
  end
  
  def transition_to!(new_status : Status)
    raise "Invalid transition from #{status} to #{new_status}" unless can_transition_to?(new_status)
    
    self.status = new_status
    save!
    
    # Trigger side effects
    case new_status
    when .shipped?
      send_shipping_notification
    when .delivered?
      mark_payment_complete
    when .cancelled?
      release_inventory
    end
  end
  
  private def valid_status_transition
    return if new_record?
    return unless status_changed?
    
    unless can_transition_to?(status)
      errors.add(:status, "cannot transition from #{status_was} to #{status}")
    end
  end
end
```

### Multiple Enum Attributes

```crystal
class Task < Grant::Base
  column id : Int64, primary: true
  column title : String
  
  enum Status
    Todo
    InProgress
    Done
  end
  
  enum Priority
    Low
    Medium
    High
    Critical
  end
  
  enum Category
    Bug
    Feature
    Documentation
    Refactor
  end
  
  enum_attribute status : Status = :todo
  enum_attribute priority : Priority = :medium
  enum_attribute category : Category = :feature
  
  # Combined scopes
  scope :urgent, -> { high.or(critical) }
  scope :backlog, -> { todo.where(priority: [Priority::Low, Priority::Medium]) }
  scope :in_progress_bugs, -> { in_progress.bug }
  
  # Helper methods
  def urgent?
    high? || critical?
  end
  
  def needs_attention?
    (bug? && !done?) || critical?
  end
end
```

### Enum with Metadata

```crystal
class User < Grant::Base
  column id : Int64, primary: true
  column email : String
  
  enum Role
    Guest
    Member
    Moderator
    Admin
    SuperAdmin
    
    def permissions : Array(String)
      case self
      when .guest?
        ["read"]
      when .member?
        ["read", "create"]
      when .moderator?
        ["read", "create", "update", "moderate"]
      when .admin?
        ["read", "create", "update", "delete", "moderate"]
      when .super_admin?
        ["*"]
      else
        [] of String
      end
    end
    
    def level : Int32
      case self
      when .guest? then 0
      when .member? then 1
      when .moderator? then 2
      when .admin? then 3
      when .super_admin? then 4
      else 0
      end
    end
    
    def label : String
      case self
      when .super_admin? then "Super Administrator"
      else to_s.gsub("_", " ").capitalize
      end
    end
  end
  
  enum_attribute role : Role = :member
  
  def can?(permission : String) : Bool
    return true if role.permissions.includes?("*")
    role.permissions.includes?(permission)
  end
  
  def promote!
    next_role = Role.values.find { |r| r.level == role.level + 1 }
    self.role = next_role if next_role
    save!
  end
  
  def demote!
    prev_role = Role.values.find { |r| r.level == role.level - 1 }
    self.role = prev_role if prev_role
    save!
  end
end
```

### Flags and Bitwise Enums

```crystal
@[Flags]
enum Permission
  Read = 1
  Write = 2
  Delete = 4
  Admin = 8
end

class Resource < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  # Store multiple flags as integer
  enum_attribute permissions : Permission = :none, column_type: Int32
  
  def can_read?
    permissions.includes?(Permission::Read)
  end
  
  def can_write?
    permissions.includes?(Permission::Write)
  end
  
  def grant_permission(perm : Permission)
    self.permissions |= perm
  end
  
  def revoke_permission(perm : Permission)
    self.permissions &= ~perm
  end
  
  def readonly?
    permissions == Permission::Read
  end
  
  def full_access?
    permissions.includes?(Permission::Read | Permission::Write | Permission::Delete)
  end
end
```

## Database Considerations

### String vs Integer Storage

```crystal
# String storage (default) - More readable, portable
class Post < Grant::Base
  enum Visibility
    Public
    Private
    Unlisted
  end
  
  enum_attribute visibility : Visibility = :public
  # Stores as: "public", "private", "unlisted"
end

# Integer storage - Better performance, smaller size
class Post < Grant::Base
  enum Visibility
    Public = 0
    Private = 1
    Unlisted = 2
  end
  
  enum_attribute visibility : Visibility = :public, column_type: Int32
  # Stores as: 0, 1, 2
end
```

### Migration Examples

```sql
-- String enum column
ALTER TABLE articles ADD COLUMN status VARCHAR(20) DEFAULT 'draft';

-- Integer enum column
ALTER TABLE articles ADD COLUMN priority INTEGER DEFAULT 1;

-- PostgreSQL native enum type
CREATE TYPE article_status AS ENUM ('draft', 'under_review', 'published', 'archived');
ALTER TABLE articles ADD COLUMN status article_status DEFAULT 'draft';

-- MySQL enum column
ALTER TABLE articles ADD COLUMN status ENUM('draft', 'under_review', 'published', 'archived') DEFAULT 'draft';

-- Add check constraint for validation
ALTER TABLE articles ADD CONSTRAINT check_status 
CHECK (status IN ('draft', 'under_review', 'published', 'archived'));
```

### Indexing Enum Columns

```sql
-- Simple index for filtering
CREATE INDEX idx_articles_status ON articles(status);

-- Partial indexes for common queries
CREATE INDEX idx_articles_published 
ON articles(id) 
WHERE status = 'published';

-- Composite index for complex queries
CREATE INDEX idx_articles_status_created 
ON articles(status, created_at DESC);
```

## Validation and Callbacks

### Enum Validations

```crystal
class Document < Grant::Base
  enum Status
    Draft
    Review
    Approved
    Published
  end
  
  enum_attribute status : Status = :draft
  
  # Validate transitions
  validate :publishable_only_if_approved
  
  # Validate combinations
  validate :review_requires_reviewer
  
  private def publishable_only_if_approved
    if published? && !status_was.try(&.approved?)
      errors.add(:status, "can only publish approved documents")
    end
  end
  
  private def review_requires_reviewer
    if review? && reviewer_id.nil?
      errors.add(:reviewer_id, "is required for review status")
    end
  end
end
```

### Callbacks with Enums

```crystal
class Subscription < Grant::Base
  enum Status
    Trial
    Active
    Suspended
    Cancelled
    Expired
  end
  
  enum_attribute status : Status = :trial
  
  before_save :track_status_changes
  after_save :send_status_notifications
  
  private def track_status_changes
    if status_changed?
      self.status_changed_at = Time.utc
      self.previous_status = status_was.to_s
    end
  end
  
  private def send_status_notifications
    return unless saved_change_to_status?
    
    case status
    when .active?
      send_activation_email
    when .suspended?
      send_suspension_warning
    when .cancelled?
      send_cancellation_confirmation
    when .expired?
      send_renewal_reminder
    end
  end
end
```

## Integration Patterns

### With Scopes

```crystal
class Product < Grant::Base
  enum Status
    Draft
    Active
    Discontinued
  end
  
  enum StockLevel
    OutOfStock
    Low
    Normal
    High
  end
  
  enum_attribute status : Status = :draft
  enum_attribute stock_level : StockLevel = :normal
  
  # Combine enum scopes with custom scopes
  scope :available, -> { active.where.not(stock_level: StockLevel::OutOfStock) }
  scope :needs_restock, -> { active.where(stock_level: [StockLevel::OutOfStock, StockLevel::Low]) }
  scope :sellable, -> { active.where(stock_level: [StockLevel::Normal, StockLevel::High]) }
  
  # Dynamic scopes based on enum
  def self.by_statuses(statuses : Array(Status))
    where(status: statuses)
  end
end
```

### With Serialization

```crystal
class ApiResponse < Grant::Base
  enum Format
    Json
    Xml
    Csv
    Yaml
  end
  
  enum_attribute format : Format = :json
  
  def serialize(data)
    case format
    when .json?
      data.to_json
    when .xml?
      data.to_xml
    when .csv?
      data.to_csv
    when .yaml?
      data.to_yaml
    end
  end
  
  def content_type : String
    case format
    when .json? then "application/json"
    when .xml? then "application/xml"
    when .csv? then "text/csv"
    when .yaml? then "application/x-yaml"
    else "text/plain"
    end
  end
end
```

### With Permissions

```crystal
class Feature < Grant::Base
  enum AccessLevel
    Public
    Beta
    Alpha
    Internal
    Disabled
    
    def accessible_by?(user : User) : Bool
      case self
      when .public?
        true
      when .beta?
        user.beta_tester? || user.staff?
      when .alpha?
        user.alpha_tester? || user.staff?
      when .internal?
        user.staff?
      when .disabled?
        false
      else
        false
      end
    end
  end
  
  enum_attribute access_level : AccessLevel = :disabled
  
  scope :accessible_by, ->(user : User) {
    levels = AccessLevel.values.select { |level| level.accessible_by?(user) }
    where(access_level: levels)
  }
end
```

## Testing Enum Attributes

```crystal
describe Article do
  describe "enum attributes" do
    it "has correct default value" do
      article = Article.new(title: "Test")
      article.status.should eq(Article::Status::Draft)
      article.draft?.should be_true
    end
    
    it "provides predicate methods" do
      article = Article.new(title: "Test")
      
      article.draft?.should be_true
      article.published?.should be_false
      
      article.published!
      article.published?.should be_true
      article.draft?.should be_false
    end
    
    it "provides scopes" do
      Article.create!(title: "Draft", status: :draft)
      Article.create!(title: "Pub1", status: :published)
      Article.create!(title: "Pub2", status: :published)
      
      Article.draft.count.should eq(1)
      Article.published.count.should eq(2)
    end
    
    it "validates enum values" do
      article = Article.new(title: "Test")
      
      # Valid assignment
      article.status = Article::Status::Published
      article.valid?.should be_true
      
      # Invalid assignment would be caught at compile time
      # article.status = "invalid" # Compilation error
    end
  end
  
  describe "state transitions" do
    it "allows valid transitions" do
      order = Order.create!(total: 100.0)
      
      order.can_transition_to?(Order::Status::Processing).should be_true
      order.can_transition_to?(Order::Status::Delivered).should be_false
      
      order.transition_to!(Order::Status::Processing)
      order.processing?.should be_true
    end
    
    it "prevents invalid transitions" do
      order = Order.create!(total: 100.0, status: :shipped)
      
      expect_raises(Exception) do
        order.transition_to!(Order::Status::Pending)
      end
    end
  end
end
```

## Performance Optimization

### Caching Enum Lookups

```crystal
class CachedEnum < Grant::Base
  enum Category
    Electronics
    Clothing
    Books
    Food
    Other
  end
  
  enum_attribute category : Category = :other
  
  # Cache category counts
  @@category_counts = {} of Category => Int32
  
  def self.category_counts : Hash(Category, Int32)
    @@category_counts.empty? ? refresh_category_counts : @@category_counts
  end
  
  def self.refresh_category_counts
    @@category_counts = Category.values.map { |cat|
      {cat, where(category: cat).count}
    }.to_h
  end
end
```

### Batch Updates

```crystal
# Efficient bulk status updates
Article.draft.update_all(status: Article::Status::Published)

# Conditional bulk updates
Article.where("created_at < ?", 30.days.ago)
       .where(status: Article::Status::Draft)
       .update_all(status: Article::Status::Archived)
```

## Best Practices

### 1. Use Meaningful Names

```crystal
# Good: Clear, descriptive enum values
enum ArticleStatus
  Draft
  UnderReview
  Published
  Archived
end

# Bad: Ambiguous values
enum Status
  S1
  S2
  S3
end
```

### 2. Consider Storage Format

```crystal
# Use integers for frequently queried columns
enum_attribute priority : Priority, column_type: Int32

# Use strings for human-readable data
enum_attribute status : Status  # Default string storage
```

### 3. Document State Machines

```crystal
# Document allowed transitions
# State diagram:
# pending -> processing -> shipped -> delivered
#    |           |                        |
#    v           v                        v
# cancelled  cancelled                refunded
class Order < Grant::Base
  # ... implementation
end
```

### 4. Use Scopes for Complex Queries

```crystal
# Define reusable scopes
scope :active_content, -> { published.or(under_review) }
scope :archived_content, -> { archived.where("archived_at < ?", 90.days.ago) }
```

## Troubleshooting

### Migration Issues

```crystal
# Handle enum column changes carefully
class MigrateEnumValues < Grant::Migration
  def up
    # Map old values to new enum values
    execute <<-SQL
      UPDATE articles 
      SET status = CASE status
        WHEN 'active' THEN 'published'
        WHEN 'inactive' THEN 'draft'
        ELSE status
      END
    SQL
  end
end
```

### Enum Value Conflicts

```crystal
# Avoid method name conflicts
enum Status
  New      # Conflicts with Model.new
  Create   # Conflicts with Model.create
  Invalid  # Conflicts with validations
end

# Better: Use prefixes or different names
enum Status
  StatusNew
  StatusPending
  StatusComplete
end
```

## Next Steps

- [Value Objects](value-objects.md)
- [Serialized Columns](serialized-columns.md)
- [Polymorphic Associations](polymorphic-associations.md)
- [Validations](../../core-features/validations.md)