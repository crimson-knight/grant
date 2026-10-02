# Nested Attributes for Grant

This feature provides Rails-style nested attributes functionality for Grant (Grant ORM), allowing you to save associated records through the parent record.

## Features

- Type-safe API with explicit type declarations
- Support for creating, updating, and destroying nested records
- Configuration options: `allow_destroy`, `update_only`, `reject_if`, and `limit`
- Validation propagation from nested records to parent
- Compile-time validation for type safety

## Also supported

- `belongs_to` associations: `accepts_nested_attributes_for publisher : Publisher` builds the parent (or updates the current one when its id is given) and saves it before the record.
- `reject_if:` takes `:all_blank`, a proc `->(attrs : Hash(String, Grant::Columns::Type)) { ... }`, or the name of an instance method.
- Submitted ids are checked when the setter runs, with one `WHERE id IN (...)` query, and `Grant::RecordNotFound` is raised for an id that is not part of the association.
- Errors of an invalid nested record land on the owner as `posts.title`, or `posts[0].title` when the association has `index_errors: true`.

## Usage

### Basic Setup

```crystal
class Author < Grant::Base
  connection sqlite
  table authors
  
  column id : Int64, primary: true
  column name : String
  
  has_many :posts
  has_one :profile
  
  # Enable nested attributes with explicit type declaration
  accepts_nested_attributes_for posts : Post, 
    allow_destroy: true,
    reject_if: :all_blank,
    limit: 5
    
  accepts_nested_attributes_for profile : Profile,
    update_only: true
    
  # Enable automatic nested saves via callbacks
  enable_nested_saves
end

class Post < Grant::Base
  connection sqlite
  table posts
  
  column id : Int64, primary: true
  column title : String
  column content : String?
  column author_id : Int64?
  
  belongs_to :author
end

class Profile < Grant::Base
  connection sqlite
  table profiles
  
  column id : Int64, primary: true
  column bio : String?
  column author_id : Int64?
  
  belongs_to :author
end
```

### Creating Records with Nested Attributes

```crystal
author = Author.new(name: "John Doe")
author.posts_attributes = [
  { "title" => "First Post", "content" => "Hello World" },
  { "title" => "Second Post", "content" => "Another post" }
]
author.save # Saves author and creates nested posts
```

### Updating Nested Records

```crystal
author = Author.find(1)
author.posts_attributes = [
  { "id" => 1, "title" => "Updated Title" },  # Updates existing post
  { "title" => "New Post" }                   # Creates new post
]
author.save
```

For `has_many` and `has_one` associations, a submitted `id` must identify a
record in that parent's association. IDs from another parent are rejected and
added to the parent's errors; they are never updated or destroyed.

### Destroying Nested Records

When `allow_destroy: true` is set:

```crystal
author = Author.find(1)
author.posts_attributes = [
  { "id" => 1, "_destroy" => "true" }  # Marks post for destruction
]
author.save # Deletes the post
```

## Configuration Options

### allow_destroy

Enables destruction of nested records via the `_destroy` flag:

```crystal
accepts_nested_attributes_for posts : Post, allow_destroy: true
```

### update_only

Only allows updates to existing records, prevents creation:

```crystal
accepts_nested_attributes_for profile : Profile, update_only: true
```

When `update_only: true` is used for a singular association, the nested
attributes update the existing associated record even when the `id` is omitted.
If no associated record exists, the parent receives an association error rather
than silently dropping the submitted attributes.

### reject_if

Rejects nested attributes based on conditions:

```crystal
accepts_nested_attributes_for posts : Post, reject_if: :all_blank
```

Currently supports `:all_blank` which rejects attributes where all values are blank.

### limit

Limits the number of nested records:

```crystal
accepts_nested_attributes_for variants : Variant, limit: 3
```

## Important Notes

### Type Declaration Required

The macro requires explicit type declaration for compile-time safety:

```crystal
# Correct
accepts_nested_attributes_for posts : Post

# Incorrect - will raise compile error
accepts_nested_attributes_for :posts
```

### Enable Nested Saves

After declaring all nested attributes, call `enable_nested_saves` to set up the after_save callback:

```crystal
class Author < Grant::Base
  # ... associations ...
  
  accepts_nested_attributes_for posts : Post
  accepts_nested_attributes_for profile : Profile
  
  # Must be called after all accepts_nested_attributes_for declarations
  enable_nested_saves
end
```

### Manual Integration

If you need more control over when nested attributes are saved, you can manually call the save methods:

```crystal
class Author < Grant::Base
  # ... setup ...
  
  def save(**args)
    result = super
    
    if result && @_has_nested_attributes && !@_nested_attributes_data.empty?
      save_nested_posts if @_nested_attributes_data["posts"]?
      save_nested_profile if @_nested_attributes_data["profile"]?
    end
    
    result
  end
end
```

## How It Works

1. The `accepts_nested_attributes_for` macro generates:
   - An attributes setter method (e.g., `posts_attributes=`)
   - A private save method (e.g., `save_nested_posts`)
   - Configuration for the nested attributes behavior

2. When you set nested attributes, they're stored in `@_nested_attributes_data`

3. When `enable_nested_saves` is called, it sets up an `after_save` callback

4. After the parent record saves successfully, the callback processes all nested attributes:
   - Creates new records (unless `update_only: true`)
   - Updates existing records by ID
   - Destroys records marked with `_destroy` (if `allow_destroy: true`)

5. Validation errors from nested records are propagated to the parent

## Limitations

- Associations must be defined before calling `accepts_nested_attributes_for`
- The `enable_nested_saves` macro must be called after all `accepts_nested_attributes_for` declarations
- Currently only supports `:all_blank` for the `reject_if` option
- Nested attributes for polymorphic associations are not yet supported
