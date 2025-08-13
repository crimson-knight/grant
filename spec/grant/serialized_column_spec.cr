require "../spec_helper"
require "json"
require "yaml"

# Test classes for serialization
class UserSettings
  include JSON::Serializable
  include YAML::Serializable
  include Grant::SerializedObject
  
  getter theme : String = "light"
  getter notifications_enabled : Bool = true
  getter items_per_page : Int32 = 20
  
  track_changes_for theme, notifications_enabled, items_per_page
  
  def initialize(@theme = "light", @notifications_enabled = true, @items_per_page = 20)
    @_changed = false
    @_original_values = {} of String => Tuple(String, String)
  end
end

class UserPreferences
  include JSON::Serializable
  include YAML::Serializable
  include Grant::SerializedObject
  
  property language : String = "en"
  property timezone : String = "UTC"
  property beta_features : Array(String) = [] of String
  
  track_changes_for language, timezone
  
  def initialize(@language = "en", @timezone = "UTC", @beta_features = [] of String)
    @_changed = false
    @_original_values = {} of String => Tuple(String, String)
  end
end

class AppConfig
  include JSON::Serializable
  include YAML::Serializable
  include Grant::SerializedObject
  
  property debug_mode : Bool = false
  property log_level : String = "info"
  property api_endpoints : Hash(String, String) = {} of String => String
  
  track_changes_for log_level
  
  def initialize(@debug_mode = false, @log_level = "info", @api_endpoints = {} of String => String)
    @_changed = false
    @_original_values = {} of String => Tuple(String, String)
  end
  
  # Manual tracking for complex types
  def debug_mode=(value : Bool)
    if @debug_mode != value
      _track_change("debug_mode", @debug_mode.to_s, value.to_s)
    end
    @debug_mode = value
  end
end

{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}

  class SerializedUser < Grant::Base
    connection {{ adapter_literal }}
    table serialized_users
    
    column id : Int64, primary: true
    column name : String?
    
    serialized_column :settings, UserSettings, format: :json
    serialized_column :preferences, UserPreferences, format: :jsonb
    serialized_column :config, AppConfig, format: :yaml
    
    timestamps
  end
{% end %}

# Setup table
SerializedUser.exec("DROP TABLE IF EXISTS serialized_users")

case CURRENT_ADAPTER
when "sqlite"
  SerializedUser.exec(<<-SQL)
    CREATE TABLE serialized_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      _serialized_settings TEXT,
      _serialized_preferences TEXT,
      _serialized_config TEXT,
      created_at TEXT,
      updated_at TEXT
    )
  SQL
when "pg"
  SerializedUser.exec(<<-SQL)
    CREATE TABLE serialized_users (
      id BIGSERIAL PRIMARY KEY,
      name VARCHAR,
      _serialized_settings JSON,
      _serialized_preferences JSONB,
      _serialized_config TEXT,
      created_at TIMESTAMP,
      updated_at TIMESTAMP
    )
  SQL
when "mysql"
  SerializedUser.exec(<<-SQL)
    CREATE TABLE serialized_users (
      id BIGINT PRIMARY KEY AUTO_INCREMENT,
      name VARCHAR(255),
      _serialized_settings JSON,
      _serialized_preferences JSON,
      _serialized_config TEXT,
      created_at TIMESTAMP,
      updated_at TIMESTAMP
    )
  SQL
end

describe Grant::SerializedColumn do
  describe "JSON serialization" do
    it "serializes and deserializes objects" do
      user = SerializedUser.new(name: "John")
      settings = UserSettings.new(theme: "dark", notifications_enabled: false, items_per_page: 50)
      
      user.settings = settings
      user.save
      
      # Reload to test deserialization
      reloaded = SerializedUser.find!(user.id)
      reloaded.settings.should_not be_nil
      reloaded.settings.not_nil!.theme.should eq("dark")
      reloaded.settings.not_nil!.notifications_enabled.should eq(false)
      reloaded.settings.not_nil!.items_per_page.should eq(50)
    end
    
    it "handles nil values" do
      user = SerializedUser.new(name: "Jane")
      user.settings.should be_nil
      user.save
      
      reloaded = SerializedUser.find!(user.id)
      reloaded.settings.should be_nil
    end
  end
  
  describe "JSONB serialization" do
    it "works the same as JSON" do
      user = SerializedUser.new(name: "Bob")
      prefs = UserPreferences.new(
        language: "es",
        timezone: "America/New_York",
        beta_features: ["new_ui", "dark_mode"]
      )
      
      user.preferences = prefs
      user.save
      
      reloaded = SerializedUser.find!(user.id)
      reloaded.preferences.should_not be_nil
      reloaded.preferences.not_nil!.language.should eq("es")
      reloaded.preferences.not_nil!.timezone.should eq("America/New_York")
      reloaded.preferences.not_nil!.beta_features.should eq(["new_ui", "dark_mode"])
    end
  end
  
  describe "YAML serialization" do
    it "serializes complex objects" do
      user = SerializedUser.new(name: "Alice")
      config = AppConfig.new(
        debug_mode: true,
        log_level: "debug",
        api_endpoints: {
          "users" => "https://api.example.com/users",
          "posts" => "https://api.example.com/posts"
        }
      )
      
      user.config = config
      user.save
      
      reloaded = SerializedUser.find!(user.id)
      reloaded.config.should_not be_nil
      reloaded.config.not_nil!.debug_mode.should eq(true)
      reloaded.config.not_nil!.log_level.should eq("debug")
      reloaded.config.not_nil!.api_endpoints["users"].should eq("https://api.example.com/users")
    end
  end
  
  describe "dirty tracking" do
    it "tracks changes in nested objects" do
      user = SerializedUser.create(name: "Dave")
      settings = UserSettings.new
      user.settings = settings
      user.save
      
      # Modify nested object
      user.settings.not_nil!.theme = "dark"
      user.settings_changed?.should be_true
      user.settings.not_nil!.changed?.should be_true
      
      user.save
      
      # After save, changes should be reset
      user.settings_changed?.should be_false
      user.settings.not_nil!.changed?.should be_false
    end
    
    it "tracks multiple changes" do
      settings = UserSettings.new
      settings.theme = "dark"
      settings.notifications_enabled = false
      
      changes = settings.changes
      changes.size.should eq(2)
      changes["theme"].should eq({"light", "dark"})
      changes["notifications_enabled"].should eq({"true", "false"})
    end
    
    it "propagates changes to parent model" do
      user = SerializedUser.new(name: "Eve")
      settings = UserSettings.new
      user.settings = settings
      user.save
      
      # Clear any dirty state
      user.settings_changed?.should be_false
      
      # Change nested object
      user.settings.not_nil!.items_per_page = 100
      user.settings_changed?.should be_true
    end
  end
  
  describe "caching behavior" do
    it "caches deserialized objects" do
      user = SerializedUser.create(name: "Frank")
      user.settings = UserSettings.new(theme: "dark")
      user.save
      
      # First access deserializes
      settings1 = user.settings
      # Second access should return same object
      settings2 = user.settings
      
      settings1.should be(settings2) # Same object reference
    end
    
    it "clears cache when setting raw value" do
      user = SerializedUser.create(name: "Grace")
      user.settings = UserSettings.new(theme: "dark")
      user.save
      
      # Get cached object
      settings1 = user.settings
      
      # Set raw JSON
      user.settings = %({"theme":"light","notifications_enabled":true,"items_per_page":20})
      
      # Should return new object
      settings2 = user.settings
      settings1.should_not be(settings2)
      settings2.not_nil!.theme.should eq("light")
    end
  end
end