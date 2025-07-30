require "../../spec_helper"

# First, let's test a simpler version of polymorphic associations
describe "Granite::Associations::Polymorphic - Basic Implementation" do
  describe "polymorphic columns" do
    it "creates the necessary columns" do
      TestComment.fields.includes?("commentable_id").should be_true
      TestComment.fields.includes?("commentable_type").should be_true
    end
  end

  describe "type registration" do
    it "registers types in the polymorphic type map" do
      # Register test types
      Granite::Polymorphic.register_type("TestPost", TestPost)
      Granite::Polymorphic.register_type("TestBook", TestBook)
      
      Granite::Polymorphic.resolve_type("TestPost").should eq(TestPost)
      Granite::Polymorphic.resolve_type("TestBook").should eq(TestBook)
    end
  end
end

# Simple test models to verify compilation
class TestComment < Granite::Base
  connection sqlite
  table test_comments
  
  column id : Int64, primary: true
  column content : String
  
  # Polymorphic association
  belongs_to :commentable, polymorphic: true
end

class TestPost < Granite::Base
  connection sqlite
  table test_posts
  
  column id : Int64, primary: true
  column name : String
end

class TestBook < Granite::Base
  connection sqlite
  table test_books
  
  column id : Int64, primary: true
  column name : String
end