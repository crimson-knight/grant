---
title: "Dirty Tracking"
category: "advanced"
subcategory: "data-management"
tags: ["dirty-tracking", "change-detection", "attributes", "callbacks", "auditing", "state-management"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../../core-features/models-and-columns.md", "../../core-features/callbacks-lifecycle.md"]
related_docs: ["../../core-features/callbacks-lifecycle.md", "imports-exports.md", "../../core-features/validations.md"]
last_updated: "2025-01-13"
estimated_read_time: "15 minutes"
use_cases: ["audit-trails", "change-detection", "conditional-logic", "data-synchronization"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Dirty Tracking

Comprehensive guide to Grant's dirty tracking system for detecting and managing attribute changes, providing Rails-compatible APIs for tracking modifications to model data.

## Overview

Dirty tracking allows you to monitor changes to model attributes, providing insight into:
- Which attributes have been modified
- Original values before changes
- Previous values after saves
- Conditional logic based on changes
- Audit trail generation

This feature is essential for callbacks, validation logic, synchronization, and building robust data management systems.

## Basic Usage

### Detecting Changes

```crystal
# Load a record
user = User.find!(1)
user.changed?  # => false

# Modify attributes
user.name = "Jane Doe"
user.email = "jane@example.com"

# Check for changes
user.changed?  # => true
user.changed_attributes  # => ["name", "email"]

# After saving
user.save
user.changed?  # => false
```

### Accessing Change Information

```crystal
user = User.find!(1)
original_name = user.name  # => "John Smith"

user.name = "Jane Doe"
user.email = "jane.doe@example.com"

# Get all changes
user.changes
# => {"name" => {"John Smith", "Jane Doe"}, 
#     "email" => {"john@example.com", "jane.doe@example.com"}}

# Check specific attributes
user.name_changed?   # => true
user.phone_changed?  # => false

# Get original values
user.name_was  # => "John Smith"
user.email_was # => "john@example.com"
```

## Per-Attribute Methods

Grant automatically generates convenience methods for each attribute:

### Change Detection Methods

```crystal
class User < Grant::Base
  column name : String
  column email : String
  column age : Int32
  column active : Bool
end

user = User.find!(1)

# <attribute>_changed? - Check if attribute changed
user.name = "New Name"
user.name_changed?   # => true
user.email_changed?  # => false

# <attribute>_was - Get original value
user.name_was  # => "Original Name"

# <attribute>_change - Get [old, new] tuple
user.name_change  # => {"Original Name", "New Name"}
user.email_change # => nil (no change)

# <attribute>_will_change! - Mark for change (useful for mutable types)
user.metadata_will_change!
```

### Working with Different Types

```crystal
class Product < Grant::Base
  column price : Float64
  column tags : Array(String)
  column metadata : JSON::Any
  column published_at : Time?
end

product = Product.find!(1)

# Numeric changes
product.price = 29.99
product.price_was     # => 19.99
product.price_change  # => {19.99, 29.99}

# Array changes
product.tags = ["sale", "featured"]
product.tags_was      # => ["new"]
product.tags_changed? # => true

# JSON changes
product.metadata = JSON.parse(%({"color": "blue"}))
product.metadata_was  # => JSON.parse(%({"color": "red"}))

# Nullable fields
product.published_at = Time.utc
product.published_at_was      # => nil
product.published_at_changed? # => true
```

## Saved Changes

After saving, access information about what was changed:

```crystal
user = User.find!(1)
user.name = "Jane Doe"
user.email = "jane@example.com"
user.save

# After save, current changes are cleared
user.changed?  # => false

# But saved changes are available
user.saved_changes
# => {"name" => {"John", "Jane"}, 
#     "email" => {"john@old.com", "jane@example.com"}}

# Check specific saved changes
user.saved_change_to_attribute?("name")   # => true
user.saved_change_to_attribute?("phone")  # => false

# Get saved change details
user.saved_change_to_name  # => {"John", "Jane"}
user.attribute_before_last_save("name")  # => "John"
```

## Restoring Changes

Revert attributes to their original values:

```crystal
user = User.find!(1)
original_values = {
  name: user.name,
  email: user.email,
  phone: user.phone
}

# Make changes
user.name = "Changed Name"
user.email = "changed@example.com"
user.phone = "555-0123"

# Restore specific attributes
user.restore_attributes(["name", "email"])
user.name   # => original_values[:name]
user.email  # => original_values[:email]
user.phone  # => "555-0123" (still changed)

# Restore all attributes
user.phone = "555-9999"
user.restore_attributes
user.phone  # => original_values[:phone]
```

## Advanced Patterns

### Conditional Callbacks

```crystal
class Article < Grant::Base
  column title : String
  column slug : String
  column content : String
  column published : Bool
  column published_at : Time?
  
  before_save :generate_slug, if: :title_changed?
  before_save :set_published_time
  after_save :notify_subscribers, if: :became_published?
  after_save :clear_cache, if: :content_changed?
  
  private def generate_slug
    self.slug = title.downcase.gsub(/[^a-z0-9]+/, "-")
  end
  
  private def set_published_time
    if published_changed? && published
      self.published_at = Time.utc
    end
  end
  
  private def became_published?
    saved_change_to_published? && published
  end
  
  private def notify_subscribers
    NotificationJob.perform_later(self.id)
  end
  
  private def clear_cache
    Cache.delete("article:#{id}")
  end
end
```

### Audit Logging

```crystal
class AuditLog < Grant::Base
  column model_type : String
  column model_id : Int64
  column changes : JSON::Any
  column user_id : Int64?
  column action : String
  timestamps
end

module Auditable
  macro included
    after_create :log_create
    after_update :log_update
    after_destroy :log_destroy
    
    private def log_create
      AuditLog.create!(
        model_type: self.class.name,
        model_id: self.id,
        changes: JSON.parse(attributes.to_json),
        user_id: Current.user?.try(&.id),
        action: "create"
      )
    end
    
    private def log_update
      return unless saved_changes.any?
      
      AuditLog.create!(
        model_type: self.class.name,
        model_id: self.id,
        changes: JSON.parse(saved_changes.to_json),
        user_id: Current.user?.try(&.id),
        action: "update"
      )
    end
    
    private def log_destroy
      AuditLog.create!(
        model_type: self.class.name,
        model_id: self.id,
        changes: JSON.parse(attributes.to_json),
        user_id: Current.user?.try(&.id),
        action: "destroy"
      )
    end
  end
end

class User < Grant::Base
  include Auditable
  
  column name : String
  column email : String
  column role : String
end
```

### Smart Updates

```crystal
class SmartUpdater
  def self.update_if_changed(record, attributes)
    changed = false
    
    attributes.each do |key, value|
      if record.responds_to?("#{key}=")
        current = record.read_attribute(key)
        if current != value
          record.write_attribute(key, value)
          changed = true
        end
      end
    end
    
    if changed
      record.save
      Log.info { "Updated #{record.class}##{record.id}: #{record.saved_changes}" }
    else
      Log.debug { "No changes for #{record.class}##{record.id}" }
    end
    
    changed
  end
end

# Usage
user = User.find!(1)
SmartUpdater.update_if_changed(user, {
  name: "Jane Doe",
  email: "jane@example.com"
})
```

### Synchronization Tracking

```crystal
class SyncableModel < Grant::Base
  column last_synced_at : Time?
  column sync_version : Int32 = 0
  column sync_hash : String?
  
  before_save :update_sync_metadata, if: :has_syncable_changes?
  
  def needs_sync?
    changed? || last_synced_at.nil? || last_synced_at.not_nil! < updated_at
  end
  
  def syncable_attributes
    attributes.except("id", "created_at", "updated_at", "last_synced_at", "sync_version")
  end
  
  def calculate_sync_hash
    Digest::SHA256.hexdigest(syncable_attributes.to_json)
  end
  
  private def has_syncable_changes?
    (changed_attributes & syncable_attributes.keys).any?
  end
  
  private def update_sync_metadata
    self.sync_version += 1
    self.sync_hash = calculate_sync_hash
  end
  
  def mark_synced!
    update!(last_synced_at: Time.utc)
  end
end
```

## Edge Cases and Behavior

### Same Value Assignment

```crystal
user.name = "John"
user.name = "John"  # Setting same value
user.name_changed?  # => false
```

### Value Reversion

```crystal
user.name  # => "John"
user.name = "Jane"
user.name_changed?  # => true

user.name = "John"  # Revert to original
user.name_changed?  # => false
user.changed?       # => false
```

### Type Coercion

```crystal
class Product < Grant::Base
  column price : Float64
  column quantity : Int32
end

product.price = "19.99"  # String input
product.price_changed?   # => true
product.price            # => 19.99 (Float64)
product.price_was        # => 9.99
```

### Mutable Types

```crystal
class Document < Grant::Base
  column tags : Array(String)
  column metadata : Hash(String, String)
end

doc = Document.find!(1)

# Direct mutation doesn't trigger change tracking
doc.tags << "new-tag"
doc.tags_changed?  # => false

# Mark as changed explicitly
doc.tags_will_change!
doc.tags << "another-tag"
doc.tags_changed?  # => true

# Or reassign
doc.tags = doc.tags + ["new-tag"]
doc.tags_changed?  # => true
```

## Performance Optimization

### Selective Change Tracking

```crystal
class OptimizedModel < Grant::Base
  # Disable tracking for large fields
  column content : String
  column cached_html : String?  # Large, derived field
  
  # Skip tracking for specific attributes
  def track_attribute_change?(attr : String) : Bool
    attr != "cached_html"
  end
  
  before_save :regenerate_cache, if: :content_changed?
  
  private def regenerate_cache
    self.cached_html = Markdown.to_html(content)
  end
end
```

### Batch Operations

```crystal
# Efficient bulk updates without change tracking
User.where(active: false).update_all(deleted_at: Time.utc)

# vs. tracking each change
User.where(active: false).each do |user|
  user.deleted_at = Time.utc
  user.save  # Triggers change tracking
end
```

### Memory Management

```crystal
class LargeDataModel < Grant::Base
  column data : String  # Potentially large
  
  # Clear change tracking after processing
  def process_with_cleanup
    yield self
  ensure
    clear_changes_information if persisted?
  end
end

# Usage
model.process_with_cleanup do |m|
  m.data = large_content
  m.save
  # Change tracking cleared after block
end
```

## Testing Dirty Tracking

```crystal
describe User do
  describe "dirty tracking" do
    it "tracks attribute changes" do
      user = User.create!(name: "John", email: "john@example.com")
      
      user.changed?.should be_false
      
      user.name = "Jane"
      user.changed?.should be_true
      user.name_changed?.should be_true
      user.name_was.should eq("John")
      user.name_change.should eq({"John", "Jane"})
    end
    
    it "tracks saved changes" do
      user = User.create!(name: "John")
      user.name = "Jane"
      user.save
      
      user.saved_changes.should eq({"name" => {"John", "Jane"}})
      user.saved_change_to_name?.should be_true
    end
    
    it "restores attributes" do
      user = User.create!(name: "John", email: "john@example.com")
      
      user.name = "Jane"
      user.email = "jane@example.com"
      
      user.restore_attributes(["name"])
      user.name.should eq("John")
      user.email.should eq("jane@example.com")
    end
    
    it "handles type conversions" do
      product = Product.create!(price: 19.99)
      
      product.price = "29.99"
      product.price_changed?.should be_true
      product.price.should eq(29.99)
      product.price_was.should eq(19.99)
    end
  end
end
```

## Integration with Other Features

### With Validations

```crystal
class EmailChangeRequest < Grant::Base
  column user_id : Int64
  column old_email : String
  column new_email : String
  column confirmed : Bool = false
  
  validate :email_actually_changed
  
  private def email_actually_changed
    if new_email == old_email
      errors.add(:new_email, "must be different from current email")
    end
  end
end
```

### With Callbacks

```crystal
class CachedModel < Grant::Base
  column name : String
  column description : String
  column cache_key : String
  
  before_save :update_cache_key, if: :should_update_cache?
  
  private def should_update_cache?
    name_changed? || description_changed?
  end
  
  private def update_cache_key
    self.cache_key = Digest::MD5.hexdigest("#{name}:#{description}:#{Time.utc.to_unix}")
  end
end
```

### With Associations

```crystal
class Post < Grant::Base
  belongs_to :category
  column title : String
  column category_id : Int64
  
  before_save :track_category_change
  
  private def track_category_change
    if category_id_changed?
      old_category = Category.find(category_id_was)
      new_category = Category.find(category_id)
      
      Log.info { "Post #{id} moved from #{old_category.name} to #{new_category.name}" }
    end
  end
end
```

## Best Practices

### 1. Use Specific Change Methods

```crystal
# Good: Specific and clear
if user.email_changed?
  send_verification_email
end

# Less clear: Generic check
if user.changed? && user.changed_attributes.includes?("email")
  send_verification_email
end
```

### 2. Leverage in Callbacks

```crystal
# Good: Use dirty tracking in callbacks
before_save :normalize_phone, if: :phone_changed?

# Avoid: Checking in the method
before_save :normalize_phone

private def normalize_phone
  return unless phone_changed?  # Redundant
  # ...
end
```

### 3. Handle Mutable Types Carefully

```crystal
# Good: Mark changes for mutable types
user.preferences_will_change!
user.preferences["theme"] = "dark"

# Or reassign
user.preferences = user.preferences.merge({"theme" => "dark"})
```

### 4. Clean Up After Bulk Operations

```crystal
# Good: Clear tracking after bulk operations
def bulk_process(users)
  users.each do |user|
    user.process_data
    user.save
    user.clear_changes_information  # Free memory
  end
end
```

## Troubleshooting

### Changes Not Detected

```crystal
# Problem: Direct mutation
user.tags << "new"
user.tags_changed?  # => false

# Solution: Mark as changed
user.tags_will_change!
user.tags << "new"
```

### Memory Usage

```crystal
# Problem: Large attributes in change tracking
class Document < Grant::Base
  column content : String  # Could be megabytes
end

# Solution: Selective tracking or cleanup
after_save :clear_content_changes

private def clear_content_changes
  @changed_attributes.delete("content") if @changed_attributes
end
```

### Unexpected Behavior with Nil

```crystal
# Setting nil is a change
user.phone = nil
user.phone_changed?  # => true
user.phone_was      # => "555-1234"
```

## Next Steps

- [Imports and Exports](imports-exports.md)
- [Normalization](normalization.md)
- [Callbacks and Lifecycle](../../core-features/callbacks-lifecycle.md)
- [Validations](../../core-features/validations.md)