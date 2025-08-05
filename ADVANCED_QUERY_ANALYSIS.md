# Advanced Query Interface Analysis

## Current Capabilities

### Already Implemented:
1. **Basic WHERE conditions**
   - `where(field: value)` - equality
   - `where(field: [array])` - IN operator
   - `where(field: range)` - BETWEEN (using >= and <=)
   - `where(field, :operator, value)` - custom operators

2. **OR conditions** ✅
   - `or(field: value)` - simple OR
   - `or { block }` - complex grouped OR conditions

3. **NOT conditions** ✅
   - `not { block }` - NOT grouped conditions

4. **Operators supported**:
   - `:eq` (=), `:neq` (!=), `:ltgt` (<>)
   - `:gt` (>), `:lt` (<), `:gteq` (>=), `:lteq` (<=)
   - `:ngt` (!>), `:nlt` (!<)
   - `:in` (IN), `:nin` (NOT IN)
   - `:like` (LIKE), `:nlike` (NOT LIKE)

5. **Other features**:
   - Order by with direction
   - Group by
   - Limit/Offset
   - Eager loading (includes, preload, eager_load)
   - Locking support
   - Raw SQL where clauses

## Missing Features for Issue #15

### 1. Query Merging ❌
Need to implement:
```crystal
query1 = User.where(active: true)
query2 = User.where(role: "admin")
combined = query1.merge(query2)
# Should produce: WHERE active = true AND role = 'admin'
```

### 2. Subqueries ❌
Need to implement:
```crystal
# IN subquery
admin_ids = User.where(role: "admin").select(:id)
Post.where(user_id: admin_ids)

# EXISTS subquery
User.where.exists(Post.where(user_id: :id))

# NOT EXISTS
User.where.not_exists(Order.where(user_id: :id))
```

### 3. Common Table Expressions (CTEs) ❌
Need to implement:
```crystal
User.with(
  admins: User.where(role: "admin"),
  recent: User.where("created_at > ?", 1.week.ago)
).from("admins").join("recent ON admins.id = recent.id")
```

### 4. Advanced WHERE methods ❌
While operators exist, need convenience methods:
```crystal
# NOT IN convenience
User.where.not_in(:id, [1, 2, 3])

# LIKE convenience  
User.where.like(:email, "%@gmail.com")

# NOT LIKE convenience
User.where.not_like(:email, "%spam%")

# IS NULL / IS NOT NULL
User.where.is_null(:deleted_at)
User.where.is_not_null(:confirmed_at)

# Chained where methods
User.where.gt(:age, 18).lt(:age, 65)
```

### 5. Association-based queries ❌
```crystal
# Has associated records
User.where.has(:posts)

# Doesn't have associated records  
User.where.missing(:orders)

# Join and query on association
User.joins(:posts).where(posts: {published: true})
```

## Implementation Priority

1. **High Priority**:
   - Query merging (fundamental for composability)
   - Subquery support (IN, EXISTS)
   - Advanced WHERE convenience methods

2. **Medium Priority**:
   - CTEs (complex but powerful)
   - Association-based queries

3. **Nice to have**:
   - UNION support
   - Window functions
   - Full text search helpers