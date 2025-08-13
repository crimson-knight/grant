# Features Not Needed Due to Crystal's Design

## 1. Type-Related Features

### ReadOnlyAttributes Type Checking
**Why not needed**: Crystal's immutability can be enforced at compile time.
```crystal
# Crystal way
getter name : String  # read-only
property name : String  # read-write
```

### Reflection (Partial)
**Why not needed**: Much of Rails' reflection is for runtime type discovery.
- Crystal has compile-time macros for introspection
- Type information is available at compile time
- No need for runtime type discovery

## 2. Async/Promise Features

### Async Calculations (from ActiveRecord::Calculations)
**Why not needed as designed**: Crystal has native concurrency.
```crystal
# Rails way
User.async_count  # returns promise

# Crystal way
spawn do
  count = User.count
  channel.send(count)
end
result = channel.receive
```

### Promise-based APIs
**Why not needed**: Use Crystal's channels and fibers instead.
- Fibers are lightweight
- Channels provide communication
- WaitGroup for synchronization

## 3. Ruby-Specific Workarounds

### DelegatedType
**Why partially not needed**: Crystal has better composition patterns.
- Union types handle polymorphism differently
- Modules provide clean composition
- Less need for delegation patterns

### Store (ActiveRecord::Store)
**Why partially not needed**: Crystal can use typed JSON columns.
```crystal
# Crystal way with typed JSON
class User < Grant::Base
  column preferences : JSON::Any
  
  # Or with a specific type
  column settings : UserSettings
end

struct UserSettings
  include JSON::Serializable
  property theme : String
  property notifications : Bool
end
```

### SpawnMethods
**Why not needed**: Crystal's query interface handles this differently.
- Method chaining works naturally
- No need for spawn/merge complexity
- Cleaner API with Crystal's type system

## 4. Framework Integration

### Middleware Classes
**Why not needed in Grant**: These are Rails-specific.
- DatabaseSelector - Framework concern, not ORM
- ShardSelector - Framework concern, not ORM
- Should be implemented at application level

### Integration (Caching)
**Why partially not needed**: Crystal web frameworks handle this differently.
- Cache key generation can be simpler
- Less dynamic behavior needed
- Framework-specific concern

## 5. Security Features Better Handled Elsewhere

### SecurePassword
**Why not needed in ORM**: Should use dedicated crypto libraries.
```crystal
# Better to use crystal's crypto
require "crypto/bcrypt/password"

class User
  def password=(raw)
    @password_hash = Crypto::Bcrypt::Password.create(raw).to_s
  end
  
  def authenticate(raw)
    Crypto::Bcrypt::Password.new(@password_hash).verify(raw)
  end
end
```

## 6. Ruby Dynamic Features

### NoTouching
**Why not needed**: This is a runtime behavior modification.
- Crystal's compile-time nature makes this less useful
- Can be handled with explicit flags if needed
- Not a common pattern in Crystal

### Suppressor
**Why not needed**: Another runtime behavior modification.
- Compile-time flags are preferred
- Explicit control flow is clearer
- Not idiomatic in Crystal

## Summary

Crystal's type system, compile-time checks, and native concurrency eliminate the need for many Active Record features that exist to work around Ruby's dynamic nature or lack of built-in concurrency. This is actually a strength - Grant can be simpler and more performant by leveraging Crystal's capabilities instead of reimplementing Ruby patterns.