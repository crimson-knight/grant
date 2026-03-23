---
name: grant-callbacks-and-transactions
description: Grant ORM lifecycle callbacks, transaction blocks, nested transactions with savepoints, isolation levels, optimistic and pessimistic locking.
user-invocable: false
---

# Grant Callbacks and Transactions

## Callback Overview

Callbacks are methods that run at specific points in a model's lifecycle. They allow you to trigger logic before or after alterations to a model's state.

## Available Callbacks

### Create Lifecycle

```
before_validation -> validations -> after_validation ->
before_save -> before_create -> INSERT -> after_create -> after_save ->
after_commit
```

### Update Lifecycle

```
before_validation -> validations -> after_validation ->
before_save -> before_update -> UPDATE -> after_update -> after_save ->
after_commit
```

### Destroy Lifecycle

```
before_destroy -> DELETE -> after_destroy -> after_commit
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

### Multiple Callbacks

Callbacks run in the order they are registered:

```crystal
before_save :normalize_email
before_save :hash_password
before_save :set_defaults
```

### Conditional Callbacks

```crystal
before_save :update_slug, if: :title_changed?
after_create :notify_subscribers, if: :published?

before_destroy :archive_content,
  if: ->(post : Post) { post.views > 1000 }

after_save :clear_cache, if: :published?, unless: :draft?
```

## Halting Execution

### Throwing :abort (Recommended)

```crystal
class Order < Grant::Base
  before_save :check_inventory

  private def check_inventory
    if total_items > available_stock
      errors.add(:items, "Insufficient inventory")
      throw :abort  # Halts the callback chain, prevents save
    end
  end
end
```

### Returning false (Legacy)

```crystal
private def validate_publishing
  if publishing? && !ready_to_publish?
    errors.add(:base, "Post not ready to publish")
    false  # Halts the callback chain
  else
    true
  end
end
```

## Transaction Callbacks

### after_commit

Runs after the database transaction has successfully committed. Safe for external side effects:

```crystal
after_commit :send_confirmation, on: :create
after_commit :update_inventory, on: :update

private def send_confirmation
  OrderMailer.confirmation(self).deliver_later  # Safe -- transaction committed
end
```

### after_rollback

Runs if the database transaction is rolled back:

```crystal
after_rollback :log_failure

private def log_failure
  PaymentFailureNotifier.notify(self)
end
```

## Skipping Callbacks

```crystal
post.save(skip_callbacks: true)
User.update_all(active: false)        # No callbacks (bulk operation)
user.update_columns(name: "Direct")   # Direct SQL, no callbacks
```

## Common Callback Patterns

### Data Normalization

```crystal
before_validation :normalize_fields

private def normalize_fields
  self.email = email.downcase.strip
  self.phone = phone.try(&.gsub(/\D/, ""))
  self.name = name.split.map(&.capitalize).join(" ")
end
```

### Slug Generation

```crystal
before_save :generate_slug

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
```

### Audit Trail

```crystal
after_create :log_create
after_update :log_update
after_destroy :log_destroy

private def log_create
  AuditLog.create(model: self.class.name, record_id: id, action: "create")
end
```

---

# Transactions

## Basic Transactions

Wrap multiple operations so they all succeed or all fail:

```crystal
User.transaction do
  user = User.create!(name: "Alice", email: "alice@example.com")
  Profile.create!(user_id: user.id, bio: "Developer")
end
```

Automatic rollback on any exception:

```crystal
User.transaction do
  user.save!
  account.save!
  raise "Something went wrong!"  # Entire transaction rolls back
end
```

### Manual Rollback

```crystal
Grant::Base.transaction do
  user = User.create!(name: "Jane")
  if user.email.blank?
    raise Grant::Rollback.new  # Rolls back without propagating exception
  end
end
```

## Nested Transactions (Savepoints)

```crystal
User.transaction do
  user.save!

  # Nested transaction uses a savepoint
  User.transaction do
    audit_log.save!
    raise Grant::Transaction::Rollback.new  # Only rolls back nested
  end

  # user.save! is still committed
end
```

### True Nested Transactions

```crystal
User.transaction do
  outer_record.save!

  User.transaction(requires_new: true) do
    independent_record.save!  # Separate transaction
  end

  raise "Error!"  # Only outer rolls back
end
```

## Isolation Levels

```crystal
User.transaction(isolation: :serializable) do
  critical_operation
end
```

Available levels:
- `:read_uncommitted` -- Lowest isolation, highest performance
- `:read_committed` -- Default for most databases
- `:repeatable_read` -- Prevents non-repeatable reads
- `:serializable` -- Highest isolation, prevents all anomalies

### Read-Only Transactions

```crystal
User.transaction(readonly: true) do
  users = User.all
  analytics = calculate_statistics(users)
end
```

---

# Locking

## Pessimistic Locking

Prevents other transactions from accessing locked records.

### Lock Modes

```crystal
# Basic exclusive lock (FOR UPDATE)
user = User.where(id: 1).lock.first!

# Shared lock (FOR SHARE)
user = User.where(id: 1).lock(Grant::Locking::LockMode::Share).first!

# Non-waiting lock (fails immediately if locked)
user = User.where(id: 1).lock(Grant::Locking::LockMode::UpdateNoWait).first!

# Skip locked rows
users = User.where(active: true).lock(Grant::Locking::LockMode::UpdateSkipLocked).to_a
```

Available modes: `Update`, `Share`, `UpdateNoWait`, `UpdateSkipLocked`, `ShareNoWait`, `ShareSkipLocked`

### Block-Based Locking

```crystal
# Lock by ID (wraps in transaction automatically)
User.with_lock(user_id) do |user|
  user.balance -= 100
  user.save!
end

# Instance method
user.with_lock do |locked_user|
  locked_user.process_payment(amount)
end
```

## Optimistic Locking

Uses a `lock_version` column to detect concurrent modifications:

### Setup

```crystal
class Product < Grant::Base
  include Grant::Locking::Optimistic

  column id : Int64, primary: true
  column name : String
  column price : Float64
  # lock_version column is automatically added
end
```

### Handling Conflicts

```crystal
user1_product = Product.find!(1)
user2_product = Product.find!(1)

user1_product.price = 99.99
user1_product.save!  # Succeeds, lock_version incremented

user2_product.price = 89.99
begin
  user2_product.save!  # Fails -- stale lock_version
rescue ex : Grant::Locking::Optimistic::StaleObjectError
  user2_product.reload
  # Retry the operation
end
```

### Automatic Retries

```crystal
product.with_optimistic_retry(max_retries: 3) do
  product.stock -= quantity
  product.save!
end
```

## Database Support

| Feature | PostgreSQL | MySQL | SQLite |
|---------|-----------|-------|--------|
| All lock modes | Yes | Basic (Update, Share, NoWait, SkipLocked) | No row-level locking |
| All isolation levels | Yes | Yes | Limited |
| Savepoints | Yes | Yes | Yes |
| Optimistic locking | Yes | Yes | Yes |

### Check Adapter Capabilities

```crystal
User.adapter.supports_lock_mode?(Grant::Locking::LockMode::UpdateSkipLocked)
User.adapter.supports_isolation_level?(Grant::Transaction::IsolationLevel::Serializable)
User.adapter.supports_savepoints?
```
