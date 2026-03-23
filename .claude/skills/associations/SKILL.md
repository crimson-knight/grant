---
name: grant-associations
description: Grant ORM associations including belongs_to, has_one, has_many, has_many through, polymorphic, dependent options, counter_cache, eager loading, and nested attributes.
user-invocable: false
---

# Grant Associations

## belongs_to

Creates a one-to-one connection where the declaring model holds the foreign key.

```crystal
class Post < Grant::Base
  belongs_to :user

  column id : Int64, primary: true
  column title : String
  column user_id : Int64   # Foreign key (inferred from association name)
end

post = Post.find(1)
author = post.user          # Fetches associated user
post.user = another_user
post.save
```

### belongs_to Options

```crystal
# Custom foreign key
belongs_to user : User, foreign_key: author_id : Int64

# Optional association (allows NULL foreign key)
belongs_to :category, optional: true

# Counter cache (maintains count on parent)
belongs_to :blog, counter_cache: true
belongs_to :article, counter_cache: :comments_total  # Custom column name

# Touch parent on save
belongs_to :article, touch: true
belongs_to :article, touch: :last_activity_at  # Touch specific column

# Custom class name
belongs_to :author, class_name: User

# Autosave associated record
belongs_to :author, autosave: true
```

## has_one

Creates a one-to-one connection where the other model holds the foreign key.

```crystal
class User < Grant::Base
  has_one :profile

  column id : Int64, primary: true
  column email : String
end

class Profile < Grant::Base
  belongs_to :user

  column id : Int64, primary: true
  column bio : String
  column user_id : Int64
end

user = User.find(1)
profile = user.profile
user.profile = Profile.new(bio: "My bio")
```

### has_one Options

```crystal
has_one :profile, dependent: :destroy
has_one :coach, foreign_key: :custom_id
has_one coach : Coach, class_name: Coach
has_one :invoice, autosave: true
```

## has_many

Creates a one-to-many connection.

```crystal
class User < Grant::Base
  has_many :posts
  # OR with explicit class name (needed for pluralization)
  has_many posts : Post
  # OR as parameter
  has_many :posts, class_name: Post
  # Custom foreign key
  has_many :articles, class_name: Post, foreign_key: :author_id

  column id : Int64, primary: true
  column name : String
end

user = User.find(1)
user.posts.each { |post| puts post.title }
```

### has_many Options

```crystal
has_many :posts, dependent: :destroy    # Destroy all on parent delete
has_many :products, dependent: :nullify  # Set FK to NULL
has_many :players, dependent: :restrict  # Prevent deletion if children exist
has_many :line_items, autosave: true    # Auto-save with parent
```

## has_many :through (Many-to-Many)

Grant recommends explicit join models for many-to-many relationships:

```crystal
class User < Grant::Base
  has_many :participants, class_name: Participant
  has_many :rooms, class_name: Room, through: :participants

  column id : Int64, primary: true
  column name : String
end

class Participant < Grant::Base
  belongs_to :user
  belongs_to :room

  column id : Int64, primary: true
  column role : String       # Additional attributes on the join
end

class Room < Grant::Base
  has_many :participants, class_name: Participant
  has_many :users, class_name: User, through: :participants

  column id : Int64, primary: true
  column name : String
end

# Usage
user.rooms.each { |room| puts room.name }
room.users.each { |user| puts user.name }
```

## Polymorphic Associations

Allow a model to belong to multiple other models through a single association.

```crystal
class Comment < Grant::Base
  belongs_to :commentable, polymorphic: true

  column id : Int64, primary: true
  column content : String
  column commentable_id : Int64?
  column commentable_type : String?
end

class Post < Grant::Base
  has_many :comments, as: :commentable
  column id : Int64, primary: true
  column title : String
end

class Photo < Grant::Base
  has_many :comments, as: :commentable
  column id : Int64, primary: true
  column url : String
end

# Create polymorphic comment
comment = Comment.create(content: "Great post!", commentable: post)

# Access polymorphic parent
if comment.commentable.is_a?(Post)
  puts comment.commentable.title
end
```

### Polymorphic Database Schema

