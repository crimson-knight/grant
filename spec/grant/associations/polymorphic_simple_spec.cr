require "../../spec_helper"

# First, let's test a simpler version of polymorphic associations
describe "Grant::Associations::Polymorphic - Basic Implementation" do
  describe "polymorphic columns" do
    it "creates the necessary columns" do
      TestComment.fields.includes?("commentable_id").should be_true
      TestComment.fields.includes?("commentable_type").should be_true
    end
  end

  describe "type registration" do
    it "checks if types are registered" do
      # Types are auto-registered via inherited macro
      Grant::Polymorphic.registered_type?("TestPost").should be_true
      Grant::Polymorphic.registered_type?("TestBook").should be_true
      Grant::Polymorphic.registered_type?("NonExistent").should be_false
    end
  end
  
  describe "polymorphic proxy" do
    it "creates a proxy for lazy loading" do
      proxy = Grant::Polymorphic::PolymorphicProxy.new("TestPost", 123_i64)
      proxy.type.should eq("TestPost")
      proxy.id.should eq(123_i64)
      proxy.present?.should be_true
      
      nil_proxy = Grant::Polymorphic::PolymorphicProxy.new(nil, nil)
      nil_proxy.present?.should be_false
    end
  end
end

# Simple test models to verify compilation
{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}
  
  class TestComment < Grant::Base
    connection {{ adapter_literal }}
    table test_comments

    column id : Int64, primary: true
    column content : String

    # Polymorphic association
    belongs_to :commentable, polymorphic: true, optional: true
  end

  class TestPost < Grant::Base
    connection {{ adapter_literal }}
    table test_posts

    column id : Int64, primary: true
    column name : String
  end

  class TestBook < Grant::Base
    connection {{ adapter_literal }}
    table test_books

    column id : Int64, primary: true
    column name : String
  end
{% end %}
