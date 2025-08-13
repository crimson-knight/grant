# Serialized Columns

Grant provides a powerful `serialized_column` macro for storing structured data in JSON, JSONB, or YAML database columns with full type safety and dirty tracking support.

## Overview

The `serialized_column` macro allows you to:
- Store complex Crystal objects in database columns
- Maintain type safety with automatic serialization/deserialization
- Track changes in nested objects (dirty tracking)
- Support JSON, JSONB, and YAML formats
- Work seamlessly with different database adapters

## Basic Usage

```crystal
# Define a settings class
class UserSettings
  include JSON::Serializable
  include Grant::SerializedObject  # For dirty tracking
  
  property theme : String = "light"
  property notifications_enabled : Bool = true
  property items_per_page : Int32 = 20
end

# Use in your model
class User < Grant::Base
  column id : Int64, primary: true
  column name : String
  
  # Define a serialized column
  serialized_column :settings, UserSettings, format: :json
end

# Usage
user = User.new(name: "John")
user.settings = UserSettings.new(theme: "dark", notifications_enabled: false)
user.save

# Access the settings object
user.settings.theme # => "dark"
user.settings.notifications_enabled # => false

# Modify settings
user.settings.items_per_page = 50
user.settings_changed? # => true
user.save
```

## Serialization Formats

### JSON (MySQL, PostgreSQL)
```crystal
serialized_column :settings, UserSettings, format: :json
```

### JSONB (PostgreSQL binary JSON)
```crystal
serialized_column :preferences, UserPreferences, format: :jsonb
```

### YAML
```crystal
serialized_column :config, AppConfig, format: :yaml
```

## Dirty Tracking

Serialized columns fully integrate with Grant's dirty tracking system:

```crystal
# Check if the serialized column has changed
user.settings_changed? # => false

# Modify nested object
user.settings.theme = "dark"
user.settings_changed? # => true
user.settings.changed? # => true (on the nested object)

# See what changed
user.settings.changes # => {"theme" => {"light", "dark"}}

# Save clears dirty state
user.save
user.settings_changed? # => false
user.settings.changed? # => false
```

## Advanced Example

```crystal
# Complex nested structure
class NotificationSettings
  include JSON::Serializable
  include Grant::SerializedObject
  
  property email : Bool = true
  property push : Bool = true
  property sms : Bool = false
  property frequency : String = "immediate"
end

class UserPreferences
  include JSON::Serializable
  include Grant::SerializedObject
  
  property language : String = "en"
  property timezone : String = "UTC"
  property notifications : NotificationSettings = NotificationSettings.new
  property beta_features : Array(String) = [] of String
end

class User < Grant::Base
  serialized_column :preferences, UserPreferences, format: :jsonb
end

# Usage
user = User.new
user.preferences = UserPreferences.new
user.preferences.language = "es"
user.preferences.notifications.email = false
user.preferences.beta_features = ["new_ui", "advanced_search"]
user.save
```

## Database Column Types

The serialized data is stored as strings in the database. Make sure your columns are the appropriate type:

### PostgreSQL
```sql
CREATE TABLE users (
  settings JSON,      -- For format: :json
  preferences JSONB,  -- For format: :jsonb
  config TEXT        -- For format: :yaml
);
```

### MySQL
```sql
CREATE TABLE users (
  settings JSON,     -- For format: :json (MySQL 5.7+)
  preferences JSON,  -- JSONB treated as JSON in MySQL
  config TEXT       -- For format: :yaml
);
```

### SQLite
```sql
CREATE TABLE users (
  settings TEXT,     -- All formats stored as TEXT
  preferences TEXT,
  config TEXT
);
```

## Requirements for Serializable Classes

Your serializable classes must:

1. Include the appropriate serialization module:
   - `JSON::Serializable` for JSON/JSONB columns
   - `YAML::Serializable` for YAML columns

2. Include `Grant::SerializedObject` for dirty tracking support

3. Have a default constructor or provide default values for all properties

## Performance Considerations

- Objects are deserialized lazily on first access
- Deserialized objects are cached until the column value changes
- Changes to nested objects are tracked efficiently
- Serialization happens automatically before save

## Best Practices

1. **Keep serialized objects focused** - Don't store entire application state
2. **Use appropriate formats**:
   - JSON/JSONB for API data, settings, configurations
   - YAML for human-readable configurations
3. **Include defaults** - Always provide sensible defaults for properties
4. **Version your schemas** - Consider adding version fields for migration support
5. **Index JSONB columns** - PostgreSQL supports indexes on JSONB fields

## Limitations

- Serialized columns cannot be queried directly in database queries
- Changes to the serializable class structure require data migration
- Large objects can impact performance
- Not suitable for data that needs to be indexed or joined

## Example: User Settings with Versioning

```crystal
class UserSettingsV2
  include JSON::Serializable
  include Grant::SerializedObject
  
  property version : Int32 = 2
  property theme : String = "light"
  property notifications_enabled : Bool = true
  property items_per_page : Int32 = 20
  property new_feature : String = "default"
  
  # Migration logic
  def self.from_json(json : String)
    data = JSON.parse(json)
    version = data["version"]?.try(&.as_i) || 1
    
    if version < 2
      # Migrate v1 to v2
      data["new_feature"] = "default"
      data["version"] = 2
    end
    
    new(data.to_json)
  end
end
```