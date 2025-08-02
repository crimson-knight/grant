require "../spec_helper"

# Test model
class TestAuthor < Granite::Base
  connection {{ CURRENT_ADAPTER }}
  table test_authors
  
  column id : Int64, primary: true
  column name : String
  
  # Enable nested attributes with various options
  accepts_nested_attributes_for :posts, 
    allow_destroy: true,
    reject_if: :all_blank,
    limit: 3
    
  accepts_nested_attributes_for :profile,
    update_only: true
end

describe "Granite::NestedAttributes Simple V2" do
  describe "basic functionality" do
    it "generates attribute setter methods" do
      author = TestAuthor.new(name: "John")
      author.responds_to?(:posts_attributes=).should be_true
      author.responds_to?(:profile_attributes=).should be_true
    end
    
    it "stores array of attributes" do
      author = TestAuthor.new(name: "John")
      author.posts_attributes = [
        {title: "Post 1", content: "Content 1"},
        {title: "Post 2", content: "Content 2"}
      ]
      
      attrs = author.posts_nested_attributes
      attrs.should_not be_nil
      attrs.not_nil!.size.should eq(2)
      attrs.not_nil![0]["title"].should eq("Post 1")
      attrs.not_nil![1]["title"].should eq("Post 2")
    end
    
    it "stores single hash as array" do
      author = TestAuthor.new(name: "John")
      # Since profile has update_only, we need an id
      author.profile_attributes = {id: 1, bio: "Developer"}
      
      attrs = author.profile_nested_attributes
      attrs.should_not be_nil
      attrs.not_nil!.size.should eq(1)
      attrs.not_nil![0]["bio"].should eq("Developer")
    end
  end
  
  describe "reject_if option" do
    it "rejects all blank attributes" do
      author = TestAuthor.new(name: "John")
      author.posts_attributes = [
        {title: "Valid Post", content: "Content"},
        {title: "", content: ""},     # Should be rejected
        {title: "Another Valid", content: "More content"}
      ]
      
      attrs = author.posts_nested_attributes
      attrs.should_not be_nil
      attrs.not_nil!.size.should eq(2)
      attrs.not_nil![0]["title"].should eq("Valid Post")
      attrs.not_nil![1]["title"].should eq("Another Valid")
    end
    
    it "does not reject attributes with _destroy" do
      author = TestAuthor.new(name: "John")
      author.posts_attributes = [
        {id: 1, _destroy: true},  # Should not be rejected even though other fields are blank
        {title: "", content: ""}  # Should be rejected
      ]
      
      attrs = author.posts_nested_attributes
      attrs.should_not be_nil
      attrs.not_nil!.size.should eq(1)
      attrs.not_nil![0]["id"].should eq(1)
      attrs.not_nil![0]["_destroy"].should eq(true)
    end
  end
  
  describe "limit option" do
    it "raises error when exceeding limit" do
      author = TestAuthor.new(name: "John")
      
      expect_raises(ArgumentError, /Maximum 3 records/) do
        author.posts_attributes = [
          {title: "Post 1"},
          {title: "Post 2"},
          {title: "Post 3"},
          {title: "Post 4"}  # This exceeds the limit
        ]
      end
    end
    
    it "allows exactly the limit" do
      author = TestAuthor.new(name: "John")
      author.posts_attributes = [
        {title: "Post 1"},
        {title: "Post 2"},
        {title: "Post 3"}
      ]
      
      attrs = author.posts_nested_attributes
      attrs.should_not be_nil
      attrs.not_nil!.size.should eq(3)
    end
  end
  
  describe "update_only option" do
    it "ignores new records when update_only is true" do
      author = TestAuthor.new(name: "John")
      author.profile_attributes = {
        bio: "New bio",
        website: "example.com"
      }
      
      attrs = author.profile_nested_attributes
      attrs.should_not be_nil
      attrs.not_nil!.size.should eq(0)  # Should be empty because no id
    end
    
    it "accepts records with id when update_only is true" do
      author = TestAuthor.new(name: "John")
      author.profile_attributes = {
        id: 123,
        bio: "Updated bio"
      }
      
      attrs = author.profile_nested_attributes
      attrs.should_not be_nil
      attrs.not_nil!.size.should eq(1)
      attrs.not_nil![0]["id"].should eq(123)
      attrs.not_nil![0]["bio"].should eq("Updated bio")
    end
  end
  
  describe "mixed operations" do
    it "handles create, update, and destroy markers" do
      author = TestAuthor.new(name: "John")
      author.posts_attributes = [
        {id: 1, title: "Updated Post"},        # Update
        {id: 2, _destroy: true},               # Destroy
        {title: "New Post", content: "New"}    # Create
      ]
      
      attrs = author.posts_nested_attributes
      attrs.should_not be_nil
      attrs.not_nil!.size.should eq(3)
      
      # Check update
      attrs.not_nil![0]["id"].should eq(1)
      attrs.not_nil![0]["title"].should eq("Updated Post")
      
      # Check destroy
      attrs.not_nil![1]["id"].should eq(2)
      attrs.not_nil![1]["_destroy"].should eq(true)
      
      # Check create
      attrs.not_nil![2]["title"].should eq("New Post")
      attrs.not_nil![2]["id"]?.should be_nil
    end
  end
end