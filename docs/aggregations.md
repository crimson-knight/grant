# Aggregation Methods

Grant provides a comprehensive set of aggregation methods for performing calculations on your data. These methods are available both at the model level and through query builders.

## Available Methods

### Count

Count the number of records:

```crystal
# Count all users
total_users = User.count  # => 42

# Count with conditions
active_users = User.where(active: true).count  # => 35

# Count distinct values
unique_emails = User.distinct.count(:email)  # => 40
```

### Sum

Calculate the sum of a numeric column:

```crystal
# Sum all order totals
total_revenue = Order.sum(:total)  # => 15234.50

# Sum with conditions
monthly_revenue = Order.where("created_at > ?", 1.month.ago).sum(:total)

# Sum returns 0.0 for empty results
no_orders = Order.where(id: -1).sum(:total)  # => 0.0
```

### Average

Calculate the average of a numeric column:

```crystal
# Average order value
avg_order_value = Order.avg(:total)  # => 125.50

# Average with conditions
avg_premium_order = Order.where("total > ?", 100).avg(:total)  # => 250.75

# Average returns nil for empty results
no_avg = Order.where(id: -1).avg(:total)  # => nil
```

### Minimum

Find the minimum value of a column:

```crystal
# Minimum price
lowest_price = Product.min(:price)  # => 9.99

# Minimum with conditions
lowest_sale_price = Product.where(on_sale: true).min(:price)  # => 4.99

# Works with dates/times
first_order_date = Order.min(:created_at)
```

### Maximum

Find the maximum value of a column:

```crystal
# Maximum price
highest_price = Product.max(:price)  # => 999.99

# Maximum with conditions
highest_premium = Product.where(category: "premium").max(:price)

# Works with dates/times
latest_login = User.max(:last_login_at)
```

### Pluck

Extract values from a specific column as an array:

```crystal
# Get all email addresses
emails = User.pluck(:email)  
# => ["user1@example.com", "user2@example.com", ...]

# Pluck with conditions and ordering
recent_titles = Post.where(published: true)
                    .order(created_at: :desc)
                    .limit(10)
                    .pluck(:title)

# Pluck numeric values
prices = Product.pluck(:price)  # => [9.99, 19.99, 29.99, ...]
```

### Pick

Extract the first value from a specific column:

```crystal
# Get the first email
first_email = User.pick(:email)  # => "user1@example.com"

# Pick with ordering
newest_title = Post.order(created_at: :desc).pick(:title)

# Pick returns nil if no records
no_pick = User.where(id: -1).pick(:email)  # => nil
```

### Last

Get the last record:

```crystal
# Get the last user (ordered by primary key)
last_user = User.last

# Get the last with conditions
last_active = User.where(active: true).last

# Raises if not found
last_user = User.last!  # Raises Granite::Querying::NotFound if table is empty
```

## Query Builder Integration

All aggregation methods work seamlessly with Grant's query builder:

```crystal
# Complex aggregations
result = Order.joins(:items)
              .where(status: "completed")
              .where("orders.created_at > ?", 1.year.ago)
              .group(:user_id)
              .sum("items.quantity * items.price")

# Multiple aggregations
stats = {
  total: Order.count,
  revenue: Order.sum(:total),
  average: Order.avg(:total),
  highest: Order.max(:total),
  lowest: Order.min(:total)
}
```

## Type Safety

Aggregation methods return appropriate types:

- `count` → `Int64`
- `sum` → `Float64`
- `avg` → `Float64?` (nil if no records)
- `min` → `Granite::Columns::Type` (polymorphic)
- `max` → `Granite::Columns::Type` (polymorphic)
- `pluck` → `Array(Granite::Columns::Type)`
- `pick` → `Granite::Columns::Type?`
- `last` → `Model?`
- `last!` → `Model` (raises if not found)

## Performance Considerations

### Database-Level Calculations

All aggregation methods perform calculations at the database level, making them highly efficient:

```crystal
# Efficient: Database calculates the sum
total = Order.sum(:amount)  # Single query: SELECT SUM(amount) FROM orders

# Inefficient: Loading all records into memory
total = Order.all.map(&.amount).sum  # Loads all records!
```

### Indexing

For optimal performance, ensure columns used in aggregations are properly indexed:

```sql
-- Index for frequent sum/avg operations
CREATE INDEX idx_orders_total ON orders(total);

-- Index for min/max operations
CREATE INDEX idx_products_price ON products(price);

-- Composite index for conditional aggregations
CREATE INDEX idx_orders_status_created ON orders(status, created_at);
```

### Caching Aggregations

For frequently accessed aggregations, consider caching:

```crystal
class Product < Granite::Base
  # Cache average rating
  column average_rating : Float64?
  
  def update_average_rating!
    self.average_rating = reviews.avg(:rating)
    save!
  end
end
```

## Advanced Usage

### Grouping with Aggregations

Combine GROUP BY with aggregations:

```crystal
# Sales by category
sales_by_category = Product.joins(:orders)
                           .group(:category)
                           .sum("order_items.quantity * order_items.price")

# Count by status
orders_by_status = Order.group(:status).count
```

### Having Clauses

Filter grouped results:

```crystal
# Users with more than 10 orders
power_users = User.joins(:orders)
                  .group("users.id")
                  .having("COUNT(orders.id) > ?", 10)
                  .pluck(:email)
```

### Multiple Columns

Some databases support multi-column operations:

```crystal
# Pluck multiple columns (returns array of arrays)
user_data = User.select("id, email, created_at").pluck
# Note: Grant currently supports single column pluck
```

## Database-Specific Behavior

### PostgreSQL

- Supports advanced aggregations like `array_agg`, `string_agg`
- Window functions for running totals
- Statistical aggregates (`stddev`, `variance`)

### MySQL

- Supports `GROUP_CONCAT` for string aggregation
- Different NULL handling in some aggregates
- Limited window function support (MySQL 8.0+)

### SQLite

- Basic aggregation support
- Limited precision for floating-point calculations
- No advanced statistical functions

## Common Patterns

### Dashboard Statistics

```crystal
def dashboard_stats
  {
    total_users: User.count,
    active_users: User.where(active: true).count,
    total_revenue: Order.where(status: "completed").sum(:total),
    average_order: Order.avg(:total),
    top_product_price: Product.max(:price),
    latest_signup: User.max(:created_at)
  }
end
```

### Report Generation

```crystal
def monthly_report(date)
  start_date = date.at_beginning_of_month
  end_date = date.at_end_of_month
  
  Order.where(created_at: start_date..end_date)
       .group("DATE(created_at)")
       .sum(:total)
end
```

### Data Validation

```crystal
# Ensure no duplicate emails
if User.distinct.count(:email) < User.count
  puts "Duplicate emails found!"
end

# Check for negative prices
if Product.min(:price) < 0
  puts "Invalid negative prices detected!"
end
```

## Best Practices

1. **Use Database Aggregations**: Always prefer database-level calculations over loading records into memory

2. **Index Aggregated Columns**: Ensure frequently aggregated columns have appropriate indexes

3. **Cache When Appropriate**: Cache expensive aggregations that don't change frequently

4. **Handle NULL Values**: Be aware that `avg`, `min`, `max` may return nil for empty sets

5. **Consider Precision**: Use appropriate numeric types for financial calculations

## Integration with Async

All aggregation methods have async counterparts:

```crystal
# Async aggregations
count_result = User.async_count
sum_result = Order.async_sum(:total)
avg_result = Product.async_avg(:price)

# Wait for results
total_users = count_result.await
total_revenue = sum_result.await
average_price = avg_result.await

# Concurrent aggregations
coordinator = Granite::Async::Coordinator.new
coordinator.add(User.async_count)
coordinator.add(Order.async_sum(:total))
coordinator.add(Product.async_avg(:price))

results = coordinator.await_all
```