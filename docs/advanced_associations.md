# Advanced Association Options

Grant now supports a comprehensive set of advanced association options that provide greater control over how associations behave. These options bring Grant closer to feature parity with Rails ActiveRecord.

## Dependent Options

The `dependent` option controls what happens to associated records when the parent record is destroyed.

### dependent: :destroy

Destroys all associated records when the parent is destroyed.

```crystal
class Author < Grant::Base
  has_many :posts, dependent: :destroy
  has_one :profile, dependent: :destroy
end

# When author is destroyed, all posts and profile are also destroyed
author.destroy! # => Also destroys all associated posts and profile
```

### dependent: :nullify

Sets the foreign key to NULL on all associated records when the parent is destroyed.

```crystal
class Category < Grant::Base
  has_many :articles, dependent: :nullify
end

# When category is destroyed, all articles have their category_id set to NULL
category.destroy! # => Sets category_id = NULL on all articles
```

### dependent: :delete / :delete_all

Deletes the associated rows with one SQL `DELETE` and no callbacks. `has_many` spells it `:delete_all`, `has_one` and `belongs_to` spell it `:delete`.

### dependent: :restrict_with_error

Prevents deletion of the parent record if any associated records exist. `destroy` returns `false` and the parent gets an error on `:base`. `:restrict` is the older spelling of the same behavior.

```crystal
class Team < Grant::Base
  has_many :members, dependent: :restrict_with_error
end

team.destroy # => false
team.errors.full_messages # => ["Cannot delete record because of dependent members"]
```

### dependent: :restrict_with_exception

Raises `Grant::Associations::RestrictError` (also reachable as `Grant::DeleteRestrictionError`) instead of adding an error.

### dependent: :destroy_async

Hands the destroy of the dependents to a queue once the parent's destroy commits. One job covers the whole association of one owner; it destroys the dependents in batches, does nothing while the owner row still exists, and is safe to run twice.

```crystal
class Author < Grant::Base
  has_many :posts, dependent: :destroy_async
end

# The default runs each job in a new fiber. Replace it to use a job system:
Grant::Dependent.async_destroy_enqueuer = ->(job : Grant::Dependent::AsyncDestroyJob) do
  MyQueue.push(job.owner_class, job.association, job.key)
  nil
end

# In the worker:
Grant::Dependent::AsyncDestroyJob.new(owner_class, association, key).perform
```

### belongs_to dependent

`belongs_to :author, dependent: :destroy` destroys the parent after the child is destroyed, `:delete` removes it with one `DELETE`, and `:destroy_async` queues the destroy. As in ActiveRecord this is rarely right when other records share the parent.

### destroyed_by_association

A record destroyed by `dependent: :destroy` can tell in its own callbacks which association did it:

```crystal
class Post < Grant::Base
  after_destroy { skip_notification if destroyed_by_association }
end
```

### Unknown values and has_many :through

A `dependent:` value the association type does not support is a compile error. On `has_many ..., through:` the option acts on the join records, never on the associated records.

## Optional Associations

By default, `belongs_to` associations are required. Grant validates that the foreign key is set and that the target exists in its active scope. Use `optional: true` to allow a missing target.

```crystal
class Product < Grant::Base
  # Required by default - validates that category_id resolves to a category
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
class Blog < Grant::Base
  column posts_count : Int32
  has_many :posts
end

class Post < Grant::Base
  # Updates blogs.posts_count automatically
  belongs_to :blog, counter_cache: true
end

# Or with a custom column name
class Comment < Grant::Base
  belongs_to :article, counter_cache: :comments_total
end
```

With `counter_cache: true` the column is the pluralized model name plus `_count` (`Category` gives `categories_count`).

The counter cache:
- Increments when a record is created
- Decrements when a record is destroyed
- Moves from one parent to the other when the association changes
- Changes with atomic `col = COALESCE(col, 0) + n` SQL, and adjusts a parent that is already loaded in memory
- Follows `has_many` `delete`, `delete_all` and `clear`, which change foreign keys without callbacks

```crystal
blog = Blog.create!(title: "My Blog", posts_count: 0)
post = Post.create!(title: "First Post", blog: blog)
blog.reload.posts_count # => 1

post.destroy!
blog.reload.posts_count # => 0
```

`counter_cache: {column: :posts_count, active: false}` records the counter without maintaining it, for the time a counter is being introduced.

`has_many :posts` reads the cached column for `size` when the association is not loaded. Name the column on the `has_many` with `counter_cache: :posts_total` when it differs.

Repair or adjust a counter directly:

```crystal
Blog.reset_counters(blog.id, :posts) # one UPDATE with a correlated COUNT(*) subquery
Blog.increment_counter(:posts_count, blog.id)
Blog.decrement_counter(:posts_count, blog.id, by: 2)
```

## Touch

The `touch` option updates the parent record's `updated_at` timestamp whenever the child record is saved or destroyed.

```crystal
class Profile < Grant::Base
  belongs_to :user, touch: true
end

# Updates user.updated_at whenever profile is saved
profile.update!(bio: "New bio") # => Also touches user.updated_at

# Touch a specific column instead
class Comment < Grant::Base
  belongs_to :post, touch: :last_commented_at
end
```

The parent is touched by key with one `UPDATE` and is not loaded (unless it has `after_touch` callbacks or touches its own parent). A save that changed nothing touches nothing, and moving a child to another parent touches both the old and the new one.

## Autosave

