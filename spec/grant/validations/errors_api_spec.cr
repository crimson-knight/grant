require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02eProfile < Grant::Base
    connection {{ adapter_literal }}
    table v02e_profiles

    column id : Int64, primary: true
    column first_name : String?
    column age : Int32?

    validates_presence_of :first_name
    validates_length_of :first_name, minimum: 3, allow_nil: true
    validates_numericality_of :age, greater_than: 17, allow_nil: true
  end
{% end %}

describe "Grant::Errors API (ActiveRecord semantics)" do
  before_all do
    V02eProfile.migrator.drop_and_create
  end

  describe "of_type" do
    it "matches by type symbol, not by message" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank", type: :blank)
      errors.of_type(:name, :blank).should be_true
      errors.of_type(:name, :invalid).should be_false
      errors.of_type?(:name, :blank).should be_true
    end

    it "matches the options of the error when given" do
      errors = Grant::Errors.new
      errors.add(:name, :too_short, count: 3)
      errors.of_type(:name, :too_short, count: 3).should be_true
      errors.of_type(:name, :too_short, count: 4).should be_false
    end

    it "keeps matching a String argument by message" do
      errors = Grant::Errors.new
      errors.add(:name, "is odd")
      errors.of_type(:name, "is odd").should be_true
      errors.has_message?(:name, "is odd").should be_true
      errors.has_message?(:name, "is even").should be_false
    end
  end

  describe "where" do
    it "filters by type and by options" do
      errors = Grant::Errors.new
      errors.add(:name, :too_short, count: 3)
      errors.add(:name, :too_short, count: 5)
      errors.add(:name, :blank)
      errors.add(:email, :blank)

      errors.where(:name).size.should eq(3)
      errors.where(:name, :too_short).size.should eq(2)
      errors.where(:name, :too_short, count: 5).size.should eq(1)
      errors.where(:name, :too_short, count: 5).first.options[:count].should eq(5)
      errors.where(:name, :invalid).should be_empty
      errors.where(:nobody).should be_empty
    end
  end

  describe "to_hash" do
    it "returns messages, or full messages with full_messages: true" do
      record = V02eProfile.new(first_name: "ab", age: 3)
      record.valid?.should be_false
      record.errors.to_hash.should eq({
        "first_name" => ["must be at least 3 characters"],
        "age"        => ["must be greater than 17"],
      })
      record.errors.to_hash(full_messages: true).should eq({
        "first_name" => ["First name must be at least 3 characters"],
        "age"        => ["Age must be greater than 17"],
      })
      record.errors.messages.should eq(record.errors.to_hash)
    end
  end

  describe "as_json and to_json" do
    it "serializes the ActiveRecord shape from as_json" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.add(:name, "is too short")
      errors.add(:base, "is bad")
      errors.as_json.should eq({"name" => ["can't be blank", "is too short"], "base" => ["is bad"]})
      errors.as_json(full_messages: true)["name"].should eq(["Name can't be blank", "Name is too short"])
      errors.as_json.to_json.should eq(%({"name":["can't be blank","is too short"],"base":["is bad"]}))
    end

    it "keeps to_json as the array of field/message objects" do
      errors = Grant::Errors.new
      errors.add(:name, "can't be blank")
      errors.to_json.should eq(%([{"field":"name","message":"can't be blank"}]))
    end
  end

  describe "extras" do
    it "reports added? for the exact error" do
      errors = Grant::Errors.new
      errors.add(:name, :too_short, count: 3)
      errors.added?(:name, :too_short, count: 3).should be_true
      errors.added?(:name, :too_short).should be_false # options must match exactly
      errors.added?(:name, :too_short, count: 4).should be_false
      errors.add(:age, :invalid)
      errors.added?(:age).should be_true # :invalid is the default type
      errors.add(:base, "custom")
      errors.added?(:base, "custom").should be_true
    end

    it "deletes by attribute, type and options and returns the messages" do
      errors = Grant::Errors.new
      errors.add(:name, :blank)
      errors.add(:name, :too_short, count: 3)
      errors.add(:email, :blank)

      errors.delete(:name, :too_short).should eq(["is too short (minimum is 3 characters)"])
      errors.size.should eq(2)
      errors.include?(:name).should be_true
      errors.delete(:name).should eq(["can't be blank"])
      errors.include?(:name).should be_false
      errors.attribute_names.should eq(["email"])
      errors.delete(:name).should be_empty
    end

    it "lists messages_for, counts by attribute and exposes the error objects" do
      errors = Grant::Errors.new
      errors.add(:name, :blank)
      errors.add(:name, :invalid)
      errors.add(:email, :blank)
      errors.messages_for(:name).should eq(["can't be blank", "is invalid"])
      errors.count(:name).should eq(2)
      errors.count(:nobody).should eq(0)
      errors.count.should eq(3)
      errors.objects.size.should eq(3)
      errors.objects.same?(errors.objects).should be_true
    end

    it "formats a full message for an attribute" do
      errors = Grant::Errors.new
      errors.full_message(:first_name, "is bad").should eq("First name is bad")
      errors.full_message(:base, "is bad").should eq("is bad")
    end

    it "keeps its attribute index right across adds, deletes and clears" do
      errors = Grant::Errors.new
      errors.add(:a, :blank)
      errors[:a].size.should eq(1) # builds the index
      errors.add(:a, :invalid)
      errors.add(:b, :blank)
      errors[:a].size.should eq(2)
      errors.attribute_names.should eq(["a", "b"])
      errors.group_by_attribute.keys.should eq(["a", "b"])
      errors.clear
      errors[:a].should be_empty
      errors.include?(:a).should be_false
    end

    it "removes duplicates with uniq!" do
      errors = Grant::Errors.new
      errors.add(:name, :blank)
      errors.add(:name, :blank)
      errors.add(:name, :too_short, count: 3)
      errors.add(:name, :too_short, count: 4)
      errors.uniq!
      errors.size.should eq(3)
    end
  end

  describe "copying between collections" do
    it "merge! copies the errors instead of sharing them" do
      source = Grant::Errors.new
      source.add(:name, "can't be blank", type: :blank)
      target = Grant::Errors.new
      target.merge!(source)

      target.size.should eq(1)
      target.first.same?(source.first).should be_false
      target.first.message = "changed"
      source.first.message.should eq("can't be blank")
    end

    it "import copies one error, optionally under another attribute" do
      source = Grant::Errors.new
      source.add(:street, :blank)
      target = Grant::Errors.new
      copy = target.import(source.first, attribute: "address.street")
      copy.attribute.should eq("address.street")
      target.of_type("address.street", :blank).should be_true
      source.first.attribute.should eq("street")
    end

    it "copy! replaces the errors with copies of another collection's" do
      source = Grant::Errors.new
      source.add(:name, :blank)
      target = Grant::Errors.new
      target.add(:old, :invalid)
      target.copy!(source)
      target.attribute_names.should eq(["name"])
      target.first.same?(source.first).should be_false
    end
  end
end
