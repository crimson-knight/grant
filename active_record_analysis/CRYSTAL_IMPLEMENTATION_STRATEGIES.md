# Crystal-Specific Implementation Strategies

## Leveraging Crystal's Strengths for Active Record Features

### 1. Transactions with Fibers

**Challenge**: Ensuring transaction stays on same connection across fibers

**Crystal Strategy**:
```crystal
class TransactionManager
  # Use fiber-local storage
  class_property fiber_transactions = {} of Fiber => Transaction
  
  def self.current_transaction
    fiber_transactions[Fiber.current]?
  end
  
  def self.transaction(&)
    fiber = Fiber.current
    connection = ConnectionPool.checkout_for_fiber(fiber)
    
    transaction = Transaction.new(connection)
    fiber_transactions[fiber] = transaction
    
    transaction.execute do
      yield
    end
  ensure
    fiber_transactions.delete(fiber)
    ConnectionPool.checkin(connection)
  end
end
```

### 2. Async Operations with Channels

**Rails Approach**: Promises and async methods
**Crystal Approach**: Channels and fibers

```crystal
module Grant::Async
  # Instead of User.async_count returning a promise
  def self.async_count(model : T.class) forall T
    channel = Channel(Int64).new
    
    spawn do
      count = model.count
      channel.send(count)
    end
    
    channel
  end
  
  # Usage
  count_channel = Grant::Async.async_count(User)
  # Do other work...
  user_count = count_channel.receive
end

# Or with multiple operations
def gather_stats
  channels = {
    users: Grant::Async.async_count(User),
    posts: Grant::Async.async_count(Post),
    comments: Grant::Async.async_count(Comment)
  }
  
  {
    users: channels[:users].receive,
    posts: channels[:posts].receive,
    comments: channels[:comments].receive
  }
end
```

### 3. Type-Safe Encryption

**Leverage Crystal's type system for encrypted attributes**:

```crystal
module Grant::Encryption
  # Type-safe encrypted attribute
  macro encrypted_column(name, type, **options)
    @[JSON::Field(ignore: true)]
    @_encrypted_{{name.id}} : String?
    
    def {{name.id}} : {{type}}?
      if encrypted = @_encrypted_{{name.id}}
        decrypt(encrypted, {{type}})
      end
    end
    
    def {{name.id}}=(value : {{type}}?)
      @_encrypted_{{name.id}} = value ? encrypt(value) : nil
    end
    
    # Database column
    column _encrypted_{{name.id}} : String?
  end
end

class User < Grant::Base
  include Grant::Encryption
  
  encrypted_column ssn : String
  encrypted_column salary : Float64
  encrypted_column metadata : Hash(String, String)
end
```

### 4. Compile-Time Validations

**Use macros for zero-runtime-cost validations**:

```crystal
module Grant::CompileTimeValidations
  macro validate_types
    {% for ivar in @type.instance_vars %}
      {% ann = ivar.annotation(Grant::Column) %}
      {% if ann && !ann[:nilable] && ivar.type.nilable? %}
        {% raise "Column #{ivar.name} is marked as not nilable but type is #{ivar.type}" %}
      {% end %}
    {% end %}
  end
  
  macro validate_associations
    {% for method in @type.methods %}
      {% if ann = method.annotation(Grant::Relationship) %}
        {% target = ann[:target] %}
        {% unless target.resolve? %}
          {% raise "Association #{method.name} references undefined class #{target}" %}
        {% end %}
      {% end %}
    {% end %}
  end
end
```

### 5. Zero-Cost Abstractions with Generics

**Use generics for type-safe, reusable components**:

```crystal
# Type-safe cache implementation
class QueryCache(T)
  @cache = {} of String => Array(T)
  
  def fetch(key : String, &) : Array(T)
    @cache[key] ||= yield
  end
  
  def clear
    @cache.clear
  end
end

# Type-safe batch processor
class BatchProcessor(T)
  def initialize(@batch_size : Int32 = 1000)
  end
  
  def process(records : Array(T), &block : Array(T) -> _)
    records.each_slice(@batch_size) do |batch|
      yield batch
    end
  end
end
```