```sql
CREATE TABLE comments (
  id BIGSERIAL PRIMARY KEY,
  content TEXT,
  commentable_id BIGINT,
  commentable_type VARCHAR(255),
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE INDEX idx_comments_commentable
  ON comments(commentable_type, commentable_id);
```

## Self-Referential Associations

```crystal
class Employee < Grant::Base
  belongs_to :manager, class_name: Employee, optional: true
  has_many :subordinates, class_name: Employee, foreign_key: :manager_id

  column id : Int64, primary: true
  column name : String
  column manager_id : Int64?
end

ceo = Employee.create(name: "CEO")
manager = Employee.create(name: "Manager", manager: ceo)
ceo.subordinates      # => [manager]
manager.manager       # => ceo
```

## Counter Cache

Maintains a count of associated records on the parent, avoiding expensive COUNT queries:

```crystal
class Blog < Grant::Base
  column id : Int64, primary: true
  column title : String
  column posts_count : Int32 = 0
  has_many :posts
end

class Post < Grant::Base
  belongs_to :blog, counter_cache: true
end

blog = Blog.create(title: "My Blog")
Post.create(title: "First Post", blog: blog)
blog.reload.posts_count  # => 1
```

Counter cache: increments on create, decrements on destroy, updates when association changes.

## Dependent Options

| Option | Behavior |
|--------|----------|
| `:destroy` | Destroys all associated records (runs callbacks) |
| `:nullify` | Sets foreign key to NULL on associated records |
| `:restrict` | Prevents deletion if associated records exist (raises `Grant::RecordNotDestroyed`) |

## Autosave

```crystal
class Order < Grant::Base
  has_many :line_items, autosave: true
  has_one :invoice, autosave: true
end

order = Order.new
order.line_items << LineItem.new(product: "Widget", quantity: 2)
order.invoice = Invoice.new(total: 100)
order.save!  # Saves order AND all associations in one call
```

## Eager Loading (N+1 Prevention)

```crystal
# BAD: N+1 queries
posts = Post.all
posts.each { |post| puts post.author.name }  # 1 query per post

# GOOD: Eager loading (2 queries total)
posts = Post.includes(:author)
posts.each { |post| puts post.author.name }  # No additional queries

# Multiple associations
posts = Post.includes(:author, :comments)

# Nested associations
users = User.includes(posts: [:comments, :tags])

# With conditions
Post.includes(:comments)
    .where("comments.approved = ?", [true])
    .references(:comments)
```

## Nested Attributes (accepts_nested_attributes_for)

Save associated records through the parent record:

```crystal
class Author < Grant::Base
  connection sqlite
  table authors
  column id : Int64, primary: true
  column name : String

  has_many :posts
  has_one :profile

  # Enable nested attributes with type declaration
  accepts_nested_attributes_for posts : Post,
    allow_destroy: true,
    reject_if: :all_blank,
    limit: 5

  accepts_nested_attributes_for profile : Profile,
    update_only: true

  # Must be called after all accepts_nested_attributes_for declarations
  enable_nested_saves
end
```

### Creating with Nested Attributes

```crystal
author = Author.new(name: "John Doe")
author.posts_attributes = [
  { "title" => "First Post", "content" => "Hello World" },
  { "title" => "Second Post", "content" => "Another post" }
]
author.save  # Saves author and creates nested posts
```

### Updating and Destroying Nested Records

```crystal
author.posts_attributes = [
  { "id" => 1, "title" => "Updated Title" },     # Update existing
  { "title" => "New Post" },                       # Create new
  { "id" => 2, "_destroy" => "true" }             # Destroy (if allow_destroy: true)
]
author.save
```

### Configuration Options

| Option | Description |
|--------|-------------|
| `allow_destroy: true` | Enables destruction via `_destroy` flag |
| `update_only: true` | Only updates existing records, no creation |
| `reject_if: :all_blank` | Rejects attributes where all values are blank |
| `limit: N` | Limits the number of nested records |

**Important**: The macro requires explicit type declaration (`posts : Post`, not just `:posts`), and `enable_nested_saves` must be called after all declarations.
