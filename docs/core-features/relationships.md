---
title: "Relationships and Associations"
category: "core-features"
subcategory: "relationships"
tags: ["relationships", "associations", "has_many", "belongs_to", "has_one", "polymorphic", "foreign_key"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["models-and-columns.md", "crud-operations.md"]
related_docs: ["querying-and-scopes.md", "validations.md", "../advanced/performance/eager-loading.md"]
last_updated: "2025-01-13"
estimated_read_time: "25 minutes"
use_cases: ["data-modeling", "database-design", "orm-relationships"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Relationships and Associations

Comprehensive guide to defining and working with relationships between models in Grant, from basic associations to advanced polymorphic relationships with sophisticated options.

## Basic Relationships

### belongs_to

The `belongs_to` association creates a one-to-one connection with another model where the declaring model holds the foreign key.

```crystal
class Post < Grant::Base
  belongs_to :user
  
  column id : Int64, primary: true
  column title : String
  column user_id : Int64  # Foreign key
end

# Usage
post = Post.find(1)
author = post.user  # Fetches associated user
post.user = another_user
post.save
```

#### Options

```crystal
class Post < Grant::Base
  # Custom foreign key
  belongs_to user : User, foreign_key: author_id : Int64
  
  # Optional association (allows NULL)
  belongs_to :category, optional: true
  
  # With counter cache
  belongs_to :blog, counter_cache: true
  
  # Touch parent on save
  belongs_to :article, touch: true
  
  # Custom class name
  belongs_to :author, class_name: User
end
```

### has_one

The `has_one` association creates a one-to-one connection where the other model holds the foreign key.

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

# Usage
user = User.find(1)
profile = user.profile
user.profile = Profile.new(bio: "My bio")
```

#### Database Schema

```sql
CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  email VARCHAR(255),
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE profiles (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT UNIQUE,  -- UNIQUE for one-to-one
  bio TEXT,
  created_at TIMESTAMP,
  updated_at TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_profiles_user_id ON profiles(user_id);
```

### has_many

The `has_many` association creates a one-to-many connection.

```crystal
class User < Grant::Base
  has_many :posts
  
  # With explicit class name
  has_many posts : Post
  
  # With custom foreign key
  has_many :articles, class_name: Post, foreign_key: :author_id
  
  column id : Int64, primary: true
  column name : String
end

class Post < Grant::Base
  belongs_to :user
  
  column id : Int64, primary: true
  column title : String
  column user_id : Int64
end

# Usage
user = User.find(1)
user.posts.each do |post|
  puts post.title
end

# Add new post
user.posts << Post.new(title: "New Post")
```

## Many-to-Many Relationships

Grant recommends using explicit join models for many-to-many relationships.

### Basic Many-to-Many

```crystal
class User < Grant::Base
  has_many :participations
  has_many :rooms, through: :participations
  
  column id : Int64, primary: true
  column name : String
end

class Participation < Grant::Base
  belongs_to :user
  belongs_to :room
  
  column id : Int64, primary: true
  column joined_at : Time
  column role : String  # Additional attributes
end

class Room < Grant::Base
  has_many :participations
  has_many :users, through: :participations
  
  column id : Int64, primary: true
  column name : String
end

# Usage
user = User.find(1)
room = Room.find(1)

# Create association
Participation.create(user: user, room: room, role: "member")

# Access through relationship
user.rooms.each do |room|
  puts room.name
end

room.users.each do |user|
  puts user.name
end
```

### Database Schema for Many-to-Many

```sql
CREATE TABLE participations (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL,
  room_id BIGINT NOT NULL,
  joined_at TIMESTAMP,
  role VARCHAR(50),
  created_at TIMESTAMP,
  updated_at TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id),
  FOREIGN KEY (room_id) REFERENCES rooms(id)
);

-- Composite index for efficient lookups
CREATE UNIQUE INDEX idx_participations_user_room 
  ON participations(user_id, room_id);
CREATE INDEX idx_participations_room_id ON participations(room_id);
```

## Advanced Association Options

### dependent

Controls what happens to associated records when parent is destroyed.

#### :destroy
```crystal
class Author < Grant::Base
  has_many :posts, dependent: :destroy
  has_one :profile, dependent: :destroy
end

# Destroys all posts and profile when author is destroyed
author.destroy!  # Triggers destroy on all associations
```

#### :nullify
```crystal
class Category < Grant::Base
  has_many :products, dependent: :nullify
end

# Sets category_id to NULL on all products
category.destroy!
```

#### :restrict
```crystal
class Team < Grant::Base
  has_many :players, dependent: :restrict
end

# Prevents deletion if players exist
team.destroy!  # Raises Grant::RecordNotDestroyed
```

### optional

Allows NULL foreign keys for belongs_to associations.

```crystal
class Product < Grant::Base
  belongs_to :category              # Required by default
  belongs_to :brand, optional: true # Allows NULL
  
  column id : Int64, primary: true
  column name : String
  column category_id : Int64
  column brand_id : Int64?
end

# Valid without brand
product = Product.new(name: "Widget", category_id: 1)
product.valid?  # => true
```

### counter_cache

Maintains count of associated records on parent model.

```crystal
class Blog < Grant::Base
  column id : Int64, primary: true
  column title : String
  column posts_count : Int32 = 0  # Counter column
  
  has_many :posts
end

class Post < Grant::Base
  belongs_to :blog, counter_cache: true
  
  # Or with custom column name
  # belongs_to :blog, counter_cache: :total_posts
end

# Usage
blog = Blog.create(title: "My Blog")
post = Post.create(title: "First Post", blog: blog)
blog.reload.posts_count  # => 1

post.destroy
blog.reload.posts_count  # => 0
```

### touch

Updates parent's `updated_at` when child is saved.

```crystal
class Comment < Grant::Base
  belongs_to :post, touch: true
  
  # Touch specific column
  belongs_to :article, touch: :last_activity_at
end

# Updates post.updated_at whenever comment changes
comment.update(content: "Updated")
```

### autosave

Automatically saves associated records with parent.

```crystal
class Order < Grant::Base
  has_many :line_items, autosave: true
  has_one :invoice, autosave: true
  
  column id : Int64, primary: true
end

# Saves order and all associations
order = Order.new
order.line_items << LineItem.new(product: "Widget", qty: 2)
order.invoice = Invoice.new(total: 100)
order.save!  # Saves everything in transaction
```

## Polymorphic Associations

Allow a model to belong to multiple other models through a single association.

### Basic Polymorphic Setup

```crystal
# Polymorphic model
class Comment < Grant::Base
  belongs_to :commentable, polymorphic: true
  
  column id : Int64, primary: true
  column content : String
  column commentable_id : Int64?
  column commentable_type : String?
end

# Parent models
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

# Usage
post = Post.create(title: "My Post")
photo = Photo.create(url: "image.jpg")

# Create comments
comment1 = Comment.create(
  content: "Great post!",
  commentable: post
)

comment2 = Comment.create(
  content: "Nice photo!",
  commentable: photo
)

# Retrieve polymorphic association
comment = Comment.find(1)
if comment.commentable.is_a?(Post)
  puts "Comment on post: #{comment.commentable.title}"
elsif comment.commentable.is_a?(Photo)
  puts "Comment on photo: #{comment.commentable.url}"
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

-- Index for efficient polymorphic queries
CREATE INDEX idx_comments_commentable 
  ON comments(commentable_type, commentable_id);
```

### Advanced Polymorphic Patterns

```crystal
# Tagging system
class Tag < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  has_many :taggings
end

class Tagging < Grant::Base
  belongs_to :tag
  belongs_to :taggable, polymorphic: true
  
  column id : Int64, primary: true
  column tag_id : Int64
  column taggable_id : Int64?
  column taggable_type : String?
end

# Multiple models can be tagged
class Article < Grant::Base
  has_many :taggings, as: :taggable, dependent: :destroy
  
  def tags
    taggings.includes(:tag).map(&.tag)
  end
  
  def add_tag(name : String)
    tag = Tag.find_or_create_by(name: name)
    taggings.create(tag: tag)
  end
end

class Product < Grant::Base
  has_many :taggings, as: :taggable, dependent: :destroy
end
```

## Self-Referential Associations

Models that have associations to themselves.

```crystal
class Employee < Grant::Base
  belongs_to :manager, class_name: Employee, optional: true
  has_many :subordinates, class_name: Employee, foreign_key: :manager_id
  
  column id : Int64, primary: true
  column name : String
  column manager_id : Int64?
end

# Usage
ceo = Employee.create(name: "CEO")
manager = Employee.create(name: "Manager", manager: ceo)
employee = Employee.create(name: "Employee", manager: manager)

ceo.subordinates      # => [manager]
manager.subordinates  # => [employee]
employee.manager      # => manager
```

## Association Callbacks

```crystal
class Post < Grant::Base
  has_many :comments, dependent: :destroy
  
  before_destroy :check_for_featured_comments
  
  private def check_for_featured_comments
    if comments.any?(&.featured?)
      errors.add(:base, "Cannot delete post with featured comments")
      throw :abort
    end
  end
end
```

## Association Validations

```crystal
class Order < Grant::Base
  has_many :line_items
  belongs_to :customer
  
  validate :must_have_items
  validate :customer_can_order
  
  private def must_have_items
    if line_items.empty?
      errors.add(:line_items, "must have at least one item")
    end
  end
  
  private def customer_can_order
    if customer && customer.suspended?
      errors.add(:customer, "account is suspended")
    end
  end
end
```

## Eager Loading (N+1 Prevention)

```crystal
# Bad: N+1 queries
posts = Post.all
posts.each do |post|
  puts post.author.name  # Query for each post
end

# Good: Eager loading
posts = Post.includes(:author)
posts.each do |post|
  puts post.author.name  # No additional queries
end

# Multiple associations
posts = Post.includes(:author, :comments)

# Nested associations
users = User.includes(posts: [:comments, :tags])
```

## Complex Association Examples

### Blog System

```crystal
class Blog < Grant::Base
  has_many :posts, dependent: :destroy
  has_many :authors, through: :posts
  has_one :settings, dependent: :destroy
  
  column id : Int64, primary: true
  column name : String
  column posts_count : Int32 = 0
end

class Post < Grant::Base
  belongs_to :blog, counter_cache: true
  belongs_to :author, class_name: User
  has_many :comments, dependent: :destroy
  has_many :post_tags, dependent: :destroy
  has_many :tags, through: :post_tags
  
  column id : Int64, primary: true
  column title : String
  column content : String
  column published : Bool = false
  column blog_id : Int64
  column author_id : Int64
end

class Comment < Grant::Base
  belongs_to :post, touch: true
  belongs_to :author, class_name: User
  belongs_to :parent, class_name: Comment, optional: true
  has_many :replies, class_name: Comment, foreign_key: :parent_id
  
  column id : Int64, primary: true
  column content : String
  column post_id : Int64
  column author_id : Int64
  column parent_id : Int64?
end
```

### E-commerce System

```crystal
class Product < Grant::Base
  belongs_to :category
  belongs_to :brand, optional: true
  has_many :variants, dependent: :destroy
  has_many :reviews, as: :reviewable
  has_many :cart_items, dependent: :restrict
  
  column id : Int64, primary: true
  column name : String
  column price : Float64
  column stock : Int32 = 0
end

class Order < Grant::Base
  belongs_to :customer, class_name: User
  has_many :line_items, dependent: :destroy, autosave: true
  has_one :payment, dependent: :destroy
  has_one :shipment, dependent: :destroy
  
  column id : Int64, primary: true
  column total : Float64
  column status : String
end

class LineItem < Grant::Base
  belongs_to :order, touch: true
  belongs_to :product
  
  column id : Int64, primary: true
  column quantity : Int32
  column price : Float64
end
```

## Best Practices

### 1. Index Foreign Keys
```sql
CREATE INDEX idx_posts_user_id ON posts(user_id);
CREATE INDEX idx_posts_blog_id ON posts(blog_id);
```

### 2. Use dependent Wisely
- `:destroy` - When child records should be deleted
- `:nullify` - When child records can exist independently
- `:restrict` - When deletion should be prevented

### 3. Validate Associations
```crystal
class Post < Grant::Base
  belongs_to :author
  
  validates :author, presence: true
  validate :author_must_be_active
  
  private def author_must_be_active
    if author && !author.active?
      errors.add(:author, "must be active")
    end
  end
end
```

### 4. Consider Database Constraints
```sql
ALTER TABLE posts 
ADD CONSTRAINT fk_posts_user 
FOREIGN KEY (user_id) 
REFERENCES users(id) 
ON DELETE CASCADE;
```

### 5. Document Complex Associations
```crystal
# Represents the many-to-many relationship between users and projects
# through team memberships. A user can be on multiple projects with
# different roles (owner, member, viewer).
class TeamMembership < Grant::Base
  belongs_to :user
  belongs_to :project
  
  column role : String
end
```

## Performance Considerations

- **Counter Cache**: Trades write performance for read performance
- **Touch**: Adds extra UPDATE queries, be cautious with chains
- **Dependent Destroy**: Can be slow for large associations
- **Autosave**: Can create multiple queries, use transactions
- **Eager Loading**: Essential for avoiding N+1 queries

## Testing Associations

```crystal
describe "Post associations" do
  it "belongs to author" do
    author = User.create(name: "John")
    post = Post.create(title: "Test", author: author)
    
    post.author.should eq(author)
  end
  
  it "destroys comments with post" do
    post = Post.create(title: "Test")
    comment = Comment.create(content: "Test", post: post)
    
    post.destroy!
    
    Comment.find(comment.id).should be_nil
  end
  
  it "maintains counter cache" do
    blog = Blog.create(name: "Test", posts_count: 0)
    
    Post.create(title: "Post 1", blog: blog)
    blog.reload.posts_count.should eq(1)
    
    Post.create(title: "Post 2", blog: blog)
    blog.reload.posts_count.should eq(2)
  end
end
```

## Troubleshooting

### Foreign Key Violations
Ensure proper order of operations and use transactions:
```crystal
Grant::Base.transaction do
  user = User.create!(name: "John")
  Profile.create!(user: user, bio: "Bio")
end
```

### Counter Cache Out of Sync
```crystal
Blog.all.each do |blog|
  blog.update_columns(posts_count: blog.posts.count)
end
```

### Circular Dependencies
Avoid bidirectional autosave to prevent infinite loops.

## Next Steps

- [Validations](validations.md)
- [Callbacks and Lifecycle](callbacks-lifecycle.md)
- [Eager Loading](../advanced/performance/eager-loading.md)
- [Query Optimization](../advanced/performance/query-optimization.md)