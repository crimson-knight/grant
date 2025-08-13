---
title: "Polymorphic Associations"
category: "advanced"
subcategory: "specialized"
tags: ["polymorphic", "associations", "relationships", "flexible-design", "database-patterns"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../../core-features/relationships.md", "../../core-features/models-and-columns.md"]
related_docs: ["../../core-features/relationships.md", "value-objects.md", "../../core-features/querying-and-scopes.md"]
last_updated: "2025-01-13"
estimated_read_time: "16 minutes"
use_cases: ["comments-system", "tagging", "notifications", "activity-feeds", "attachments"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Polymorphic Associations

Comprehensive guide to implementing polymorphic associations in Grant, allowing models to belong to multiple other models through a single association using type and ID columns.

## Overview

Polymorphic associations enable a model to belong to more than one other model on a single association. This pattern is useful when you have a model that could logically belong to several different parent models, eliminating the need for multiple foreign key columns or join tables.

### Common Use Cases

- **Comments**: Can belong to posts, photos, videos, etc.
- **Tags/Labels**: Can be applied to various content types
- **Attachments**: Files that can belong to different models
- **Notifications**: About various types of activities
- **Likes/Reactions**: Can be applied to any content
- **Audit Logs**: Track changes across all models

## Basic Implementation

### Setting Up Polymorphic Associations

```crystal
# The polymorphic model
class Comment < Grant::Base
  connection pg
  table comments
  
  column id : Int64, primary: true
  column content : String
  column author_name : String
  column created_at : Time = Time.utc
  
  # Polymorphic association - creates commentable_id and commentable_type columns
  belongs_to :commentable, polymorphic: true
  
  # Optional: Add indexes for performance
  # CREATE INDEX idx_comments_commentable ON comments(commentable_type, commentable_id);
end

# Parent models that can have comments
class Post < Grant::Base
  connection pg
  table posts
  
  column id : Int64, primary: true
  column title : String
  column body : String
  column published : Bool = false
  
  # Specify the polymorphic association with 'as:'
  has_many :comments, as: :commentable
end

class Photo < Grant::Base
  connection pg
  table photos
  
  column id : Int64, primary: true
  column url : String
  column caption : String
  column width : Int32
  column height : Int32
  
  has_many :comments, as: :commentable
end

class Video < Grant::Base
  connection pg
  table videos
  
  column id : Int64, primary: true
  column title : String
  column url : String
  column duration : Int32  # in seconds
  
  has_many :comments, as: :commentable
end
```

### Database Schema

```sql
-- Comments table with polymorphic columns
CREATE TABLE comments (
  id BIGSERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  author_name VARCHAR(255),
  commentable_id BIGINT,          -- ID of the associated record
  commentable_type VARCHAR(255),   -- Class name of the associated model
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Important: Add composite index for performance
CREATE INDEX idx_comments_commentable 
ON comments(commentable_type, commentable_id);

-- Optional: Add check constraint for valid types
ALTER TABLE comments 
ADD CONSTRAINT check_commentable_type 
CHECK (commentable_type IN ('Post', 'Photo', 'Video') OR commentable_type IS NULL);
```

## Working with Polymorphic Data

### Creating Records

```crystal
# Create parent records
post = Post.create!(
  title: "Understanding Polymorphism",
  body: "Polymorphic associations are powerful..."
)

photo = Photo.create!(
  url: "https://example.com/sunset.jpg",
  caption: "Beautiful sunset",
  width: 1920,
  height: 1080
)

# Add comments to different parent types
comment1 = Comment.new(
  content: "Great explanation!",
  author_name: "Alice"
)
comment1.commentable = post
comment1.save!

comment2 = Comment.new(
  content: "Stunning photo!",
  author_name: "Bob"
)
comment2.commentable = photo
comment2.save!

# Alternative: Create through association
post.comments.create!(
  content: "Very helpful",
  author_name: "Charlie"
)
```

### Retrieving Associated Records

```crystal
# Get the parent object for a comment
comment = Comment.find!(1)
parent = comment.commentable  # Returns Post, Photo, or Video instance

# Type checking and handling
case parent
when Post
  puts "Comment on post: #{parent.title}"
  puts "Post has #{parent.comments.count} total comments"
when Photo
  puts "Comment on photo: #{parent.caption}"
  puts "Photo dimensions: #{parent.width}x#{parent.height}"
when Video
  puts "Comment on video: #{parent.title}"
  puts "Video duration: #{parent.duration} seconds"
when Nil
  puts "Orphaned comment (parent deleted)"
else
  puts "Unknown parent type"
end

# Safe navigation
comment.commentable.try do |parent|
  puts "Parent class: #{parent.class.name}"
  puts "Parent ID: #{parent.id}"
end
```

### Querying Polymorphic Associations

```crystal
# Find all comments for a specific type
post_comments = Comment.where(commentable_type: "Post")
photo_comments = Comment.where(commentable_type: "Photo")

# Find comments for a specific parent
post = Post.find!(1)
comments = Comment.where(
  commentable_type: "Post",
  commentable_id: post.id
)

# Or use the association
comments = post.comments

# Find orphaned comments
orphaned = Comment.where(commentable_id: nil)

# Comments created in last 24 hours for any type
recent = Comment.where.gteq(:created_at, 24.hours.ago)

# Group comments by parent type
Comment.group(:commentable_type)
       .select("commentable_type, COUNT(*) as count")
```

## Advanced Patterns

### Multiple Polymorphic Associations

```crystal
class Attachment < Grant::Base
  column id : Int64, primary: true
  column file_name : String
  column file_size : Int64
  column content_type : String
  
  # Can belong to different models
  belongs_to :attachable, polymorphic: true
  
  # Can also be owned by different models
  belongs_to :owner, polymorphic: true
  
  def image?
    content_type.starts_with?("image/")
  end
  
  def pdf?
    content_type == "application/pdf"
  end
end

class Document < Grant::Base
  has_many :attachments, as: :attachable
  has_many :owned_attachments, 
    class_name: "Attachment",
    as: :owner
end
```

### Polymorphic Has-One

```crystal
class Address < Grant::Base
  column id : Int64, primary: true
  column street : String
  column city : String
  column country : String
  
  belongs_to :addressable, polymorphic: true
end

class User < Grant::Base
  has_one :address, as: :addressable
end

class Company < Grant::Base
  has_one :address, as: :addressable
end

# Usage
user = User.find!(1)
user.address = Address.new(
  street: "123 Main St",
  city: "Boston",
  country: "USA"
)
```

### Self-Referential Polymorphic

```crystal
class Note < Grant::Base
  column id : Int64, primary: true
  column content : String
  
  # Note can be attached to anything, including other notes
  belongs_to :notable, polymorphic: true
  
  # A note can have notes attached to it
  has_many :notes, as: :notable
end

# Create nested notes
main_note = Note.create!(content: "Main topic")
sub_note = Note.create!(
  content: "Additional thoughts",
  notable: main_note
)
```

### Polymorphic with STI (Single Table Inheritance)

```crystal
# Base class for different event types
abstract class Event < Grant::Base
  column id : Int64, primary: true
  column type : String  # STI discriminator
  column data : JSON::Any
  
  belongs_to :eventable, polymorphic: true
end

class ClickEvent < Event
  def clicks : Int32
    data["clicks"].as_i
  end
end

class ViewEvent < Event
  def duration : Int32
    data["duration"].as_i
  end
end

class Product < Grant::Base
  has_many :events, as: :eventable
  
  def click_events
    events.select { |e| e.is_a?(ClickEvent) }
  end
  
  def view_events
    events.select { |e| e.is_a?(ViewEvent) }
  end
end
```

## Complex Examples

### Activity Feed System

```crystal
class Activity < Grant::Base
  column id : Int64, primary: true
  column user_id : Int64
  column action : String  # "created", "updated", "liked", etc.
  column created_at : Time = Time.utc
  
  belongs_to :user
  belongs_to :trackable, polymorphic: true
  
  scope :recent, -> { order(created_at: :desc).limit(20) }
  scope :for_user, ->(user_id : Int64) { where(user_id: user_id) }
  
  def description : String
    case action
    when "created"
      "created #{trackable_type.downcase}"
    when "updated"
      "updated #{trackable_type.downcase}"
    when "liked"
      "liked #{trackable_type.downcase}"
    else
      action
    end
  end
end

module Trackable
  macro included
    has_many :activities, as: :trackable
    
    after_create :track_creation
    after_update :track_update
    
    private def track_creation
      Activity.create!(
        user_id: Current.user.id,
        trackable: self,
        action: "created"
      )
    end
    
    private def track_update
      Activity.create!(
        user_id: Current.user.id,
        trackable: self,
        action: "updated"
      )
    end
  end
end

class Article < Grant::Base
  include Trackable
  
  column id : Int64, primary: true
  column title : String
  column content : String
end

# Usage
user_activities = Activity.for_user(current_user.id).recent

user_activities.each do |activity|
  puts "#{activity.user.name} #{activity.description}"
  
  # Access the trackable object
  case activity.trackable
  when Article
    puts "  Article: #{activity.trackable.title}"
  when Photo
    puts "  Photo: #{activity.trackable.caption}"
  end
end
```

### Tagging System

```crystal
class Tag < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  has_many :taggings
  
  def self.find_or_create_by(name : String) : Tag
    find_by(name: name) || create!(name: name)
  end
end

class Tagging < Grant::Base
  column id : Int64, primary: true
  column tag_id : Int64
  column created_at : Time = Time.utc
  
  belongs_to :tag
  belongs_to :taggable, polymorphic: true
  
  validates_uniqueness_of :tag_id, scope: [:taggable_type, :taggable_id]
end

module Taggable
  macro included
    has_many :taggings, as: :taggable
    has_many :tags, through: :taggings
    
    def tag_list : String
      tags.map(&.name).join(", ")
    end
    
    def tag_list=(names : String)
      tag_names = names.split(",").map(&.strip).reject(&.empty?)
      
      # Remove old tags
      taggings.destroy_all
      
      # Add new tags
      tag_names.each do |name|
        tag = Tag.find_or_create_by(name)
        taggings.create!(tag: tag)
      end
    end
    
    def tagged_with?(name : String) : Bool
      tags.any? { |t| t.name == name }
    end
  end
  
  module ClassMethods
    def tagged_with(tag_name : String)
      tag = Tag.find_by(name: tag_name)
      return none unless tag
      
      joins(:taggings).where(taggings: {tag_id: tag.id})
    end
  end
end

class Product < Grant::Base
  include Taggable
  extend Taggable::ClassMethods
  
  column id : Int64, primary: true
  column name : String
  column price : Float64
end

# Usage
product = Product.find!(1)
product.tag_list = "electronics, sale, featured"
product.save!

# Find products with specific tag
sale_products = Product.tagged_with("sale")
```

### Notification System

```crystal
class Notification < Grant::Base
  column id : Int64, primary: true
  column recipient_id : Int64
  column actor_id : Int64
  column action : String
  column read : Bool = false
  column created_at : Time = Time.utc
  
  belongs_to :recipient, class_name: "User"
  belongs_to :actor, class_name: "User"
  belongs_to :notifiable, polymorphic: true
  
  scope :unread, -> { where(read: false) }
  scope :recent, -> { order(created_at: :desc) }
  
  def mark_as_read!
    update!(read: true)
  end
  
  def message : String
    actor_name = actor.name
    
    case notifiable
    when Comment
      "#{actor_name} commented on your #{notifiable.commentable_type.downcase}"
    when Like
      "#{actor_name} liked your #{notifiable.likeable_type.downcase}"
    when Follow
      "#{actor_name} started following you"
    else
      "#{actor_name} #{action}"
    end
  end
end

module Notifiable
  macro included
    has_many :notifications, as: :notifiable
    
    def notify(recipient : User, actor : User, action : String)
      return if recipient.id == actor.id  # Don't notify self
      
      Notification.create!(
        recipient: recipient,
        actor: actor,
        notifiable: self,
        action: action
      )
    end
  end
end

class Comment < Grant::Base
  include Notifiable
  
  belongs_to :commentable, polymorphic: true
  belongs_to :author, class_name: "User"
  
  after_create :notify_parent_author
  
  private def notify_parent_author
    if parent_author = commentable.try(&.author)
      notify(parent_author, author, "commented")
    end
  end
end
```

## Performance Optimization

### Eager Loading

```crystal
# Load polymorphic associations efficiently
comments = Comment.includes(:commentable).limit(10)

comments.each do |comment|
  # No N+1 queries
  puts comment.commentable.try(&.title)
end

# Preload specific types
post_ids = Comment.where(commentable_type: "Post")
                  .pluck(:commentable_id)
posts = Post.where(id: post_ids).index_by(&.id)

Comment.where(commentable_type: "Post").each do |comment|
  post = posts[comment.commentable_id]?
  puts post.try(&.title)
end
```

### Database Indexes

```sql
-- Essential indexes for polymorphic associations
CREATE INDEX idx_comments_commentable 
ON comments(commentable_type, commentable_id);

CREATE INDEX idx_comments_commentable_type 
ON comments(commentable_type);

-- For queries by parent
CREATE INDEX idx_comments_parent 
ON comments(commentable_id, commentable_type) 
WHERE commentable_id IS NOT NULL;

-- Partial indexes for specific types
CREATE INDEX idx_comments_posts 
ON comments(commentable_id) 
WHERE commentable_type = 'Post';
```

### Query Optimization

```crystal
# Efficient counting by type
def self.count_by_type
  connection.query_all(
    "SELECT commentable_type, COUNT(*) as count 
     FROM comments 
     GROUP BY commentable_type",
    as: {String?, Int64}
  ).to_h
end

# Batch loading for specific type
def self.load_for_posts(post_ids : Array(Int64))
  where(commentable_type: "Post", commentable_id: post_ids)
    .group_by(&.commentable_id)
end
```

## Testing Polymorphic Associations

```crystal
describe Comment do
  describe "polymorphic associations" do
    it "can belong to different parent types" do
      post = Post.create!(title: "Test Post", body: "Content")
      photo = Photo.create!(url: "test.jpg", caption: "Test")
      
      post_comment = Comment.create!(
        content: "Post comment",
        commentable: post
      )
      
      photo_comment = Comment.create!(
        content: "Photo comment",
        commentable: photo
      )
      
      post_comment.commentable_type.should eq("Post")
      post_comment.commentable_id.should eq(post.id)
      post_comment.commentable.should eq(post)
      
      photo_comment.commentable_type.should eq("Photo")
      photo_comment.commentable_id.should eq(photo.id)
      photo_comment.commentable.should eq(photo)
    end
    
    it "handles nil parent gracefully" do
      comment = Comment.create!(content: "Orphaned")
      comment.commentable.should be_nil
      comment.commentable_type.should be_nil
      comment.commentable_id.should be_nil
    end
    
    it "can query by parent type" do
      post = Post.create!(title: "Test", body: "Content")
      photo = Photo.create!(url: "test.jpg", caption: "Test")
      
      3.times { Comment.create!(commentable: post, content: "Post") }
      2.times { Comment.create!(commentable: photo, content: "Photo") }
      
      Comment.where(commentable_type: "Post").count.should eq(3)
      Comment.where(commentable_type: "Photo").count.should eq(2)
    end
  end
end
```

## Best Practices

### 1. Always Add Indexes

```sql
-- Composite index is crucial for performance
CREATE INDEX idx_polymorphic 
ON table_name(polymorphic_type, polymorphic_id);
```

### 2. Use Type Constants

```crystal
class Comment < Grant::Base
  COMMENTABLE_TYPES = ["Post", "Photo", "Video"]
  
  validate :valid_commentable_type
  
  private def valid_commentable_type
    return if commentable_type.nil?
    unless COMMENTABLE_TYPES.includes?(commentable_type)
      errors.add(:commentable_type, "is not a valid type")
    end
  end
end
```

### 3. Handle Orphaned Records

```crystal
class Comment < Grant::Base
  # Soft handling of missing parents
  def commentable
    return nil unless commentable_id && commentable_type
    
    @commentable ||= begin
      klass = commentable_type.constantize
      klass.find?(commentable_id)
    rescue
      nil
    end
  end
  
  # Cleanup orphaned records
  def self.cleanup_orphaned
    where(commentable_id: nil).destroy_all
  end
end
```

### 4. Consider Alternatives

```crystal
# Sometimes separate tables are better
class PostComment < Grant::Base
  belongs_to :post
end

class PhotoComment < Grant::Base
  belongs_to :photo
end

# Or use STI instead
class Comment < Grant::Base
  column type : String  # STI
end

class PostComment < Comment
  belongs_to :post
end
```

## Troubleshooting

### Type Resolution Issues

```crystal
# Register custom type mappings
Grant::PolymorphicRegistry.register("CustomPost", Post)

# Handle namespaced models
class Admin::Post < Grant::Base
  has_many :comments, 
    as: :commentable,
    class_name: "Comment"
end
```

### Migration Issues

```sql
-- Add polymorphic columns to existing table
ALTER TABLE comments 
ADD COLUMN commentable_type VARCHAR(255),
ADD COLUMN commentable_id BIGINT;

-- Migrate existing foreign keys
UPDATE comments 
SET commentable_type = 'Post', 
    commentable_id = post_id 
WHERE post_id IS NOT NULL;

-- Drop old foreign key columns
ALTER TABLE comments DROP COLUMN post_id;
```

## Next Steps

- [Relationships](../../core-features/relationships.md)
- [Enum Attributes](enum-attributes.md)
- [Value Objects](value-objects.md)
- [Serialized Columns](serialized-columns.md)