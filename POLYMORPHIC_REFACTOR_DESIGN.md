# Polymorphic Associations Refactor Design

## Problem Statement

The current polymorphic association implementation fails because:
1. The type registry uses `Granite::Base.class` as the value type
2. `Granite::Base` is abstract and cannot be instantiated
3. Crystal's type system doesn't allow runtime type resolution in the way we need

## Current Implementation Issues

```crystal
# This creates a compile-time issue
class_property polymorphic_type_map = {} of String => Granite::Base.class

# When resolve_type returns Granite::Base.class?, calling find on it fails
klass = Granite::Polymorphic.resolve_type(type_value)
klass.find(id_value)  # Error: can't instantiate abstract class
```

## New Design

### Key Principles
1. Avoid storing abstract class references
2. Use compile-time type registration with concrete types
3. Leverage Crystal's macro system for type safety
4. Create a polymorphic loader that doesn't require runtime type resolution

### Solution Architecture

#### 1. Type Registry Redesign
Instead of a runtime hash, use compile-time registration with a macro that generates a case statement:

```crystal
module Granite::Polymorphic
  # Each model registers itself at compile time
  macro register_polymorphic_type(name, klass)
    {% Granite::Polymorphic::REGISTERED_TYPES[name] = klass %}
  end
  
  # Generate a loader method at compile time
  macro finished
    def self.load_polymorphic(type_name : String, id : Int64)
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name.stringify}}
        {{klass}}.find(id)
      {% end %}
      else
        nil
      end
    end
  end
end
```

#### 2. Polymorphic Association Redesign
Create a PolymorphicProxy that handles the loading without exposing abstract types:

```crystal
struct PolymorphicProxy
  def initialize(@type : String?, @id : Int64?)
  end
  
  def load
    return nil unless @type && @id
    Granite::Polymorphic.load_polymorphic(@type, @id)
  end
  
  def reload
    load
  end
end
```

#### 3. Belongs To Polymorphic Macro
Refactor to return a proxy instead of trying to load directly:

```crystal
macro belongs_to_polymorphic(name, **options)
  # ... column definitions ...
  
  def {{name.id}}_proxy
    PolymorphicProxy.new(@{{type_column.id}}, @{{foreign_key.id}})
  end
  
  def {{name.id}}
    {{name.id}}_proxy.load
  end
  
  def {{name.id}}=(record)
    if record.nil?
      @{{foreign_key.id}} = nil
      @{{type_column.id}} = nil
    else
      @{{foreign_key.id}} = record.primary_key_value.as(Int64)
      @{{type_column.id}} = record.class.name
    end
  end
end
```

#### 4. Has Many/One Polymorphic Macros
These already use concrete types, so they need minimal changes:

```crystal
macro has_many_polymorphic(name, poly_as, **options)
  # Current implementation is mostly fine
  # Just ensure the target class is concrete
  def {{method_name.id}}
    {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value)
  end
end
```

## Implementation Steps

1. Create new polymorphic module with compile-time type registry
2. Implement PolymorphicProxy struct
3. Update belongs_to_polymorphic macro to use proxy
4. Ensure has_many/has_one work with new system
5. Update model inheritance to auto-register types
6. Fix all specs to work with new API

## Benefits

1. **Type Safety**: All types are known at compile time
2. **No Abstract Instantiation**: We never try to instantiate Granite::Base
3. **Performance**: Case statement is optimized by compiler
4. **Clarity**: Clear separation between proxy and actual loading

## Migration Path

Existing code using polymorphic associations will need minimal changes:
- The API remains mostly the same
- Internal implementation is what changes
- Auto-registration ensures models work automatically