require "../../spec_helper"

describe Grant::Errors do
  describe "#add" do
    it "adds an error with field and message" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.size.should eq(1)
      errors.first.field.should eq(:name)
      errors.first.message.should eq("can't be blank")
    end

    it "adds errors with string field names" do
      errors = Grant::Errors.new
      errors.add("email", "is invalid")
      errors.size.should eq(1)
      errors.first.field.should eq("email")
    end

    it "adds multiple errors for the same field" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:name, "is too short")
      errors.size.should eq(2)
    end

    it "adds error with default empty message" do
      errors = Grant::Errors.new
      errors.add(:name)
      errors.size.should eq(1)
      errors.first.message.should eq("")
    end
  end

  describe "#<<" do
    it "appends an Error object" do
      errors = Grant::Errors.new
      errors << Grant::Error.new(:name, "can't be blank")
      errors.size.should eq(1)
    end

    it "supports chaining multiple pushes" do
      errors = Grant::Errors.new
      errors << Grant::Error.new(:name, "can't be blank")
      errors << Grant::Error.new(:email, "is invalid")
      errors.size.should eq(2)
    end
  end

  describe "#[]" do
    it "returns messages for a field as symbol" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:name, "is too short")
      errors.add(:email, "is invalid")

      errors[:name].should eq(["can't be blank", "is too short"])
    end

    it "returns messages for a field as string" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")

      errors["name"].should eq(["can't be blank"])
    end

    it "returns empty array for field with no errors" do
      errors = Grant::Errors.new
      errors[:email].should eq([] of String)
    end

    it "returns messages matching symbol field stored as string" do
      errors = Grant::Errors.new
      errors.add("name", "can't be blank")
      errors[:name].should eq(["can't be blank"])
    end
  end

  describe "#[] with Int32 index" do
    it "returns error at index" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")
      errors[0].field.should eq(:name)
      errors[1].field.should eq(:email)
    end
  end

  describe "#full_messages" do
    it "returns formatted messages" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      messages = errors.full_messages
      messages.should contain("Name can't be blank")
      messages.should contain("Email is invalid")
    end

    it "returns message without prefix for :base errors" do
      errors = Grant::Errors.new
      errors.add(:base, "Record is invalid")

      errors.full_messages.should eq(["Record is invalid"])
    end

    it "returns empty array when no errors" do
      errors = Grant::Errors.new
      errors.full_messages.should eq([] of String)
    end
  end

  describe "#full_messages_for" do
    it "returns full messages for a specific field" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:name, "is too short")
      errors.add(:email, "is invalid")

      messages = errors.full_messages_for(:name)
      messages.size.should eq(2)
      messages.should contain("Name can't be blank")
      messages.should contain("Name is too short")
    end

    it "returns empty array for field with no errors" do
      errors = Grant::Errors.new
      errors.full_messages_for(:email).should eq([] of String)
    end
  end

  describe "#where" do
    it "returns Error objects for a field" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:name, "is too short")
      errors.add(:email, "is invalid")

      name_errors = errors.where(:name)
      name_errors.size.should eq(2)
      name_errors.all? { |e| e.field.to_s == "name" }.should be_true
    end

    it "returns empty array for field with no errors" do
      errors = Grant::Errors.new
      errors.where(:email).should eq([] of Grant::Error)
    end
  end

  describe "#of_type" do
    it "returns true when error with matching message exists" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")

      errors.of_type(:name, "can't be blank").should be_true
    end

    it "returns false when message doesn't match" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")

      errors.of_type(:name, "is too short").should be_false
    end

    it "returns false when field doesn't match" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")

      errors.of_type(:email, "can't be blank").should be_false
    end
  end

  describe "#include?" do
    it "returns true when field has errors" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")

      errors.include?(:name).should be_true
    end

    it "returns false when field has no errors" do
      errors = Grant::Errors.new
      errors.include?(:name).should be_false
    end

    it "works with string field" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")

      errors.include?("name").should be_true
    end
  end

  describe "#attribute_names" do
    it "returns unique field names with errors" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:name, "is too short")
      errors.add(:email, "is invalid")

      names = errors.attribute_names
      names.should eq(["name", "email"])
    end

    it "returns empty array when no errors" do
      errors = Grant::Errors.new
      errors.attribute_names.should eq([] of String)
    end
  end

  describe "#group_by_attribute" do
    it "groups errors by field name" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:name, "is too short")
      errors.add(:email, "is invalid")

      grouped = errors.group_by_attribute
      grouped.keys.should eq(["name", "email"])
      grouped["name"].size.should eq(2)
      grouped["email"].size.should eq(1)
    end
  end

  describe "#any? / #empty?" do
    it "returns false for any? when no errors" do
      errors = Grant::Errors.new
      errors.any?.should be_false
    end

    it "returns true for any? when errors exist" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.any?.should be_true
    end

    it "returns true for empty? when no errors" do
      errors = Grant::Errors.new
      errors.empty?.should be_true
    end

    it "returns false for empty? when errors exist" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.empty?.should be_false
    end
  end

  describe "#size / #count" do
    it "returns number of errors" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      errors.size.should eq(2)
      errors.count.should eq(2)
    end

    it "returns 0 when no errors" do
      errors = Grant::Errors.new
      errors.size.should eq(0)
      errors.count.should eq(0)
    end
  end

  describe "#first / #first? / #last / #last?" do
    it "returns first error" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      errors.first.field.should eq(:name)
      errors.first?.not_nil!.field.should eq(:name)
    end

    it "returns last error" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      errors.last.field.should eq(:email)
      errors.last?.not_nil!.field.should eq(:email)
    end

    it "returns nil for first? and last? when empty" do
      errors = Grant::Errors.new
      errors.first?.should be_nil
      errors.last?.should be_nil
    end
  end

  describe "#clear" do
    it "removes all errors" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      errors.clear
      errors.empty?.should be_true
      errors.size.should eq(0)
    end
  end

  describe "#to_hash" do
    it "returns hash of field names to message arrays" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:name, "is too short")
      errors.add(:email, "is invalid")

      hash = errors.to_hash
      hash.keys.should eq(["name", "email"])
      hash["name"].should eq(["can't be blank", "is too short"])
      hash["email"].should eq(["is invalid"])
    end

    it "returns empty hash when no errors" do
      errors = Grant::Errors.new
      errors.to_hash.should eq({} of String => Array(String))
    end
  end

  describe "#merge!" do
    it "merges errors from another collection" do
      errors1 = Grant::Errors.new
      errors1.add(:name, "can't be blank")

      errors2 = Grant::Errors.new
      errors2.add(:email, "is invalid")
      errors2.add(:age, "must be positive")

      errors1.merge!(errors2)
      errors1.size.should eq(3)
      errors1[:name].should eq(["can't be blank"])
      errors1[:email].should eq(["is invalid"])
      errors1[:age].should eq(["must be positive"])
    end
  end

  describe "#to_a" do
    it "returns a copy of the errors array" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      arr = errors.to_a
      arr.size.should eq(2)
      arr.should be_a(Array(Grant::Error))
    end
  end

  describe "#each (Enumerable)" do
    it "supports iteration with each" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      fields = [] of String
      errors.each { |e| fields << e.field.to_s }
      fields.should eq(["name", "email"])
    end

    it "supports map" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      fields = errors.map(&.field.to_s)
      fields.should eq(["name", "email"])
    end

    it "supports select" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      name_errors = errors.select { |e| e.field.to_s == "name" }
      name_errors.size.should eq(1)
    end
  end

  describe "#to_json" do
    it "serializes errors to JSON" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")

      json = errors.to_json
      json.should contain("\"field\"")
      json.should contain("\"name\"")
      json.should contain("\"message\"")
      json.should contain("can't be blank")
    end
  end

  describe "#to_s" do
    it "returns comma-separated full messages" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:email, "is invalid")

      errors.to_s.should eq("Name can't be blank, Email is invalid")
    end
  end

  describe "#any? with pattern" do
    it "matches error type using class pattern" do
      errors = Grant::Errors.new
      errors << Grant::ConversionError.new(:field, "bad value")

      errors.any?(Grant::ConversionError).should be_true
      errors.any?(Grant::Error).should be_true
    end

    it "returns false when no matching type" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")

      errors.any?(Grant::ConversionError).should be_false
    end
  end
