# Advanced Query Interface Documentation

The Grant ORM provides a powerful and expressive query interface that allows you to build complex database queries with a fluent, chainable API.

## Table of Contents
- [Query Merging](#query-merging)
- [Advanced WHERE Methods](#advanced-where-methods)
- [Subqueries](#subqueries)
- [OR and NOT Conditions](#or-and-not-conditions)
- [Query Duplication](#query-duplication)
- [Complete Examples](#complete-examples)

## Query Merging

The `merge` method allows you to combine conditions from multiple queries into a single query. This is useful for building reusable query scopes.

### Basic Usage

```crystal
# Define reusable query scopes
active_users = User.where(active: true)
verified_users = User.where(email_verified: true)
admin_users = User.where(role: "admin")

# Merge queries together
active_admins = active_users.merge(admin_users)
# Produces: WHERE active = true AND role = 'admin'

active_verified_admins = active_users.merge(verified_users).merge(admin_users)
# Produces: WHERE active = true AND email_verified = true AND role = 'admin'
```

### Merging Rules

When merging queries:
- **WHERE conditions** are combined with AND
- **ORDER BY** from the merged query takes precedence
- **GROUP BY** fields are combined (duplicates removed)
- **LIMIT/OFFSET** from the merged query takes precedence if set
- **Associations** (includes, preload, eager_load) are combined

```crystal
query1 = User.where(active: true).order(name: :asc).limit(10)
query2 = User.where(role: "admin").order(created_at: :desc).limit(20)

merged = query1.merge(query2)
# WHERE: active = true AND role = 'admin'
# ORDER BY: created_at DESC (from query2)
# LIMIT: 20 (from query2)
```

## Advanced WHERE Methods

The query builder now provides a `WhereChain` that offers expressive methods for building complex conditions.

### Accessing WhereChain

Call `where` without arguments to access the WhereChain:

```crystal
User.where.not_in(:id, [1, 2, 3])
User.where.like(:email, "%@gmail.com")
```

### Available Methods

#### NOT IN
```crystal
# Find users not in the given list
User.where.not_in(:id, [5, 10, 15])
# SQL: WHERE id NOT IN (5, 10, 15)

# Can be chained
User.where(active: true).where.not_in(:role, ["guest", "suspended"])
```

#### LIKE / NOT LIKE
```crystal
# Pattern matching with LIKE
User.where.like(:email, "%@company.com")
# SQL: WHERE email LIKE '%@company.com'

# Exclude patterns with NOT LIKE
User.where.not_like(:email, "%spam%")
# SQL: WHERE email NOT LIKE '%spam%'

# Multiple patterns
User.where.like(:name, "John%").where.not_like(:email, "%test%")
```

#### Comparison Operators
```crystal
# Greater than
User.where.gt(:age, 18)
# SQL: WHERE age > 18

# Less than
User.where.lt(:age, 65)
# SQL: WHERE age < 65

# Greater than or equal
User.where.gteq(:created_at, 7.days.ago)
# SQL: WHERE created_at >= '2024-01-28 ...'

# Less than or equal  
User.where.lteq(:score, 100)
# SQL: WHERE score <= 100

# Chaining comparisons
User.where.gt(:age, 18).lt(:age, 65)
# SQL: WHERE age > 18 AND age < 65
```

#### NULL Checks
```crystal
# IS NULL
User.where.is_null(:deleted_at)
# SQL: WHERE deleted_at IS NULL

# IS NOT NULL
User.where.is_not_null(:email_confirmed_at)
# SQL: WHERE email_confirmed_at IS NOT NULL

# Combining NULL checks
User.where.is_null(:deleted_at).where.is_not_null(:activated_at)
```

#### BETWEEN
```crystal
# Inclusive range
User.where.between(:age, 25..35)
# SQL: WHERE age >= 25 AND age <= 35

# With dates
User.where.between(:created_at, 1.month.ago..Time.utc)
```

#### NOT (inequality)
```crystal
# Not equal to a value
User.where.not(:status, "banned")
# SQL: WHERE status != 'banned'
```

### Chaining WHERE Methods

All WHERE methods return the query builder, allowing for method chaining:

```crystal
User.where(active: true)
    .where.not_in(:id, blocked_ids)
    .where.like(:email, "%@company.com")
    .where.gteq(:age, 18)
    .where.is_null(:deleted_at)
    .order(created_at: :desc)
    .limit(10)
```

## Subqueries

Grant supports subqueries for IN conditions and EXISTS/NOT EXISTS checks.

### IN Subqueries

```crystal
# Find all posts by admin users
admin_user_ids = User.where(role: "admin").select(:id)
admin_posts = Post.where(user_id: admin_user_ids)
# SQL: WHERE user_id IN (SELECT id FROM users WHERE role = 'admin')

# Find orders for active products
active_product_ids = Product.where(active: true).select(:id)
Order.where(product_id: active_product_ids)
```

### EXISTS Subqueries

```crystal
# Find users who have posted
users_with_posts = User.where.exists(
  Post.where("posts.user_id = users.id")
)
# SQL: WHERE EXISTS (SELECT * FROM posts WHERE posts.user_id = users.id)

# Find users who have commented on their own posts
users_self_commented = User.where.exists(
  Comment.where("comments.user_id = users.id")
         .where("comments.post_id IN (SELECT id FROM posts WHERE posts.user_id = users.id)")
)
```

### NOT EXISTS Subqueries

```crystal
# Find users without any posts
users_without_posts = User.where.not_exists(
  Post.where("posts.user_id = users.id")
)
# SQL: WHERE NOT EXISTS (SELECT * FROM posts WHERE posts.user_id = users.id)

# Find products never ordered
unordered_products = Product.where.not_exists(
  Order.where("orders.product_id = products.id")
)
```

## OR and NOT Conditions

### OR Conditions

Use the `or` method with a block to group OR conditions:

```crystal
# Simple OR
User.where(role: "admin").or { |q| q.where(role: "moderator") }
# SQL: WHERE role = 'admin' OR (role = 'moderator')

# Complex OR groups
User.where(active: true)
    .or do |q|
      q.where(role: "admin")
      q.where.gteq(:level, 10)
    end
# SQL: WHERE active = true OR (role = 'admin' AND level >= 10)

# Multiple OR groups
User.where(verified: true)
    .or { |q| q.where(role: "admin") }
    .or { |q| q.where.gt(:reputation, 1000) }
# SQL: WHERE verified = true OR (role = 'admin') OR (reputation > 1000)
```

### NOT Conditions

Use the `not` method with a block to negate a group of conditions:

```crystal
# Simple NOT
User.not { |q| q.where(status: "banned") }
# SQL: WHERE NOT (status = 'banned')

# Complex NOT groups
User.not do |q|
  q.where(active: false)
  q.where.is_null(:email_confirmed_at)
end
# SQL: WHERE NOT (active = false AND email_confirmed_at IS NULL)

# Combining with other conditions
User.where(country: "US")
    .not { |q| q.where(status: "suspended") }
    .where.gteq(:age, 18)
# SQL: WHERE country = 'US' AND NOT (status = 'suspended') AND age >= 18
```

## Query Duplication

The `dup` method creates an independent copy of a query, useful for creating variations:

```crystal
# Create a base query
base_query = User.where(active: true).order(name: :asc)

# Create variations without modifying the original
admins = base_query.dup.where(role: "admin")
recent = base_query.dup.where.gteq(:created_at, 7.days.ago)
verified = base_query.dup.where.is_not_null(:email_confirmed_at)

# Original query remains unchanged
base_query.where_fields.size # => 1 (only active: true)
```

## Complete Examples

### Building a Search Query

```crystal
def search_users(params)
  query = User.where(active: true)
  
  # Add search term
  if term = params["search"]?
    query = query.where.like(:name, "%#{term}%")
                 .or { |q| q.where.like(:email, "%#{term}%") }
  end
  
  # Filter by role
  if role = params["role"]?
    query = query.where(role: role)
  end
  
  # Age range
  if min_age = params["min_age"]?
    query = query.where.gteq(:age, min_age.to_i)
  end
  
  if max_age = params["max_age"]?
    query = query.where.lteq(:age, max_age.to_i)
  end
  
  # Exclude suspended users
  query = query.where.not(:status, "suspended")
  
  # Only verified users
  if params["verified_only"]?
    query = query.where.is_not_null(:email_confirmed_at)
  end
  
  query.order(created_at: :desc).limit(20)
end
```

### Complex Business Logic

```crystal
# Find premium users eligible for rewards
# - Active and verified
# - Either: admin, or (subscriber with 6+ months tenure), or (high reputation)
# - Has made purchases
# - Not flagged for review

eligible_users = User
  .where(active: true)
  .where.is_not_null(:email_confirmed_at)
  .where.not(:flagged_for_review, true)
  .where.exists(Purchase.where("purchases.user_id = users.id"))
  .or do |q|
    q.where(role: "admin")
  end
  .or do |q|
    q.where(subscription_type: "premium")
     .where.lteq(:subscribed_at, 6.months.ago)
  end
  .or do |q|
    q.where.gt(:reputation_score, 1000)
  end
```

### Reusable Query Scopes

```crystal
module UserScopes
  def self.active
    User.where(active: true).where.is_null(:deleted_at)
  end
  
  def self.verified
    User.where.is_not_null(:email_confirmed_at)
        .where.is_not_null(:phone_confirmed_at)
  end
  
  def self.admins
    User.where(role: "admin")
  end
  
  def self.with_recent_activity
    User.where.exists(
      Activity.where("activities.user_id = users.id")
              .where.gteq(:created_at, 30.days.ago)
    )
  end
end

# Combine scopes
active_admins = UserScopes.active.merge(UserScopes.admins)
verified_active_users = UserScopes.active.merge(UserScopes.verified)
```

## Performance Considerations

1. **Subqueries**: Use `select(:id)` to fetch only IDs for IN subqueries
2. **Complex OR/NOT**: These create SQL with parentheses, which may affect query planner optimization
3. **Chaining**: Each where method adds an AND condition; be mindful of query complexity
4. **Indexes**: Ensure your database has appropriate indexes for fields used in WHERE conditions

## Migration from Basic Queries

Here's how to migrate from basic to advanced queries:

```crystal
# Before
users = User.all("role = ? AND age > ? AND email LIKE ?", ["admin", 18, "%@company.com"])

# After  
users = User.where(role: "admin")
            .where.gt(:age, 18)
            .where.like(:email, "%@company.com")
            .select

# Before - complex conditions with string interpolation
query = "active = true AND (role = 'admin' OR reputation > 1000) AND deleted_at IS NULL"
users = User.all(query)

# After - type-safe and expressive
users = User.where(active: true)
            .or { |q| q.where(role: "admin") }
            .or { |q| q.where.gt(:reputation, 1000) }
            .where.is_null(:deleted_at)
            .select
```