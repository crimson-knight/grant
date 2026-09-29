require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02oAccount < Grant::Base
    connection {{ adapter_literal }}
    table v02o_accounts

    column id : Int64, primary: true
    column first_name : String?
    column author_id : Int64?
  end
{% end %}

describe "Grant::Error object API" do
  describe "#full_message" do
    it "humanizes the attribute name" do
      Grant::Error.new(:first_name, "can't be blank").full_message.should eq("First name can't be blank")
      Grant::Error.new("first_name", "can't be blank").to_s.should eq("First name can't be blank")
    end

    it "drops an _id suffix like ActiveRecord's humanize" do
      Grant::Error.new(:author_id, "is missing").full_message.should eq("Author is missing")
    end

    it "returns the message alone for base errors given as Symbol or String" do
      Grant::Error.new(:base, "went wrong").full_message.should eq("went wrong")
      Grant::Error.new("base", "went wrong").full_message.should eq("went wrong")
    end

    it "uses the model's human_attribute_name once it belongs to a record" do
      Grant::I18n.store("attributes.v02o_account.first_name", "Given name")
      begin
        account = V02oAccount.new
        account.errors.add(:first_name, :blank)
        account.errors.first.full_message.should eq("Given name can't be blank")
        account.errors.full_messages.should eq(["Given name can't be blank"])
      ensure
        Grant::I18n.translator = Grant::I18n::DefaultTranslator.new
      end
    end

    it "is computed once per error" do
      error = Grant::Error.new(:name, "bad")
      error.full_message.same?(error.full_message).should be_true
    end
  end

  describe "accessors" do
    it "exposes attribute, type, raw_type, options and message" do
      error = Grant::Error.new(:name, :too_short, options: {:count => 3.as(Grant::Error::Value)})
      error.attribute.should eq("name")
      error.type.should eq(:too_short)
      error.raw_type.should eq(:too_short)
      error.options[:count].should eq(3)
      error.options?.should be_true
      error.message.should eq("is too short (minimum is 3 characters)")
      error.detail.should eq({:error => :too_short, :count => 3})
    end

    it "keeps the constructor with a message and an optional type" do
      error = Grant::Error.new(:name, "bad", :blank)
      error.message.should eq("bad")
      error.type.should eq(:blank)
      error.options?.should be_false
      Grant::Error.new(:name).message.should eq("")
    end
  end

  describe "#match?" do
    it "matches by attribute, type and options" do
      error = Grant::Error.new(:name, :too_short, options: {:count => 3.as(Grant::Error::Value)})
      error.match?(:name).should be_true
      error.match?("name").should be_true
      error.match?(:other).should be_false
      error.match?(:name, :too_short).should be_true
      error.match?(:name, :blank).should be_false
      error.match?(:name, :too_short, count: 3).should be_true
      error.match?(:name, :too_short, count: 4).should be_false
      error.match?(:name, :too_short, extra: 1).should be_false
    end

    it "matches a String type against the message" do
      error = Grant::Error.new(:name, "is odd")
      error.match?(:name, "is odd").should be_true
      error.match?(:name, "is even").should be_false
    end
  end

  describe "#strict_match?" do
    it "requires the options to be exactly the given ones" do
      error = Grant::Error.new(:name, :too_short, options: {:count => 3.as(Grant::Error::Value)})
      error.strict_match?(:name, :too_short, count: 3).should be_true
      error.strict_match?(:name, :too_short).should be_false
      error.strict_match?(:name, :too_short, count: 3, extra: 1).should be_false
      Grant::Error.new(:name, :blank).strict_match?(:name, :blank).should be_true
    end
  end

  describe "#copy" do
    it "duplicates the options and can move the error to another attribute" do
      error = Grant::Error.new(:name, :too_short, options: {:count => 3.as(Grant::Error::Value)})
      copy = error.copy(:title)
      copy.attribute.should eq("title")
      copy.options[:count] = 9
      error.options[:count].should eq(3)
    end
  end
end