The `autosave` option automatically saves associated records when the parent is saved.

### Basic Usage

```crystal
class Order < Grant::Base
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

### How Autosave Works

| Option | Effect on `owner.save` |
| ------ | ---------------------- |
| unset | New records are validated and saved with the owner. |
| `autosave: true` | Also saves changed records and destroys the ones marked with `mark_for_destruction`. |
| `autosave: false` | Never saves the associated records. |

1. **Validation** (`validate:`, on by default for `has_many`): before anything is written, the new (or, with `autosave: true`, changed) records are validated. With `autosave: true` their errors are copied onto the owner as `posts.title`; without it the owner gets one `posts` "is invalid" error. `index_errors: true` keys them by position (`posts[0].title`). An invalid record makes `owner.save` return `false` and nothing is saved.
2. **Saving**: `belongs_to` targets are saved before the owner, `has_one` and `has_many` targets after it has its key. Only new or changed records are touched; loaded records that did not change cost nothing.
3. **Records built on the association** (`owner.posts.build`) are saved with the owner.

```crystal
class Blog < Grant::Base
  has_many :posts, autosave: true, index_errors: true
end

blog.posts.first.mark_for_destruction # destroyed, and dropped from the target, on blog.save
blog.posts.build(title: "")
blog.save # => false
blog.errors["posts[1].title"] # => ["can't be blank"]
```

`belongs_to :author, default: ->(post : Post) { Author.current }` fills a missing key before validation on create, and `post.author_changed?` / `post.author_previously_changed?` report the foreign key's dirty state.

### Autosave with has_many

```crystal
class Blog < Grant::Base
  has_many :posts, autosave: true
end

blog = Blog.create!(title: "My Blog")

# Add new posts
post1 = Post.new(title: "First Post")
post2 = Post.new(title: "Second Post")
blog.posts = [post1, post2]

blog.save! # Creates both posts

# Modify existing posts
blog.posts.first.title = "Updated First Post"
blog.save! # Updates the modified post
```

### Autosave with belongs_to

```crystal
class Comment < Grant::Base
  belongs_to :author, autosave: true
end

# Create a new author along with the comment
new_author = Author.new(name: "Jane Doe")
comment = Comment.new(content: "Great article!", author: new_author)
comment.save! # Also saves the new author
```

### Important Notes

- Autosave works on the records the association holds in memory: assigned, built, appended or loaded
- Direct manipulation of foreign keys bypasses autosave
- Autosave respects validation and wraps the owner plus associated saves in a transaction
- New `belongs_to` targets are saved before the owner; `has_one` and `has_many` targets are saved after the owner has its key

## Association Collections

A `has_many` accessor returns an owner-aware collection. It can load records lazily, preserve association scopes, and build relation queries without dropping the owner condition:

```crystal
author.books.where(published: true).order(created_at: :desc).limit(10).select
author.books.find_by(title: "A book") # searches only this author's books
author.books.build(title: "Draft")   # sets the configured owner foreign key
```

The collection supports `<<`, `append`, `push`, `delete`, `destroy`, `clear`, `ids`, `exists?`, `create`, `create!`, `delete_all`, and `destroy_all`. For a direct association, `delete` and `clear` nullify the foreign key; `destroy` runs record callbacks. For a `has_many :through` association, `delete_all` removes join rows and leaves target records intact.

## Combining Options

You can combine multiple options on a single association:

```crystal
class Article < Grant::Base
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
- `touch` uses `after_save`, `after_destroy` and `after_touch` callbacks
- `autosave` saves `belongs_to` records before the owner and `has_one`/`has_many` records after the owner, in a transaction

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
class Blog < Grant::Base
  def reset_posts_count!
    update!(posts_count: posts.count)
  end
end
```

### Dependent Destroy Too Slow

For large associations, consider:
1. Using `dependent: :delete_all` when child callbacks are not needed
2. Database-level CASCADE
3. Background job processing

### Circular Dependencies

Be careful with bidirectional autosave:

```crystal
# This can cause infinite loops
class User < Grant::Base
  has_one :profile, autosave: true
end

class Profile < Grant::Base
  belongs_to :user, autosave: true
end
```

## Testing Associations

When testing models with advanced association options:

### Testing Dependent Options

```crystal
it "destroys associated records" do
  author = Author.create!(name: "Jane")
  post = Post.create!(author: author)
  
  author.destroy!
  
  Post.find_by(id: post.id).should be_nil
end
```

### Testing Counter Cache

```crystal
it "maintains accurate count" do
  blog = Blog.create!(posts_count: 0)
  
  Post.create!(blog: blog, title: "Post 1")
  blog.reload.posts_count.should eq(1)
  
  Post.create!(blog: blog, title: "Post 2")
  blog.reload.posts_count.should eq(2)
end
```

### Testing Touch

```crystal
it "updates parent timestamp" do
  post = Post.create!(title: "Post")
  original_updated_at = post.updated_at
  
  sleep 0.001 # Ensure timestamp difference
  Comment.create!(post: post, content: "Comment")
  
  post.reload.updated_at.should_not eq(original_updated_at)
end
```

### Testing Autosave

```crystal
it "saves associated records" do
  order = Order.new
  order.line_items = [
    LineItem.new(product: "Widget", quantity: 1),
    LineItem.new(product: "Gadget", quantity: 2)
  ]
  
  order.save!
  
  order.line_items.all?(&.persisted?).should be_true
  LineItem.count.should eq(2)
end
```
