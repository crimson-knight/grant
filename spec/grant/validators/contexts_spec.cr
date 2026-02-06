require "../../spec_helper"

describe "Validation Contexts" do
  describe "on: :create" do
    it "runs create-only validators when context is :create" do
      record = ContextUser.new
      record.username = "john"
      record.email = "john@example.com"
      record.terms_accepted = true
      record.valid?(context: :create).should be_true

      record.terms_accepted = false
      record.valid?(context: :create).should be_false
      record.errors.first.field.should eq("terms_accepted")
    end

    it "skips create-only validators when context is :update" do
      record = ContextUser.new
      record.username = "john"
      record.email = "john@example.com"
      record.terms_accepted = false # would fail on create
      record.update_reason = "some reason" # required on update
      record.valid?(context: :update).should be_true
    end
  end

  describe "on: :update" do
    it "runs update-only validators when context is :update" do
      record = ContextUser.new
      record.username = "john"
      record.email = "john@example.com"
      record.terms_accepted = true
      record.update_reason = nil
      record.valid?(context: :update).should be_false
      record.errors.first.field.should eq("update_reason")
    end

    it "skips update-only validators when context is :create" do
      record = ContextUser.new
      record.username = "john"
      record.email = "john@example.com"
      record.terms_accepted = true
      record.update_reason = nil # would fail on update
      record.valid?(context: :create).should be_true
    end
  end

  describe "on: :save (default)" do
    it "runs save validators on both create and update context" do
      record = ContextUser.new
      record.username = nil
      record.email = "john@example.com"
      record.terms_accepted = true

      record.valid?(context: :create).should be_false
      record.errors.first.field.should eq("username")

      record.errors.clear
      record.valid?(context: :update).should be_false
      record.errors.first.field.should eq("username")
    end

    it "runs save validators when no context is specified" do
      record = ContextUser.new
      record.username = nil

      record.valid?.should be_false
      record.errors.first.field.should eq("username")
    end
  end

  describe "mixed contexts" do
    it "applies correct validators for each context" do
      record = ContextUser.new
      record.username = "john"
      record.email = "john@example.com"
      record.terms_accepted = true
      record.update_reason = "updating profile"

      # Should pass both contexts
      record.valid?(context: :create).should be_true
      record.valid?(context: :update).should be_true
    end

    it "running without context runs all validators" do
      record = ContextUser.new
      record.username = "john"
      record.email = "john@example.com"
      record.terms_accepted = false # create-only fails
      record.update_reason = nil    # update-only fails

      # Without context, all validators run
      record.valid?.should be_false
      error_fields = record.errors.map(&.field.to_s)
      error_fields.should contain("terms_accepted")
      error_fields.should contain("update_reason")
    end
  end

  describe "context with built-in validators" do
    it "validates_length_of with on: :update" do
      record = ContextPost.new
      record.title = "Hi"
      record.body = "Short"

      # On create, body length not checked
      record.valid?(context: :create).should be_true

      # On update, body must be >= 10 chars
      record.valid?(context: :update).should be_false
      record.errors.first.field.should eq("body")

      record.body = "This is long enough"
      record.valid?(context: :update).should be_true
    end

    it "validates_numericality_of with on: :create" do
      record = ContextPost.new
      record.title = "Hello"
      record.body = "Long enough content"
      record.priority = -1

      # On create, priority must be > 0
      record.valid?(context: :create).should be_false
      record.errors.first.field.should eq("priority")

      # On update, priority not validated
      record.errors.clear
      record.valid?(context: :update).should be_true
    end

    it "validates_inclusion_of with on: :update" do
      record = ContextPost.new
      record.title = "Hello"
      record.body = "Long enough content"
      record.priority = 1
      record.status = "invalid_status"

      # On create, status not validated
      record.valid?(context: :create).should be_true

      # On update, status must be in list
      record.valid?(context: :update).should be_false
      record.errors.first.field.should eq("status")
    end
  end
end

# Test models for validation contexts
class ContextUser < Grant::Base
  connection sqlite
  table context_users

  column id : Int64, primary: true
  column username : String?
  column email : String?
  column terms_accepted : Bool = false
  column update_reason : String?

  # Always required (default context: :save)
  validates_presence_of :username

  # Required only on create
  validate :terms_accepted, "must be accepted on signup", ->(record : ContextUser) {
    !!record.terms_accepted
  }, context: :create

  # Required only on update
  validates_presence_of :update_reason, on: :update
end

class ContextPost < Grant::Base
  connection sqlite
  table context_posts

  column id : Int64, primary: true
  column title : String?
  column body : String?
  column priority : Int32 = 1
  column status : String = "draft"

  # Always required
  validates_presence_of :title

  # Body length only checked on update
  validates_length_of :body, minimum: 10, on: :update

  # Priority only checked on create
  validates_numericality_of :priority, greater_than: 0, on: :create

  # Status only checked on update
  validates_inclusion_of :status, in: ["draft", "published", "archived"], on: :update
end
