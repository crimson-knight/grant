# Dirty tracking functionality is built directly into Grant::Base and Grant::Columns.
#
# This module serves as documentation for the dirty tracking API.
#
# ## Overview
#
# Dirty tracking allows you to track changes to model attributes, providing methods to:
# - Check if attributes have changed
# - Access original values before changes
# - See what was changed in the last save
# - Restore attributes to their original values
#
# ## Usage
#
# ```
# user = User.find!(1)
# user.name # => "John"
# 
# user.name = "Jane"
# user.changed? # => true
# user.name_changed? # => true
# user.name_was # => "John"
# user.name_change # => {"John", "Jane"}
# 
# user.save
# user.changed? # => false
# user.previous_changes # => {"name" => {"John", "Jane"}}
# ```
#
# ## Implementation
#
# The dirty tracking implementation consists of:
# 
# 1. **Storage** - Three hashes track attribute states:
#    - `@original_attributes` - Values when record was loaded/saved
#    - `@changed_attributes` - Current changes with {original, new} tuples
#    - `@previous_changes` - Changes from the last save operation
#
# 2. **Column Macro Integration** - The `column` macro automatically generates:
#    - Custom setters that track changes
#    - Per-attribute dirty methods (`<attr>_changed?`, `<attr>_was`, etc.)
#
# 3. **Lifecycle Integration** - Hooks into save operations to:
#    - Clear dirty state after successful save
#    - Capture current values as new originals
#    - Store previous changes for post-save access
#
# See `Grant::Base` for the core dirty tracking methods and `Grant::Columns` 
# for the per-attribute method generation.
module Grant::Dirty
  # This module is intentionally empty as dirty tracking is integrated
  # directly into Grant::Base and Grant::Columns for better performance
  # and JSON/YAML serialization compatibility.
end