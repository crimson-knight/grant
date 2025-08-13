require "../spec_helper"

# Test model with normalization
class NormalizedUser < Grant::Base
  include Grant::Normalization

  connection {{ CURRENT_ADAPTER }}
  table normalized_users

  column id : Int64, primary: true
  column email : String?
  column phone : String?
  column username : String?
  column website : String?
  column name : String?

  # Simple normalizations
  normalizes :email do |value|
    value.downcase.strip
  end

  normalizes :phone do |value|
    value.gsub(/\D/, "")
  end

  # More complex normalization
  normalizes :username do |value|
    value.downcase.gsub(/[^a-z0-9_]/, "")
  end

  # Conditional normalization
  normalizes :website, if: :website_present? do |value|
    value.starts_with?("http") ? value : "https://#{value}"
  end

  # Trim whitespace from name
  normalizes :name do |value|
    value.strip
  end

  def website_present?
    !website.nil? && !website.try(&.empty?)
  end
end

# Setup table
NormalizedUser.exec("DROP TABLE IF EXISTS normalized_users")

case CURRENT_ADAPTER
when "sqlite"
  NormalizedUser.exec(<<-SQL)
    CREATE TABLE normalized_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT,
      phone TEXT,
      username TEXT,
      website TEXT,
      name TEXT,
      created_at TEXT,
      updated_at TEXT
    )
  SQL
when "pg"
  NormalizedUser.exec(<<-SQL)
    CREATE TABLE normalized_users (
      id BIGSERIAL PRIMARY KEY,
      email VARCHAR,
      phone VARCHAR,
      username VARCHAR,
      website VARCHAR,
      name VARCHAR,
      created_at TIMESTAMP,
      updated_at TIMESTAMP
    )
  SQL
when "mysql"
  NormalizedUser.exec(<<-SQL)
    CREATE TABLE normalized_users (
      id BIGINT PRIMARY KEY AUTO_INCREMENT,
      email VARCHAR(255),
      phone VARCHAR(255),
      username VARCHAR(255),
      website VARCHAR(255),
      name VARCHAR(255),
      created_at TIMESTAMP,
      updated_at TIMESTAMP
    )
  SQL
end

describe Grant::Normalization do
  describe "basic normalization" do
    it "normalizes email to lowercase and strips whitespace" do
      user = NormalizedUser.new
      user.email = "  JOHN@EXAMPLE.COM  "
      user.valid?
      user.email.should eq("john@example.com")
    end

    it "removes non-digits from phone numbers" do
      user = NormalizedUser.new
      user.phone = "(555) 123-4567"
      user.valid?
      user.phone.should eq("5551234567")
    end

    it "normalizes usernames" do
      user = NormalizedUser.new
      user.username = "John_Doe!"
      user.valid?
      user.username.should eq("john_doe")
    end

    it "strips whitespace from names" do
      user = NormalizedUser.new
      user.name = "  John Doe  "
      user.valid?
      user.name.should eq("John Doe")
    end
  end

  describe "conditional normalization" do
    it "adds https:// to websites when condition is met" do
      user = NormalizedUser.new
      user.website = "example.com"
      user.valid?
      user.website.should eq("https://example.com")
    end

    it "does not modify websites that already have protocol" do
      user = NormalizedUser.new
      user.website = "http://example.com"
      user.valid?
      user.website.should eq("http://example.com")
    end

    it "does not normalize when condition is not met" do
      user = NormalizedUser.new
      user.website = nil
      user.valid?
      user.website.should be_nil
    end
  end

  describe "with nil values" do
    it "handles nil values gracefully" do
      user = NormalizedUser.new
      user.email = nil
      user.phone = nil
      user.username = nil
      user.valid?

      user.email.should be_nil
      user.phone.should be_nil
      user.username.should be_nil
    end
  end

  describe "persistence" do
    it "normalizes before saving" do
      user = NormalizedUser.new
      user.email = "  TEST@EXAMPLE.COM  "
      user.phone = "(123) 456-7890"
      user.save

      user.email.should eq("test@example.com")
      user.phone.should eq("1234567890")

      # Reload and verify
      reloaded = NormalizedUser.find!(user.id)
      reloaded.email.should eq("test@example.com")
      reloaded.phone.should eq("1234567890")
    end
  end

  describe "dirty tracking integration" do
    it "tracks changes after normalization" do
      user = NormalizedUser.create(email: "old@example.com")
      user.email = "  NEW@EXAMPLE.COM  "
      user.valid?

      user.email.should eq("new@example.com")
      user.email_changed?.should be_true
      user.email_was.should eq("old@example.com")
    end

    it "does not mark as changed if normalization returns to original value" do
      user = NormalizedUser.create(email: "test@example.com")
      user.email = "  TEST@EXAMPLE.COM  "
      user.email_changed?.should be_true

      user.valid?
      user.email.should eq("test@example.com")
      user.email_changed?.should be_false # Back to original value
    end

    it "marks as changed when normalization actually changes the value" do
      user = NormalizedUser.new
      user.email = "  TEST@EXAMPLE.COM  "
      user.email_changed?.should be_false # New record, no changes yet

      user.valid?
      user.email.should eq("test@example.com")
      # For new records, normalization shouldn't mark as changed
      user.email_changed?.should be_false
    end
  end

  describe "opt-out of normalization" do
    it "skips normalization when skip_normalization is true" do
      user = NormalizedUser.new
      user.email = "  JOHN@EXAMPLE.COM  "
      user.valid?(skip_normalization: true)
      user.email.should eq("  JOHN@EXAMPLE.COM  ") # Unchanged
    end

    it "preserves changed status when skipping normalization" do
      user = NormalizedUser.create(email: "test@example.com")
      user.email = "  TEST@EXAMPLE.COM  "

      user.valid?(skip_normalization: true)
      user.email.should eq("  TEST@EXAMPLE.COM  ")
      user.email_changed?.should be_true
    end

    it "normalizes on subsequent validation after skipping" do
      user = NormalizedUser.new
      user.email = "  JOHN@EXAMPLE.COM  "

      # First validation with skip
      user.valid?(skip_normalization: true)
      user.email.should eq("  JOHN@EXAMPLE.COM  ")

      # Second validation without skip
      user.valid?
      user.email.should eq("john@example.com")
    end
  end
end