### 6. Efficient Connection Pooling

**Crystal's concurrency model for pools**:

```crystal
class ConnectionPool(T)
  @connections = Channel(T).new(@size)
  @factory : -> T
  
  def initialize(@size : Int32, &@factory : -> T)
    @size.times { @connections.send(@factory.call) }
  end
  
  def checkout : T
    @connections.receive
  end
  
  def checkin(connection : T)
    @connections.send(connection)
  end
  
  def with_connection(&)
    connection = checkout
    yield connection
  ensure
    checkin(connection) if connection
  end
end
```

### 7. Macro-Based Query DSL

**Leverage macros for expressive queries**:

```crystal
macro where(conditions)
  {% if conditions.is_a?(NamedTupleLiteral) %}
    where({
      {% for key, value in conditions %}
        {{key.id.stringify}} => {{value}},
      {% end %}
    })
  {% elsif conditions.is_a?(StringLiteral) %}
    where({{conditions}})
  {% else %}
    {% raise "Invalid where conditions" %}
  {% end %}
end

# Enables
User.where(name: "John", age: 25)
User.where("age > ?", 21)
```

### 8. Type-Safe Nested Attributes

**Use Crystal's type system for nested attributes**:

```crystal
module NestedAttributes
  macro accepts_nested_attributes_for(association, **options)
    def {{association.id}}_attributes=(values : Array(NamedTuple))
      values.each do |attrs|
        if attrs[:_destroy]?
          {{association.id}}.find { |r| r.id == attrs[:id]? }.try(&.mark_for_destruction)
        elsif attrs[:id]?
          {{association.id}}.find { |r| r.id == attrs[:id]? }.try(&.assign_attributes(attrs))
        else
          {{association.id}}.build(attrs)
        end
      end
    end
  end
end
```

### 9. Performance Optimizations

**Crystal-specific performance tricks**:

```crystal
# Stack allocation for small objects
struct QueryStats
  property count : Int32
  property duration : Time::Span
  
  def initialize(@count, @duration)
  end
end

# Avoid allocations in hot paths
module FastQuery
  @sql_buffer = String::Builder.new(1024)
  
  def build_sql
    @sql_buffer.clear
    @sql_buffer << "SELECT * FROM "
    @sql_buffer << table_name
    @sql_buffer.to_s
  end
end

# Use StaticArray for known-size collections
struct BatchResult(T, N)
  @results : StaticArray(T, N)
  
  def initialize(@results)
  end
end
```

### 10. Leveraging Crystal's Standard Library

**Use built-in features instead of reimplementing**:

```crystal
# Use Log for query logs instead of custom logger
Log.for("grant.sql").info &.emit("Query executed", 
  sql: sql,
  duration: duration
)

# Use built-in Random::Secure for tokens
def generate_secure_token
  Random::Secure.hex(16)
end

# Use built-in Base64 for encoding
def encode_signed_id(id : Int64, purpose : String)
  data = "#{id}:#{purpose}:#{Time.utc.to_unix}"
  Base64.urlsafe_encode(encrypt(data))
end
```

## Crystal Patterns to Avoid

### 1. ❌ Dynamic Method Definition
```ruby
# Rails way - DON'T DO THIS
define_method :dynamic_method do
  # ...
end
```

### 2. ❌ Runtime Type Checking
```crystal
# Avoid
if value.is_a?(String)
  process_string(value)
elsif value.is_a?(Int32)
  process_int(value)
end

# Prefer compile-time overloads
def process(value : String)
  # ...
end

def process(value : Int32)
  # ...
end
```

### 3. ❌ Monkey Patching Standard Classes
```crystal
# Avoid extending standard library classes
class String
  def to_snake_case
    # ...
  end
end

# Prefer modules or separate methods
module StringExtensions
  def self.to_snake_case(str : String)
    # ...
  end
end
```

## Conclusion

Crystal's features allow Grant to implement Active Record functionality with:
- Better performance (zero-cost abstractions)
- Stronger guarantees (compile-time type checking)
- Cleaner code (macros and generics)
- Native concurrency (fibers and channels)

The key is to embrace Crystal's paradigms rather than directly translating Ruby patterns.