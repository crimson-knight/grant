# Advanced Association Options

Grant now supports a comprehensive set of advanced association options that provide greater control over how associations behave. These options bring Grant closer to feature parity with Rails ActiveRecord.

## Dependent Options

The `dependent` option controls what happens to associated records when the parent record is destroyed.

### dependent: :destroy

Destroys all associated records when the parent is destroyed.

```crystal
class Author < Granite::Base
  has_many :posts, dependent: :destroy
  has_one :profile, dependent: :destroy
end

# When author is destroyed, all posts and profile are also destroyed
author.destroy! # => Also destroys all associated posts and profile
```

### dependent: :nullify

Sets the foreign key to NULL on all associated records when the parent is destroyed.

```crystal
class Category < Granite::Base
  has_many :articles, dependent: :nullify
end

# When category is destroyed, all articles have their category_id set to NULL
category.destroy! # => Sets category_id = NULL on all articles
```

### dependent: :restrict

Prevents deletion of the parent record if any associated records exist.

```crystal
class Team < Granite::Base
  has_many :members, dependent: :restrict
end

# Raises error if trying to destroy team with members
team.destroy! # => Raises Granite::RecordNotDestroyed if members exist
```

## Optional Associations

By default, `belongs_to` associations are required (the foreign key cannot be NULL). Use `optional: true` to allow NULL foreign keys.

```crystal
class Product < Granite::Base
  # Required by default - validates presence of category_id
  belongs_to :category
  
  # Optional - allows product without manufacturer
  belongs_to :manufacturer, optional: true
end

# This will fail validation
product = Product.new(name: "Widget")
product.valid? # => false
product.errors.first.message # => "category must exist"

# This will pass validation
product = Product.new(name: "Widget", manufacturer_id: nil)
product.valid? # => true (if category is set)
```

## Counter Cache

Counter cache maintains a count of associated records on the parent model, avoiding expensive COUNT queries.

```crystal
class Blog < Granite::Base
  column posts_count : Int32
  has_many :posts
end

class Post < Granite::Base
  # Updates blogs.posts_count automatically
  belongs_to :blog, counter_cache: true
end

# Or with a custom column name
class Comment < Granite::Base
  belongs_to :article, counter_cache: :comments_total
end
```

The counter cache:
- Increments when a record is created
- Decrements when a record is destroyed
- Updates when the association changes

```crystal
blog = Blog.create!(title: "My Blog", posts_count: 0)
post = Post.create!(title: "First Post", blog: blog)
blog.reload.posts_count # => 1

post.destroy!
blog.reload.posts_count # => 0
```

## Touch

The `touch` option updates the parent record's `updated_at` timestamp whenever the child record is saved or destroyed.

```crystal
class Profile < Granite::Base
  belongs_to :user, touch: true
end

# Updates user.updated_at whenever profile is saved
profile.update!(bio: "New bio") # => Also touches user.updated_at

# Touch a specific column instead
class Comment < Granite::Base
  belongs_to :post, touch: :last_commented_at
end
```

## Autosave

The `autosave` option automatically saves associated records when the parent is saved.

```crystal
class Order < Granite::Base
  has_many :line_items, autosave: true
  has_one :invoice, autosave: true
  belongs_to :customer, autosave: true
end

order = Order.new
order.line_items << LineItem.new(product: "Widget", quantity: 2)
order.invoice = Invoice.new(total: 100)
order.customer = Customer.new(name: "John Doe")

# Saves order and all associated records in one call
order.save! # => Also saves line_items, invoice, and customer
```

## Combining Options

You can combine multiple options on a single association:

```crystal
class Article < Granite::Base
  # Posts count is maintained, destroyed with article, touches article on changes
  has_many :comments, 
    dependent: :destroy,
    counter_cache: true,
    autosave: true
    
  belongs_to :author,
    optional: true,
    touch: :last_activity_at,
    counter_cache: :articles_count
end
```

## Implementation Details

### Callbacks

Most association options are implemented using Grant's callback system:
- `dependent` options use `before_destroy` or `after_destroy` callbacks
- `counter_cache` uses `after_create`, `after_destroy`, and `before_update` callbacks
- `touch` uses `after_save` and `after_destroy` callbacks
- `autosave` uses `before_save` callbacks

### Performance Considerations

1. **Counter Cache**: Trades write performance for read performance. Updates are slightly slower but counts are instant.

2. **Dependent Destroy**: Can be slow for large associations. Consider using database cascades for better performance.

3. **Touch**: Adds an extra UPDATE query. Be cautious with deeply nested touch chains.

4. **Autosave**: Can create multiple database queries. Consider using transactions for consistency.

## Best Practices

1. **Use dependent: :restrict for safety**: This prevents accidental data loss and ensures referential integrity.

2. **Always add indexes**: Add database indexes for foreign keys used in dependent operations:
   ```sql
   CREATE INDEX idx_posts_author_id ON posts(author_id);
   ```

3. **Consider database constraints**: For critical data, combine Grant options with database constraints:
   ```sql
   ALTER TABLE posts 
   ADD CONSTRAINT fk_posts_author 
   FOREIGN KEY (author_id) 
   REFERENCES authors(id) 
   ON DELETE CASCADE;
   ```

4. **Be explicit with optional**: Always specify `optional: true` when NULL foreign keys are intended.

5. **Monitor counter caches**: Periodically verify counter accuracy and provide admin tools to recalculate if needed:
   ```crystal
   Blog.all.each do |blog|
     blog.update!(posts_count: blog.posts.count)
   end
   ```

## Migration Helpers

When using these features, ensure your database schema supports them:

```crystal
# For counter cache
add_column :blogs, :posts_count, :integer, default: 0
add_index :posts, :blog_id

# For touch with custom column
add_column :posts, :last_commented_at, :timestamp

# For dependent operations
add_index :comments, :post_id
add_index :comments, [:commentable_type, :commentable_id] # For polymorphic
```

## Troubleshooting

### Counter Cache Out of Sync

If counter caches become inaccurate:

```crystal
class Blog < Granite::Base
  def reset_posts_count!
    update!(posts_count: posts.count)
  end
end
```

### Dependent Destroy Too Slow

For large associations, consider:
1. Using `dependent: :delete_all` (when implemented)
2. Database-level CASCADE
3. Background job processing

### Circular Dependencies

Be careful with bidirectional autosave:

```crystal
# This can cause infinite loops
class User < Granite::Base
  has_one :profile, autosave: true
end

class Profile < Granite::Base
  belongs_to :user, autosave: true
end
```