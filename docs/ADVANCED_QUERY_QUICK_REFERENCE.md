# Advanced Query Interface - Quick Reference

## WhereChain Methods

Access via `.where` (without arguments):

| Method | Description | Example |
|--------|-------------|---------|
| `not_in(field, array)` | NOT IN condition | `User.where.not_in(:id, [1,2,3])` |
| `like(field, pattern)` | LIKE pattern match | `User.where.like(:email, "%@gmail%")` |
| `not_like(field, pattern)` | NOT LIKE pattern | `User.where.not_like(:name, "%test%")` |
| `gt(field, value)` | Greater than | `User.where.gt(:age, 18)` |
| `lt(field, value)` | Less than | `User.where.lt(:score, 100)` |
| `gteq(field, value)` | Greater or equal | `User.where.gteq(:created_at, 1.day.ago)` |
| `lteq(field, value)` | Less or equal | `User.where.lteq(:price, 99.99)` |
| `not(field, value)` | Not equal | `User.where.not(:status, "banned")` |
| `between(field, range)` | BETWEEN range | `User.where.between(:age, 25..35)` |
| `is_null(field)` | IS NULL | `User.where.is_null(:deleted_at)` |
| `is_not_null(field)` | IS NOT NULL | `User.where.is_not_null(:email)` |
| `exists(subquery)` | EXISTS subquery | `User.where.exists(Post.where(...))` |
| `not_exists(subquery)` | NOT EXISTS | `User.where.not_exists(Order.where(...))` |

## Query Builder Methods

| Method | Description | Example |
|--------|-------------|---------|
| `merge(other_query)` | Combine queries | `active.merge(verified)` |
| `dup()` | Copy query | `base_query.dup.where(...)` |
| `or { }` | OR group | `query.or { \|q\| q.where(...) }` |
| `not { }` | NOT group | `query.not { \|q\| q.where(...) }` |

## Collection & Enumerable Methods

`Query::Builder` includes `Enumerable(Model)`, so standard collection methods work directly on query chains.

### SQL-Optimized (No Block)

| Method | Returns | Description | Example |
|--------|---------|-------------|---------|
| `count` / `size` | `Int64` | SQL COUNT | `User.where(active: true).count` |
| `any?` | `Bool` | Checks via LIMIT 1 | `User.where(role: "admin").any?` |
| `select` | `Array(Model)` | Executes SQL query | `User.where(active: true).select` |
| `to_a` | `Array(Model)` | Materializes results | `User.where(active: true).to_a` |

### In-Memory (With Block)

| Method | Returns | Description | Example |
|--------|---------|-------------|---------|
| `each { }` | `Nil` | Iterate records | `User.where(active: true).each { \|u\| puts u.name }` |
| `map { }` | `Array(T)` | Transform records | `User.where(active: true).map { \|u\| u.name }` |
| `select { }` | `Array(Model)` | Filter in memory | `User.where(active: true).select { \|u\| u.admin? }` |
| `reject { }` | `Array(Model)` | Inverse filter | `User.where(active: true).reject { \|u\| u.banned? }` |
| `count { }` | `Int32` | Count with condition | `User.where(active: true).count { \|u\| u.admin? }` |
| `any? { }` | `Bool` | Any match block? | `User.where(active: true).any? { \|u\| u.admin? }` |
| `none? { }` | `Bool` | None match block? | `User.where(active: true).none? { \|u\| u.banned? }` |
| `all? { }` | `Bool` | All match block? | `User.where(active: true).all? { \|u\| u.age > 0 }` |
| `min_by { }` | `Model?` | Minimum by criteria | `User.where(active: true).min_by { \|u\| u.created_at }` |
| `max_by { }` | `Model?` | Maximum by criteria | `User.where(active: true).max_by { \|u\| u.created_at }` |
| `sum { }` | `T` | Sum computed values | `Order.where(status: "paid").sum { \|o\| o.total }` |
| `partition { }` | `Tuple(Array, Array)` | Split into two | `users.partition { \|u\| u.admin? }` |
| `reduce { }` | `T` | Accumulate result | `orders.reduce(0.0) { \|sum, o\| sum + o.total }` |
| `compact_map { }` | `Array(T)` | Map, remove nils | `users.compact_map { \|u\| u.email }` |
| `flat_map { }` | `Array(T)` | Map and flatten | `posts.flat_map { \|p\| p.tags }` |
| `tally_by { }` | `Hash(T, Int32)` | Count by key | `users.tally_by { \|u\| u.role }` |
| `each_with_object { }` | `T` | Iterate with object | `users.each_with_object({} of Int64 => String) { \|u, h\| h[u.id] = u.name }` |

> **Tip:** No `.all` needed before these methods — they work directly on `Query::Builder`.

## Common Patterns

### Search with Multiple Fields
```crystal
User.where.like(:name, "%#{term}%")
    .or { |q| q.where.like(:email, "%#{term}%") }
    .or { |q| q.where.like(:username, "%#{term}%") }
```

### Date Range Queries
```crystal
Post.where.gteq(:created_at, start_date)
    .where.lteq(:created_at, end_date)
# OR
Post.where.between(:created_at, start_date..end_date)
```

### Excluding Records
```crystal
User.where.not_in(:status, ["banned", "suspended"])
    .where.is_null(:deleted_at)
```

### Complex Business Rules
```crystal
Product.where(active: true)
       .where.gt(:stock, 0)
       .where.lteq(:price, budget)
       .where.not_exists(
         Order.where("orders.product_id = products.id")
              .where(status: "returned")
       )
```

### Subquery for Latest Records
```crystal
latest_post_ids = Post.where(user_id: user.id)
                      .order(created_at: :desc)
                      .limit(5)
                      .select(:id)

Comment.where(post_id: latest_post_ids)
```

## Operators Reference

### Comparison Operators
- `:eq` - Equal (=)
- `:neq` - Not equal (!=)
- `:gt` - Greater than (>)
- `:lt` - Less than (<)
- `:gteq` - Greater or equal (>=)
- `:lteq` - Less or equal (<=)

### List Operators
- `:in` - IN
- `:nin` - NOT IN

### Pattern Operators
- `:like` - LIKE
- `:nlike` - NOT LIKE

### Null Operators
- Use `is_null()` and `is_not_null()` methods

## Tips

1. **Chain conditions** - All methods return the query builder
   ```crystal
   User.where.gt(:age, 18).lt(:age, 65).not(:status, "inactive")
   ```

2. **Combine approaches** - Mix regular where with WhereChain
   ```crystal
   User.where(country: "US").where.like(:email, "%@company.com")
   ```

3. **Use merge for DRY code**
   ```crystal
   active = User.where(active: true)
   verified = User.where(verified: true)
   active_verified = active.merge(verified)
   ```

4. **Parentheses with OR/NOT** - These create grouped conditions
   ```crystal
   # Produces: WHERE active = true AND (role = 'admin' OR level > 10)
   User.where(active: true).or { |q| 
     q.where(role: "admin").where.gt(:level, 10)
   }
   ```