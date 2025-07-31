# Convenience Methods Documentation

Grant provides a comprehensive set of convenience methods that make working with data more efficient and expressive. These methods are inspired by Rails' ActiveRecord and provide similar functionality.

## Query Methods

### pluck

Extract one or more column values from records without instantiating full model objects.

```crystal
# Single column
names = User.where(active: true).pluck(:name)
# => [["John"], ["Jane"], ["Bob"]]

# Multiple columns
data = User.where(active: true).pluck(:id, :name, :email)
# => [[1, "John", "john@example.com"], [2, "Jane", "jane@example.com"]]

# With ordering
ordered_names = User.order(created_at: :desc).pluck(:name)

# With ranges
users_in_age_range = User.where(age: 25..35).pluck(:name)
```

### pick

Extract column values from the first record only. This is equivalent to `limit(1).pluck(...).first?`.

```crystal
# Get first user's data
first_user = User.pick(:id, :name)
# => [1, "John"]

# Returns nil if no records
User.where(age: 1000).pick(:name)
# => nil

# With conditions
admin = User.where(role: "admin").pick(:id, :name, :email)
```

## Batch Processing

### in_batches

Process large datasets in batches to avoid memory issues and improve performance.

```crystal
# Process users in batches of 1000 (default)
User.in_batches do |batch|
  batch.each do |user|
    user.update(last_processed_at: Time.utc)
  end
end

# Custom batch size
User.in_batches(of: 100) do |batch|
  # Process batch
end

# With start and finish constraints
User.in_batches(of: 500, start: 1000, finish: 5000) do |batch|
  # Only processes records with IDs between 1000 and 5000
end

# Process in descending order
User.in_batches(order: :desc) do |batch|
  # Processes from highest ID to lowest
end
```

## Bulk Operations

### insert_all

Efficiently insert multiple records in a single query.

```crystal
# Basic bulk insert
User.insert_all([
  {name: "John", email: "john@example.com", age: 25},
  {name: "Jane", email: "jane@example.com", age: 30},
  {name: "Bob", email: "bob@example.com", age: 35}
])

# With timestamps (default: true)
Article.insert_all(
  [{title: "First"}, {title: "Second"}],
  record_timestamps: true  # Automatically sets created_at and updated_at
)

# Skip timestamps
Product.insert_all(
  [{name: "Widget", price: 9.99}],
  record_timestamps: false
)

# With returning clause (database-specific)
users = User.insert_all(
  [{name: "Alice"}, {name: "Bob"}],
  returning: [:id, :name]
)
# => Returns array of User objects with id and name populated
```

### upsert_all

Insert records or update them if they already exist (based on unique constraints).

```crystal
# Basic upsert - updates on email conflict
User.upsert_all(
  [
    {name: "John Doe", email: "john@example.com", age: 26},
    {name: "Jane Smith", email: "jane@example.com", age: 31}
  ],
  unique_by: [:email]
)

# Update only specific columns on conflict
Product.upsert_all(
  [
    {sku: "WIDGET-1", name: "Widget", price: 19.99, stock: 100},
    {sku: "GADGET-1", name: "Gadget", price: 29.99, stock: 50}
  ],
  unique_by: [:sku],
  update_only: [:price, :stock]  # Only update price and stock, not name
)

# With timestamps
Article.upsert_all(
  [{slug: "hello-world", title: "Hello World", content: "..."}],
  unique_by: [:slug],
  record_timestamps: true  # Updates updated_at on conflict
)
```

## Query Annotations

Add SQL comments to queries for debugging and monitoring.

```crystal
# Add comment to query
users = User.where(active: true)
           .annotate("Dashboard#active_users")
           .select

# The generated SQL includes the comment:
# /* Dashboard#active_users */ SELECT * FROM users WHERE active = true

# Useful for:
# - Debugging slow queries in logs
# - Identifying query sources in monitoring tools
# - Adding context for database administrators
```

## Implementation Details

### Range Query Support

Range queries are automatically converted to appropriate SQL operators:

```crystal
# Inclusive range
User.where(age: 25..35)
# Generates: WHERE age >= 25 AND age <= 35

# Works with dates too
Post.where(created_at: 7.days.ago..Time.utc)
```

### Parameter Handling

All convenience methods properly handle parameter passing to prevent SQL injection:

- Query parameters are collected in assembler instances
- Bulk operations use parameterized queries
- Range values are properly escaped

### Database Compatibility

While the API is consistent across databases, some implementation details vary:

**PostgreSQL** (9.5+)
- Full support for RETURNING clause
- Native ON CONFLICT ... DO UPDATE

**MySQL** (5.6+)
- No RETURNING clause support
- Uses INSERT ... ON DUPLICATE KEY UPDATE

**SQLite** (3.24.0+)
- Required minimum version: 3.24.0 (enforced at runtime)
- Limited RETURNING support (SQLite 3.35+)
- Uses ON CONFLICT ... DO UPDATE syntax (proper upsert behavior)
- Requires unique indexes/constraints for upsert operations
- Version check performed on adapter initialization

**Important**: SQLite versions older than 3.24.0 are not supported. The library will raise an error on startup if an older version is detected. This ensures consistent upsert behavior across all supported databases.

### Performance Considerations

1. **pluck** is more efficient than loading full models when you only need specific columns
2. **in_batches** prevents memory exhaustion on large datasets
3. **insert_all/upsert_all** use single SQL statements for efficiency
4. Query annotations have negligible performance impact

## Error Handling

```crystal
begin
  User.insert_all(invalid_data)
rescue e : Granite::RecordNotSaved
  # Handle validation or constraint errors
end

begin
  User.upsert_all(data, unique_by: [:email])
rescue e : SQLite3::Exception
  # Handle database-specific errors (e.g., missing unique index)
end
```

## Best Practices

1. Use `pluck` when you only need column values, not full objects
2. Process large datasets with `in_batches` to avoid memory issues
3. Use `upsert_all` with explicit `unique_by` to ensure predictable behavior
4. Add query annotations in production apps for better monitoring
5. Test bulk operations with your specific database adapter
6. Create necessary indexes before using upsert operations

## Migration from ActiveRecord

If you're coming from Rails, here's a quick mapping:

| ActiveRecord | Grant |
|-------------|-------|
| `pluck(:name)` | `pluck(:name)` |
| `pick(:id, :name)` | `pick(:id, :name)` |
| `find_in_batches` | `in_batches` |
| `insert_all` | `insert_all` |
| `upsert_all` | `upsert_all` |
| `annotate("comment")` | `annotate("comment")` |

The API is designed to be familiar to Rails developers while taking advantage of Crystal's type safety and performance.