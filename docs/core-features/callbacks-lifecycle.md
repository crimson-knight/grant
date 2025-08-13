---
title: "Callbacks and Lifecycle"
category: "core-features"
subcategory: "callbacks"
tags: ["callbacks", "lifecycle", "hooks", "events", "triggers"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["models-and-columns.md", "crud-operations.md", "validations.md"]
related_docs: ["relationships.md", "../advanced/data-management/transactions.md"]
last_updated: "2025-01-13"
estimated_read_time: "12 minutes"
use_cases: ["data-processing", "audit-trails", "cache-management", "notifications"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Callbacks and Lifecycle

Comprehensive guide to Grant's callback system, allowing you to hook into the lifecycle of your models and execute code at specific points.

## Overview

Callbacks are methods that get called at certain moments of an object's lifecycle. They allow you to trigger logic before or after alterations to your model's state.

```crystal
class Post < Grant::Base
  before_save :normalize_title
  after_create :send_notification
  before_destroy :check_permissions
  
  column id : Int64, primary: true
  column title : String
  column published : Bool = false
  
  private def normalize_title
    self.title = title.strip.squeeze(" ")
  end
  
  private def send_notification
    NotificationService.post_created(self)
  end
  
  private def check_permissions
    unless deletable?
      errors.add(:base, "Cannot delete published posts")
      throw :abort
    end
  end
end
```

## Available Callbacks

### Create Callbacks

The complete callback chain for creating a new record:

```crystal
class User < Grant::Base
  before_validation :set_defaults           # 1. First callback
  # validations run here                    # 2. Validations
  after_validation :process_validated_data  # 3. After validation
  before_save :before_save_tasks           # 4. Before save (create or update)
  before_create :before_create_tasks       # 5. Before create specifically
  # INSERT happens here                     # 6. Database insert
  after_create :after_create_tasks         # 7. After create
  after_save :after_save_tasks            # 8. After save (create or update)
  after_commit :after_commit_tasks        # 9. After transaction commits
end
```

### Update Callbacks

The complete callback chain for updating an existing record:

```crystal
class Product < Grant::Base
  before_validation :normalize_data         # 1. First callback
  # validations run here                    # 2. Validations
  after_validation :process_changes        # 3. After validation
  before_save :before_save_tasks          # 4. Before save
  before_update :before_update_tasks      # 5. Before update specifically
  # UPDATE happens here                    # 6. Database update
  after_update :after_update_tasks        # 7. After update
  after_save :after_save_tasks           # 8. After save
  after_commit :after_commit_tasks       # 9. After transaction commits
end
```

### Destroy Callbacks

The complete callback chain for destroying a record:

```crystal
class Comment < Grant::Base
  before_destroy :cleanup_associations     # 1. Before destroy
  # DELETE happens here                    # 2. Database delete
  after_destroy :log_deletion             # 3. After destroy
  after_commit :notify_deletion          # 4. After transaction commits
end
```

## Callback Registration

### Method Symbols

```crystal
class Article < Grant::Base
  before_save :sanitize_content
  after_create :publish_to_feed
  
  private def sanitize_content
    self.content = Sanitizer.clean(content)
  end
  
  private def publish_to_feed
    FeedService.publish(self) if published?
  end
end
```

### Blocks

```crystal
class Order < Grant::Base
  before_save do
    self.total = calculate_total
  end
  
  after_create do
    OrderMailer.confirmation(self).deliver_later
  end
end
```

### Conditional Callbacks

```crystal
class Post < Grant::Base
  # With symbol conditions
  before_save :update_slug, if: :title_changed?
  after_create :notify_subscribers, if: :published?
  
  # With proc conditions
  before_destroy :archive_content, 
    if: ->(post : Post) { post.views > 1000 }
  
  # Multiple conditions
  after_save :clear_cache,
    if: :published?,
    unless: :draft?
end
```

### Multiple Callbacks

```crystal
class User < Grant::Base
  # Multiple callbacks for same event
  before_save :normalize_email
  before_save :hash_password
  before_save :set_defaults
  
  # Callbacks run in order of registration
end
```

## Common Callback Patterns

### Data Normalization

```crystal
class User < Grant::Base
  before_validation :normalize_fields
  
  column email : String
  column phone : String?
  column name : String
  
  private def normalize_fields
    self.email = email.downcase.strip
    self.phone = phone.try(&.gsub(/\D/, ""))
    self.name = name.split.map(&.capitalize).join(" ")
  end
end
```

### Setting Defaults

```crystal
class Document < Grant::Base
  before_create :set_defaults
  
  column uuid : String
  column version : Int32
  column status : String
  
  private def set_defaults
    self.uuid ||= UUID.random.to_s
    self.version ||= 1
    self.status ||= "draft"
  end
end
```

### Generating Tokens

```crystal
class Session < Grant::Base
  before_create :generate_token
  
  column token : String
  column expires_at : Time
  
  private def generate_token
    loop do
      self.token = Random::Secure.hex(32)
      break unless Session.exists?(token: token)
    end
    self.expires_at = 24.hours.from_now
  end
end
```

### Slug Generation

```crystal
class Article < Grant::Base
  before_save :generate_slug
  
  column title : String
  column slug : String
  
  private def generate_slug
    return unless title_changed?
    
    base_slug = title.downcase.gsub(/[^a-z0-9]+/, "-")
    self.slug = base_slug
    
    counter = 1
    while Article.exists?(slug: slug)
      self.slug = "#{base_slug}-#{counter}"
      counter += 1
    end
  end
end
```

### Audit Trails

```crystal
class AuditableModel < Grant::Base
  after_create :log_create
  after_update :log_update
  after_destroy :log_destroy
  
  private def log_create
    AuditLog.create(
      model: self.class.name,
      record_id: id,
      action: "create",
      user_id: Current.user_id,
      changes: attributes.to_json
    )
  end
  
  private def log_update
    if changes.any?
      AuditLog.create(
        model: self.class.name,
        record_id: id,
        action: "update",
        user_id: Current.user_id,
        changes: changes.to_json
      )
    end
  end
  
  private def log_destroy
    AuditLog.create(
      model: self.class.name,
      record_id: id,
      action: "destroy",
      user_id: Current.user_id,
      data: attributes.to_json
    )
  end
end
```

### Cache Management

```crystal
class Product < Grant::Base
  after_save :clear_cache
  after_destroy :clear_cache
  
  column category_id : Int64
  column price : Float64
  
  private def clear_cache
    Cache.delete("product:#{id}")
    Cache.delete("category:#{category_id}:products")
    Cache.delete("products:featured") if featured?
  end
end
```

### Dependent Cleanup

```crystal
class User < Grant::Base
  before_destroy :cleanup_associations
  
  has_many :posts
  has_many :comments
  has_one :profile
  
  private def cleanup_associations
    # Anonymize instead of delete
    posts.update_all(author_name: "Deleted User", user_id: nil)
    comments.update_all(author_name: "Deleted User", user_id: nil)
    profile.try(&.destroy)
  end
end
```

## Halting Execution

### Returning False (Legacy)

```crystal
class Post < Grant::Base
  before_save :validate_publishing
  
  private def validate_publishing
    if publishing? && !ready_to_publish?
      errors.add(:base, "Post not ready to publish")
      false  # Halts the callback chain
    else
      true
    end
  end
end
```

### Throwing :abort (Recommended)

```crystal
class Order < Grant::Base
  before_save :check_inventory
  
  private def check_inventory
    if total_items > available_stock
      errors.add(:items, "Insufficient inventory")
      throw :abort  # Halts execution
    end
  end
end
```

### With Validations

```crystal
class User < Grant::Base
  before_destroy :prevent_admin_deletion
  
  private def prevent_admin_deletion
    if admin? && User.where(admin: true).count == 1
      errors.add(:base, "Cannot delete the last admin")
      throw :abort
    end
  end
end
```

## Transaction Callbacks

### after_commit

Runs after the database transaction successfully commits:

```crystal
class Order < Grant::Base
  after_commit :send_confirmation, on: :create
  after_commit :update_inventory, on: :update
  
  private def send_confirmation
    # Safe to send email - transaction committed
    OrderMailer.confirmation(self).deliver_later
  end
  
  private def update_inventory
    # Safe to call external services
    InventoryService.sync(self)
  end
end
```

### after_rollback

Runs if the database transaction is rolled back:

```crystal
class Payment < Grant::Base
  after_rollback :log_failure
  
  private def log_failure
    Rails.logger.error "Payment #{id} failed to save: #{errors.full_messages}"
    PaymentFailureNotifier.notify(self)
  end
end
```

## Callback Classes

For complex or reusable callbacks:

```crystal
class TimestampCallback
  def self.before_create(record)
    record.created_at = Time.utc
    record.updated_at = Time.utc
  end
  
  def self.before_update(record)
    record.updated_at = Time.utc
  end
end

class SlugCallback
  def self.before_save(record)
    return unless record.responds_to?(:title) && record.responds_to?(:slug)
    return unless record.title_changed?
    
    record.slug = record.title.downcase.gsub(/[^a-z0-9]+/, "-")
  end
end

class Article < Grant::Base
  before_create TimestampCallback.before_create
  before_update TimestampCallback.before_update
  before_save SlugCallback.before_save
end
```

## Callback Inheritance

```crystal
class ApplicationModel < Grant::Base
  # Common callbacks for all models
  before_save :track_changes
  after_save :log_activity
  
  private def track_changes
    @changed_attributes = changes
  end
  
  private def log_activity
    ActivityLog.track(self, @changed_attributes)
  end
end

class User < ApplicationModel
  # Inherits callbacks from ApplicationModel
  # Plus its own callbacks
  before_save :normalize_email
  
  private def normalize_email
    self.email = email.downcase
  end
end
```

## Skipping Callbacks

```crystal
class User < Grant::Base
  before_save :expensive_operation
  
  # Skip callbacks when needed
  def update_without_callbacks(attributes)
    assign_attributes(attributes)
    save(validate: false, skip_callbacks: true)
  end
  
  # Bulk operations typically skip callbacks
  def self.bulk_update(ids, attributes)
    where(id: ids).update_all(attributes)  # No callbacks
  end
end
```

## Performance Considerations

### 1. Keep Callbacks Fast

```crystal
class Post < Grant::Base
  # Bad: Synchronous external call
  after_create :notify_external_service
  
  private def notify_external_service
    HTTPClient.post("https://api.example.com/webhook", body: to_json)
  end
  
  # Good: Queue for background processing
  after_create :queue_notification
  
  private def queue_notification
    NotificationJob.perform_later(self.id)
  end
end
```

### 2. Avoid N+1 Queries

```crystal
class Comment < Grant::Base
  belongs_to :post
  
  # Bad: N+1 query
  after_save :update_post_activity
  
  private def update_post_activity
    post.update(last_activity: Time.utc)
  end
  
  # Good: Batch or optimize
  after_commit :queue_post_update
  
  private def queue_post_update
    PostActivityJob.perform_later(post_id)
  end
end
```

### 3. Use Conditional Callbacks

```crystal
class User < Grant::Base
  # Only run expensive callbacks when necessary
  after_save :sync_to_crm, if: :crm_fields_changed?
  after_save :clear_cache, if: :significant_change?
  
  private def crm_fields_changed?
    (changes.keys & ["email", "name", "company"]).any?
  end
  
  private def significant_change?
    !changes.empty?
  end
end
```

## Testing Callbacks

```crystal
describe Post do
  describe "callbacks" do
    it "normalizes title before save" do
      post = Post.new(title: "  Multiple   Spaces  ")
      post.save
      
      post.title.should eq("Multiple Spaces")
    end
    
    it "prevents destroying published posts" do
      post = Post.create(title: "Test", published: true)
      
      post.destroy.should be_false
      post.errors[:base].should include("Cannot delete published posts")
      Post.exists?(post.id).should be_true
    end
    
    it "generates unique slug" do
      Post.create(title: "My Post")
      post2 = Post.create(title: "My Post")
      
      post2.slug.should eq("my-post-1")
    end
  end
end
```

## Best Practices

### 1. Keep Callbacks Simple

```crystal
# Good: Single responsibility
before_save :normalize_email
before_save :hash_password
before_save :set_defaults

# Bad: Doing too much
before_save :do_everything
```

### 2. Use Appropriate Callback

```crystal
# Good: after_commit for external services
after_commit :send_email

# Bad: after_save might send email even if rolled back
after_save :send_email
```

### 3. Avoid Callback Loops

```crystal
class User < Grant::Base
  has_one :profile
  after_save :update_profile
  
  # Careful: This could cause infinite loop
  private def update_profile
    profile.update(last_updated: Time.utc)  # Triggers Profile callbacks
  end
end
```

### 4. Document Side Effects

```crystal
class Order < Grant::Base
  # Callback: Sends confirmation email after creation
  # Side effect: Decrements inventory
  after_create :process_order
  
  private def process_order
    OrderMailer.confirmation(self).deliver_later
    InventoryService.decrement(line_items)
  end
end
```

### 5. Consider Service Objects

```crystal
# Instead of complex callbacks
class User < Grant::Base
  after_create :setup_user_account
  
  private def setup_user_account
    UserAccountSetupService.new(self).perform
  end
end

# Service object handles complexity
class UserAccountSetupService
  def initialize(@user : User)
  end
  
  def perform
    create_profile
    send_welcome_email
    assign_default_role
    track_signup
  end
end
```

## Troubleshooting

### Callbacks Not Running

```crystal
# Callbacks skip on certain operations
User.update_all(active: false)  # No callbacks
user.save(skip_callbacks: true)  # Explicitly skipped
user.update_columns(name: "New")  # Direct SQL, no callbacks
```

### Callback Order Issues

```crystal
# Callbacks run in registration order
before_save :first_callback
before_save :second_callback  # Runs after first
```

### Transaction Issues

```crystal
# Use after_commit for external services
after_commit :notify_external_api  # Safe
after_save :notify_external_api    # Risky - might rollback
```

## Next Steps

- [Validations](validations.md)
- [Transactions](../advanced/data-management/transactions.md)
- [Testing Models](../development/testing-guide.md)
- [Service Objects](../patterns/service-objects.md)