# Eager Loading TODO

## Current Status

The eager loading API is implemented and working:
- `includes`, `preload`, and `eager_load` methods create proper query builders
- Query builders track associations to be loaded
- The select method calls AssociationLoader

## Missing Implementation

### 1. AssociationLoader.get_association_metadata
The method that retrieves association metadata from models is not implemented. It currently returns nil, preventing any associations from being loaded.

This method needs to:
- Access the model's association metadata (stored by association macros)
- Return a NamedTuple with type, foreign_key, primary_key, target_class, etc.

### 2. Association Metadata Storage
Association macros need to store metadata in a way that AssociationLoader can access:
- Each association should store its configuration
- Metadata should be accessible at runtime
- Should include all necessary information for loading

### 3. Class Lookup
The `get_class_from_name` method needs implementation to:
- Convert string class names to actual class references
- Handle namespaced classes
- Provide proper error messages for missing classes

### 4. Association Loading Logic
While the structure is there, the actual loading needs:
- Proper SQL generation for each association type
- Handling of polymorphic associations
- Support for through associations
- Proper assignment of loaded data to records

## Test Coverage

The spec correctly tests:
- API functionality (methods return query builders)
- Association tracking in query builders
- Expected behavior of loaded associations

But cannot test actual loading until implementation is complete.

## Recommendation

This is a significant feature that requires:
1. Modification of association macros to store metadata
2. Implementation of metadata retrieval
3. Proper class resolution system
4. Extensive testing with real database queries

Consider implementing in phases:
1. Start with simple belongs_to
2. Add has_one and has_many
3. Add through associations
4. Add polymorphic support