end

describe "Grant::Errors integration with models" do
  it "model errors is a Grant::Errors instance" do
    article = ErrorsApiArticle.new
    article.errors.should be_a(Grant::Errors)
  end

  it "errors.add works on model" do
    article = ErrorsApiArticle.new
    article.errors.add(:base, "Something went wrong")
    article.errors.any?.should be_true
    article.errors[:base].should eq(["Something went wrong"])
  end

  it "validation populates errors with rich API" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.body = nil
    article.valid?.should be_false

    # Rich API
    article.errors.include?(:title).should be_true
    article.errors[:title].should eq(["can't be blank"])
    article.errors.full_messages.size.should be > 0
    article.errors.to_hash.keys.size.should be > 0
  end

  it "errors.where returns Error objects" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.body = nil
    article.valid?.should be_false

    title_errors = article.errors.where("title")
    title_errors.size.should eq(1)
    title_errors.first.message.should eq("can't be blank")
  end

  it "errors.of_type checks specific error" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.valid?.should be_false

    article.errors.of_type("title", "can't be blank").should be_true
    article.errors.of_type("title", "is too short").should be_false
  end

  it "errors.full_messages_for works with model" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.body = nil
    article.valid?.should be_false

    messages = article.errors.full_messages_for("title")
    messages.size.should eq(1)
    messages.first.should contain("Title")
  end

  it "errors.clear resets validation state" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.valid?.should be_false
    article.errors.any?.should be_true

    article.errors.clear
    article.errors.empty?.should be_true
  end

  it "errors.merge! combines errors from another model" do
    article1 = ErrorsApiArticle.new
    article1.title = nil
    article1.valid?

    article2 = ErrorsApiArticle.new
    article2.body = nil
    article2.title = "valid"
    article2.valid?

    article1.errors.merge!(article2.errors)
    article1.errors.include?("title").should be_true
    article1.errors.include?("body").should be_true
  end

  it "errors.to_hash provides structured access" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.body = nil
    article.valid?.should be_false

    hash = article.errors.to_hash
    hash.has_key?("title").should be_true
    hash["title"].should contain("can't be blank")
  end

  it "backward compatible: errors.each works" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.valid?.should be_false

    fields = [] of String
    article.errors.each { |e| fields << e.field.to_s }
    fields.should contain("title")
  end

  it "backward compatible: errors.map works" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.valid?.should be_false

    fields = article.errors.map(&.field.to_s)
    fields.should contain("title")
  end

  it "backward compatible: errors << Error.new works" do
    article = ErrorsApiArticle.new
    article.errors << Grant::Error.new(:custom, "custom error")
    article.errors.size.should eq(1)
    article.errors.first.field.should eq(:custom)
  end

  it "backward compatible: errors.first works" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.valid?.should be_false

    article.errors.first.field.should eq("title")
    article.errors.first.message.should eq("can't be blank")
  end

  it "backward compatible: errors.size works" do
    article = ErrorsApiArticle.new
    article.title = nil
    article.body = nil
    article.valid?.should be_false

    article.errors.size.should eq(2)
  end
end

# Test model for Errors API
class ErrorsApiArticle < Grant::Base
  connection sqlite
  table errors_api_articles

  column id : Int64, primary: true
  column title : String?
  column body : String?

  validates_presence_of :title
  validates_presence_of :body
end
