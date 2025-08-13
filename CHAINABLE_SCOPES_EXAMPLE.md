# Chainable Scopes: Technical Implementation Example

## Current vs Proposed Implementation

### Current Implementation (Not Chainable)

```crystal
# Model definition
class Post < Grant::Base
  table posts
  
  column id : Int64, primary: true
  column title : String
  column published : Bool
  column featured : Bool
  column created_at : Time
  
  scope :published, ->(query : Grant::Query::Builder(Post)) do
    query.where(published: true)
  end
  
  scope :featured, ->(query : Grant::Query::Builder(Post)) do
    query.where(featured: true)
  end
  
  scope :recent, ->(query : Grant::Query::Builder(Post)) do
    query.order(created_at: :desc)
  end
end

# Usage - CANNOT chain scopes
Post.published         # ✓ Works: Returns Grant::Query::Builder(Post)
Post.published.recent  # ✗ Error: undefined method 'recent' for Grant::Query::Builder(Post)

# Workaround required
Post.where(published: true).where(featured: true).order(created_at: :desc)
```

### Proposed Implementation (Chainable)

```crystal
# Model definition with new architecture
class Post < Grant::Base
  table posts
  
  column id : Int64, primary: true
  column title : String
  column published : Bool
  column featured : Bool
  column created_at : Time
  
  # Scopes are defined the same way
  scope :published, ->(query) { query.where(published: true) }
  scope :featured, ->(query) { query.where(featured: true) }
  scope :recent, ->(query) { query.order(created_at: :desc) }
  scope :by_title, ->(query, title) { query.where(title: title) }
end

# Generated code (automatically created by macros)
class Post
  # Custom QueryBuilder is auto-generated
  class QueryBuilder < Grant::Query::Builder(Post)
    # Scope methods are added to QueryBuilder
    def published
      where(published: true)
    end
    
    def featured
      where(featured: true)
    end
    
    def recent
      order(created_at: :desc)
    end
    
    def by_title(title)
      where(title: title)
    end
    
    # Override parent methods to return QueryBuilder type
    def where(*args, **kwargs) : QueryBuilder
      super
      self
    end
    
    def order(*args, **kwargs) : QueryBuilder
      super
      self
    end
    
    # ... other query methods
  end
  
  # Model class methods use custom QueryBuilder
  def self.__builder
    QueryBuilder.new(adapter.database_type)
  end
end

# Usage - Scopes ARE chainable!
Post.published.featured.recent  # ✓ Works: Returns Post::QueryBuilder
Post.recent.published.by_title("Hello")  # ✓ Works: All chainable
```

## Implementation Details

### 1. Modified Scoping Module

```crystal
module Grant::Scoping
  macro included
    macro inherited
      # Generate custom QueryBuilder class
      class QueryBuilder < ::Grant::Query::Builder({{@type}})
        # Ensure all methods return self for chaining
        {% for method in %w[where order limit offset group_by having select] %}
          def {{method.id}}(*args, **kwargs) : self
            super
            self
          end
        {% end %}
      end
    end
  end
  
  macro scope(name, body)
    # Add scope to model class
    def self.{{name.id}}(*args)
      result = {{body}}.call(__builder, *args)
      result  # Returns QueryBuilder instance
    end
    
    # Add scope to QueryBuilder for chaining
    class QueryBuilder
      def {{name.id}}(*args)
        result = {{body}}.call(self, *args)
        result  # Returns self (QueryBuilder instance)
      end
    end
  end
end
```

### 2. Modified Base Class

```crystal
abstract class Grant::Base
  macro inherited
    # Ensure QueryBuilder is available
    {% unless @type.has_constant?("QueryBuilder") %}
      class QueryBuilder < ::Grant::Query::Builder({{@type}})
      end
    {% end %}
    
    # Use custom QueryBuilder
    def self.__builder
      db_type = case adapter.class.to_s
                when "Grant::Adapter::Pg"
                  Grant::Query::Builder::DbType::Pg
                when "Grant::Adapter::Mysql"
                  Grant::Query::Builder::DbType::Mysql
                else
                  Grant::Query::Builder::DbType::Sqlite
                end
      
      QueryBuilder.new(db_type)
    end
  end
end
```

### 3. Association Integration

```crystal
class User < Grant::Base
  has_many :posts
  
  scope :active, ->(q) { q.where(active: true) }
end

class Post < Grant::Base
  belongs_to :user
  
  scope :published, ->(q) { q.where(published: true) }
  scope :recent, ->(q) { q.order(created_at: :desc) }
end

# With chainable scopes, associations can use scopes!
user = User.find(1)
user.posts.published.recent  # ✓ Works with new architecture!

# Complex queries become more readable
User.active
    .joins(:posts)
    .where(posts: {published: true})
    .includes(:profile)
    .order(created_at: :desc)
```

## Type Safety Example

```crystal
# Type annotations work correctly
query : Post::QueryBuilder = Post.published.featured
posts : Array(Post) = query.to_a

# Can still access Query::Builder methods
query.where_fields  # Array of where conditions
query.to_sql       # Generated SQL

# Compiler prevents mixing incompatible types
user_query : User::QueryBuilder = User.active
post_query : Post::QueryBuilder = Post.published

# This would be a compile error:
# user_query = post_query  # Error: can't assign Post::QueryBuilder to User::QueryBuilder
```

## Performance Considerations

```crystal
# Before: Generic Query::Builder - single class for all models
typeof(User.where(active: true))  # Grant::Query::Builder(User)
typeof(Post.where(published: true))  # Grant::Query::Builder(Post)

# After: Model-specific QueryBuilders - one class per model
typeof(User.where(active: true))  # User::QueryBuilder
typeof(Post.where(published: true))  # Post::QueryBuilder

# Impact:
# - Slightly larger binary size (one QueryBuilder class per model)
# - Compile time increases with number of models
# - Runtime performance should be identical
# - Better type safety and clearer error messages
```

## Migration Example

```crystal
# Step 1: Add feature flag
Grant.config.use_chainable_scopes = true

# Step 2: Models opt-in to new behavior
class Post < Grant::Base
  use_chainable_scopes!  # Generates custom QueryBuilder
  
  scope :published, ->(q) { q.where(published: true) }
end

# Step 3: Gradual migration
# Old code continues to work
Post.where(published: true)  # Still returns Grant::Query::Builder(Post)

# New code can use chainable scopes
Post.published.recent  # Returns Post::QueryBuilder

# Step 4: Future major version makes it default
# Remove feature flag and make all models use custom QueryBuilders
```