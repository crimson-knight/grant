require "../../spec_helper"
require "json"

class StoreSpecSettings
  include JSON::Serializable

  class_property parse_count = 0

  property theme : String = "light"
  property notifications : Bool = true
  property volume : Int32 = 5
  property locale : String? = nil

  def initialize
  end

  def self.new(pull : JSON::PullParser)
    @@parse_count += 1
    previous_def
  end
end

class StoreSpecUser < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table store_spec_users

  column id : Int64, primary: true
  column name : String?
  serialized_column :settings, StoreSpecSettings
  store_accessor :settings, theme : String = "light", notifications : Bool = true, volume : Int32 = 5, locale : String?
end

class StoreSpecPrefixed < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table store_spec_users

  column id : Int64, primary: true
  column name : String?
  serialized_column :settings, StoreSpecSettings
  store_accessor :settings, theme : String = "light", prefix: true
  store_accessor :settings, volume : Int32 = 5, suffix: :level
end

describe "store_accessor" do
  before_all do
    id_column = case CURRENT_ADAPTER
                when "pg"    then "BIGSERIAL PRIMARY KEY"
                when "mysql" then "BIGINT AUTO_INCREMENT PRIMARY KEY"
                else              "INTEGER PRIMARY KEY AUTOINCREMENT"
                end
    StoreSpecUser.exec("DROP TABLE IF EXISTS store_spec_users")
    StoreSpecUser.exec("CREATE TABLE store_spec_users (id #{id_column}, name VARCHAR(255), _serialized_settings TEXT)")
  end

  before_each { StoreSpecUser.clear }

  it "reads defaults without building the object" do
    user = StoreSpecUser.new
    user.theme.should eq("light")
    user.notifications.should be_true
    user.notifications?.should be_true
    user.volume.should eq(5)
    user.locale.should be_nil
    user.settings.should be_nil
  end

  it "writes typed keys and persists them" do
    user = StoreSpecUser.new(name: "a")
    user.theme = "dark"
    user.volume = 11
    user.locale = "en"
    user.save!
    loaded = StoreSpecUser.find!(user.id)
    loaded.theme.should eq("dark")
    loaded.volume.should eq(11)
    loaded.locale.should eq("en")
    loaded.notifications.should be_true
  end

  it "tracks dirty state per key" do
    user = StoreSpecUser.create!(name: "d")
    user.theme_changed?.should be_false
    user.theme = "dark"
    user.theme_changed?.should be_true
    user.theme_was.should eq("light")
    user.volume_changed?.should be_false
    user.settings_changed?.should be_true
    user.changed?.should be_true

    user.theme = "light"
    user.theme_changed?.should be_false

    user.theme = "dark"
    user.save!
    user.theme_changed?.should be_false
    user.theme_was.should eq("dark")
    user.settings_changed?.should be_false
  end

  it "keeps the record dirty when only a store key changed" do
    user = StoreSpecUser.create!(name: "k")
    loaded = StoreSpecUser.find!(user.id)
    loaded.volume = 9
    loaded.changed?.should be_true
    loaded.save!
    StoreSpecUser.find!(user.id).volume.should eq(9)
  end

  it "does not deserialize the whole column again for each key" do
    user = StoreSpecUser.create!(name: "p")
    user.theme = "dark"
    user.save!
    loaded = StoreSpecUser.find!(user.id)
    StoreSpecSettings.parse_count = 0
    10.times do
      loaded.theme
      loaded.volume
      loaded.notifications
    end
    StoreSpecSettings.parse_count.should eq(1)
    loaded.theme = "blue"
    loaded.volume = 3
    loaded.theme
    StoreSpecSettings.parse_count.should eq(1)
    loaded.settings.should be(loaded.settings)
  end

  it "supports prefix and suffix names" do
    user = StoreSpecPrefixed.new
    user.settings_theme.should eq("light")
    user.settings_theme = "dark"
    user.settings_theme_changed?.should be_true
    user.volume_level = 2
    user.volume_level.should eq(2)
    user.settings.try(&.theme).should eq("dark")
  end
end
