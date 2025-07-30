# Polymorphic Associations

Grant now supports polymorphic associations, allowing a model to belong to more than one other model on a single association. This is useful when you have a model that could belong to several different parent models.

## Overview

Polymorphic associations use a pair of columns to store both the associated record's ID and its type (class name). This allows a single association to reference records from multiple tables.

## Basic Usage

### Setting up a Polymorphic belongs_to

```crystal
class Comment < Granite::Base
  connection sqlite
  table comments
  
  column id : Int64, primary: true
  column content : String
  
  # Creates commentable_id and commentable_type columns
  belongs_to :commentable, polymorphic: true
end
```

### Setting up the Parent Models

```crystal
class Post < Granite::Base
  connection sqlite
  table posts
  
  column id : Int64, primary: true
  column title : String
  column body : String
  
  # Use 'as:' to specify the polymorphic association name
  has_many :comments, as: :commentable
end

class Photo < Granite::Base
  connection sqlite
  table photos
  
  column id : Int64, primary: true
  column url : String
  column caption : String
  
  has_many :comments, as: :commentable
end
```

## How It Works

When you declare `belongs_to :commentable, polymorphic: true`, Grant automatically:

1. Creates two columns:
   - `commentable_id` (Int64?) - stores the ID of the associated record
   - `commentable_type` (String?) - stores the class name of the associated record

2. Creates getter and setter methods for the association

3. Registers the model types for polymorphic resolution

## Using Polymorphic Associations

### Creating Records

```crystal
# Create a post and add comments
post = Post.create!(title: "My Post", body: "Post content")
comment1 = Comment.new(content: "Great post!")
comment1.commentable = post
comment1.save!

# Create a photo and add comments
photo = Photo.create!(url: "image.jpg", caption: "Beautiful sunset")
comment2 = Comment.new(content: "Amazing photo!")
comment2.commentable = photo
comment2.save!
```

### Retrieving Associated Records

```crystal
# Get the commentable for a comment
comment = Comment.find!(1)
commentable = comment.commentable  # Returns a Post or Photo instance

# Type checking
if commentable.is_a?(Post)
  puts "Comment on post: #{commentable.title}"
elsif commentable.is_a?(Photo)
  puts "Comment on photo: #{commentable.caption}"
end
```

### Querying from Parent

```crystal
# Get all comments for a post
post = Post.find!(1)
post_comments = post.comments.to_a

# Get all comments for a photo
photo = Photo.find!(1)
photo_comments = photo.comments.to_a
```

## Advanced Options

### Custom Column Names

You can customize the column names used for the polymorphic association:

```crystal
class Comment < Granite::Base
  belongs_to :owner, polymorphic: true, 
    foreign_key: :owner_id,
    type_column: :owner_class
end
```

### has_one Polymorphic Associations

Polymorphic associations also work with `has_one`:

```crystal
class Image < Granite::Base
  column id : Int64, primary: true
  column url : String
  
  belongs_to :imageable, polymorphic: true
end

class Post < Granite::Base
  has_one :image, as: :imageable
end

class User < Granite::Base
  has_one :avatar, class_name: Image, as: :imageable
end
```

## Type Registration

Grant automatically registers all models that inherit from `Granite::Base` for polymorphic type resolution. This happens through the `inherited` macro, so no manual registration is required.

If you need to manually register a type for any reason:

```crystal
Granite::Polymorphic.register_type("MyModel", MyModel)
```

## Limitations and Considerations

1. **Type Safety**: Since polymorphic associations can return different types, the return type is not strongly typed. You may need to use type checks (`is_a?`) when working with polymorphic associations.

2. **Foreign Key Constraints**: Database-level foreign key constraints cannot be used with polymorphic associations since the foreign key can reference multiple tables.

3. **Eager Loading**: Currently, eager loading polymorphic associations requires special handling and may not be as efficient as regular associations.

4. **Querying**: When querying polymorphic associations, you need to specify both the type and ID:

```crystal
# Find all comments for posts
Comment.where(commentable_type: "Post")

# Find all comments for a specific post
Comment.where(commentable_type: "Post", commentable_id: post.id)
```

## Migration Example

When creating tables with polymorphic associations:

```sql
CREATE TABLE comments (
  id INTEGER PRIMARY KEY,
  content TEXT NOT NULL,
  commentable_id INTEGER,
  commentable_type VARCHAR(255),
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

-- Note: No foreign key constraint can be added for polymorphic associations
```

## Best Practices

1. **Use Meaningful Names**: Choose association names that clearly indicate the relationship (e.g., `commentable`, `taggable`, `imageable`).

2. **Add Indexes**: Always add database indexes on the polymorphic columns for better query performance:
   ```sql
   CREATE INDEX idx_comments_commentable ON comments(commentable_type, commentable_id);
   ```

3. **Consider Alternatives**: If you only need to associate with 2-3 specific models, consider using separate associations instead of polymorphic ones for better type safety.

4. **Document Your Associations**: Since polymorphic associations can be less obvious than regular ones, document which models can be associated.

## Example: Tagging System

Here's a complete example of a polymorphic tagging system:

```crystal
class Tag < Granite::Base
  column id : Int64, primary: true
  column name : String
  
  has_many :taggings
end

class Tagging < Granite::Base
  column id : Int64, primary: true
  
  belongs_to :tag
  belongs_to :taggable, polymorphic: true
end

class Article < Granite::Base
  column id : Int64, primary: true
  column title : String
  
  has_many :taggings, as: :taggable
  
  def tags
    taggings.map(&.tag)
  end
end

class Product < Granite::Base
  column id : Int64, primary: true
  column name : String
  
  has_many :taggings, as: :taggable
  
  def tags
    taggings.map(&.tag)
  end
end

# Usage
article = Article.create!(title: "My Article")
product = Product.create!(name: "My Product")
tag = Tag.create!(name: "featured")

Tagging.create!(tag: tag, taggable: article)
Tagging.create!(tag: tag, taggable: product)

# Find all featured items
featured_taggings = Tagging.joins(:tag).where("tags.name": "featured")
```