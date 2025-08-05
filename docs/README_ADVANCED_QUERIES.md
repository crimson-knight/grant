# Advanced Query Interface

Grant provides a powerful and expressive query interface that goes beyond basic ActiveRecord-style queries. This advanced interface allows you to build complex database queries with type safety and a fluent API.

## Getting Started

The advanced query interface is accessed through the standard query builder methods on your models:

```crystal
# Basic query
users = User.where(active: true).select

# Advanced query with WhereChain
users = User.where(active: true)
            .where.like(:email, "%@company.com")
            .where.gt(:age, 18)
            .select
```

## Key Features

### 1. WhereChain Methods
Access advanced WHERE conditions by calling `where` without arguments:

- `not_in` - Exclude values from a list
- `like` / `not_like` - Pattern matching
- `gt`, `lt`, `gteq`, `lteq` - Comparison operators
- `between` - Range queries
- `is_null` / `is_not_null` - NULL checks
- `exists` / `not_exists` - Subquery conditions

### 2. Query Merging
Combine multiple queries into one:

```crystal
active_users = User.where(active: true)
verified_users = User.where(email_verified: true)
combined = active_users.merge(verified_users)
```

### 3. OR and NOT Groups
Build complex boolean logic:

```crystal
# OR conditions
User.where(verified: true)
    .or { |q| q.where(role: "admin") }

# NOT conditions  
User.not { |q| q.where(status: "banned") }
```

### 4. Subqueries
Use queries as values for IN conditions:

```crystal
admin_ids = User.where(role: "admin").select(:id)
admin_posts = Post.where(user_id: admin_ids)
```

## Documentation

- [Full Documentation](./ADVANCED_QUERY_INTERFACE.md) - Comprehensive guide with all features
- [Quick Reference](./ADVANCED_QUERY_QUICK_REFERENCE.md) - Cheat sheet for common patterns
- [Examples](../examples/advanced_query_examples.cr) - Real-world usage examples

## Benefits

1. **Type Safety** - All queries are checked at compile time
2. **Readability** - Express complex queries in readable Crystal code
3. **Composability** - Build queries incrementally and reuse components
4. **Performance** - Generates efficient SQL without N+1 queries
5. **Maintainability** - Easier to understand and modify than raw SQL

## When to Use

Use the advanced query interface when you need:
- Complex WHERE conditions with multiple operators
- Queries that combine OR/NOT logic
- Subqueries for filtering data
- Reusable query components
- Dynamic query building based on parameters

## Examples

### Search Implementation
```crystal
def search_users(term : String?, filters = {} of String => String)
  query = User.where(active: true)
  
  if term
    query = query.where.like(:name, "%#{term}%")
                 .or { |q| q.where.like(:email, "%#{term}%") }
  end
  
  if role = filters["role"]?
    query = query.where(role: role)
  end
  
  query.where.is_null(:deleted_at)
       .order(created_at: :desc)
       .select
end
```

### Complex Business Logic
```crystal
# Find users eligible for premium features
eligible_users = User
  .where(active: true)
  .where.is_not_null(:email_verified_at)
  .where.exists(
    Subscription.where("subscriptions.user_id = users.id")
                .where(status: "active")
  )
  .or { |q| q.where(role: "admin") }
  .where.not(:country, "restricted")
  .select
```

## Next Steps

1. Review the [full documentation](./ADVANCED_QUERY_INTERFACE.md)
2. Check out the [examples](../examples/advanced_query_examples.cr)
3. Try building queries in your application
4. Refer to the [quick reference](./ADVANCED_QUERY_QUICK_REFERENCE.md) as needed