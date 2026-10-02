require "../spec_helper"

# Test models
class NestedAttributeAuthor < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table nested_attribute_authors

  column id : Int64, primary: true
  column name : String
  timestamps

  has_many :posts, class_name: NestedAttributePost, foreign_key: :author_id
  has_one :profile, class_name: NestedAttributeProfile, foreign_key: :author_id

  # Enable nested attributes with explicit types
  accepts_nested_attributes_for posts : NestedAttributePost,
    allow_destroy: true,
    reject_if: :all_blank,
    limit: 5

  accepts_nested_attributes_for profile : NestedAttributeProfile

  # Enable automatic nested saves via callbacks
  enable_nested_saves
end

class NestedAttributePost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table nested_attribute_posts

  column id : Int64, primary: true
  column title : String
  column content : String?
  timestamps

  belongs_to author : NestedAttributeAuthor, foreign_key: author_id : Int64?, optional: true
  has_many :comments, class_name: NestedAttributeComment, foreign_key: :post_id

  validate :title, "Title cannot be blank" do |post|
    !post.title.blank?
  end

  accepts_nested_attributes_for comments : NestedAttributeComment,
    allow_destroy: true

  enable_nested_saves
end

class NestedAttributeComment < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table nested_attribute_comments

  column id : Int64, primary: true
  column body : String
  timestamps

  belongs_to post : NestedAttributePost, foreign_key: post_id : Int64?, optional: true
end

class NestedAttributeProfile < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table nested_attribute_profiles

  column id : Int64, primary: true
  column bio : String?
  column website : String?
  timestamps

  belongs_to author : NestedAttributeAuthor, foreign_key: author_id : Int64?, optional: true
end

class NestedAttributeUpdateOnlyAuthor < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table nested_attribute_update_only_authors

  column id : Int64, primary: true
  column name : String

  has_one :profile, class_name: NestedAttributeUpdateOnlyProfile, foreign_key: :update_only_nested_author_id
  accepts_nested_attributes_for profile : NestedAttributeUpdateOnlyProfile, update_only: true
  enable_nested_saves
end

class NestedAttributeUpdateOnlyProfile < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table nested_attribute_update_only_profiles

  column id : Int64, primary: true
  column bio : String?
  column website : String?
  belongs_to :update_only_nested_author, class_name: NestedAttributeUpdateOnlyAuthor, optional: true
end

# Set up each fixture table through its model migration so both supported
# adapters receive the columns declared by these models.
def setup_nested_attributes_tables
  NestedAttributeAuthor.migrator.drop_and_create
  NestedAttributePost.migrator.drop_and_create
  NestedAttributeComment.migrator.drop_and_create
  NestedAttributeProfile.migrator.drop_and_create
  NestedAttributeUpdateOnlyAuthor.migrator.drop_and_create
  NestedAttributeUpdateOnlyProfile.migrator.drop_and_create
end

def cleanup_nested_attributes_tables
  NestedAttributeComment.exec("DROP TABLE IF EXISTS nested_attribute_comments")
  NestedAttributePost.exec("DROP TABLE IF EXISTS nested_attribute_posts")
  NestedAttributeProfile.exec("DROP TABLE IF EXISTS nested_attribute_profiles")
  NestedAttributeAuthor.exec("DROP TABLE IF EXISTS nested_attribute_authors")
  NestedAttributeUpdateOnlyProfile.exec("DROP TABLE IF EXISTS nested_attribute_update_only_profiles")
  NestedAttributeUpdateOnlyAuthor.exec("DROP TABLE IF EXISTS nested_attribute_update_only_authors")
end

describe Grant::NestedAttributes do
  before_each do
    cleanup_nested_attributes_tables
    setup_nested_attributes_tables
  end

  after_each do
    cleanup_nested_attributes_tables
  end

  describe "accepts_nested_attributes_for macro" do
    it "generates attribute setter methods" do
      author = NestedAttributeAuthor.new(name: "John Doe")
      author.responds_to?(:posts_attributes=).should be_true
      author.responds_to?(:profile_attributes=).should be_true
    end
  end

  describe "creating nested records" do
    it "creates child records with has_many association" do
      author = NestedAttributeAuthor.new(name: "John Doe")
      author.posts_attributes = [
        {title: "First NestedAttributePost", content: "Content 1"},
        {title: "Second NestedAttributePost", content: "Content 2"},
      ]

      author.save.should be_true
      author.id.should_not be_nil

      # Verify posts were created
      posts = NestedAttributePost.where(author_id: author.id).select
      posts.size.should eq(2)

      titles = posts.map(&.title).sort
      titles.should eq(["First NestedAttributePost", "Second NestedAttributePost"])
    end

    it "creates child record with has_one association" do
      author = NestedAttributeAuthor.new(name: "Jane Doe")
      author.profile_attributes = {
        bio:     "Software developer",
        website: "https://example.com",
      }

      author.save.should be_true

      # Verify profile was created
      profile = NestedAttributeProfile.find_by(author_id: author.id)
      profile.should_not be_nil
      profile.not_nil!.bio.should eq("Software developer")
      profile.not_nil!.website.should eq("https://example.com")
    end
  end

  describe "updating nested records" do
    it "updates existing child records" do
      author = NestedAttributeAuthor.create(name: "John Doe")
      post = NestedAttributePost.create(title: "Original Title", author_id: author.id)

      author.posts_attributes = [
        {id: post.id, title: "Updated Title"},
      ]

      author.save.should be_true

      # Verify post was updated
      updated_post = NestedAttributePost.find!(post.id)
      updated_post.title.should eq("Updated Title")
    end
  end

  describe "destroying nested records" do
    it "destroys child records when _destroy is true" do
      author = NestedAttributeAuthor.create(name: "John Doe")
      post1 = NestedAttributePost.create(title: "NestedAttributePost 1", author_id: author.id)
      post2 = NestedAttributePost.create(title: "NestedAttributePost 2", author_id: author.id)

      author.posts_attributes = [
        {id: post1.id, _destroy: true},
        {id: post2.id, title: "NestedAttributePost 2 Updated"},
      ]

      author.save.should be_true

      # Verify post1 was destroyed and post2 was updated
      NestedAttributePost.find(post1.id).should be_nil
      NestedAttributePost.find!(post2.id).title.should eq("NestedAttributePost 2 Updated")
    end

    it "ignores _destroy when allow_destroy is false" do
      # NestedAttributeProfile doesn't have allow_destroy
      author = NestedAttributeAuthor.create(name: "Jane Doe")
      profile = NestedAttributeProfile.create(bio: "Original bio", author_id: author.id)

      author.profile_attributes = {
        id:       profile.id,
        _destroy: true,
        bio:      "This should update",
      }

      author.save.should be_true

      # NestedAttributeProfile should still exist and be updated
      updated_profile = NestedAttributeProfile.find!(profile.id)
      updated_profile.bio.should eq("This should update")
    end
  end

  describe "reject_if option" do
    it "rejects all blank attributes" do
      author = NestedAttributeAuthor.new(name: "John Doe")
      author.posts_attributes = [
        {title: "Valid NestedAttributePost", content: "Content"},
        {title: "", content: ""},   # Should be rejected
        {title: nil, content: nil}, # Should be rejected
      ]

      author.save.should be_true

      # Only one post should be created
      posts = NestedAttributePost.where(author_id: author.id).select
      posts.size.should eq(1)
      posts[0].title.should eq("Valid NestedAttributePost")
    end
  end

  describe "limit option" do
    it "raises error when exceeding limit" do
      posts_attrs = (1..6).map { |i| {title: "NestedAttributePost #{i}"} }

      expect_raises(ArgumentError, /Maximum 5 records/) do
        author = NestedAttributeAuthor.new(name: "John Doe")
        author.posts_attributes = posts_attrs
      end
    end
  end

  describe "update_only option" do
    it "does not create new records when update_only is true" do
      author = NestedAttributeUpdateOnlyAuthor.create(name: "Jane Doe")

      # Try to create a profile (should be ignored)
      author.profile_attributes = {
        bio:     "New bio",
        website: "https://example.com",
      }

      author.save.should be_true

      # No profile should be created
      NestedAttributeUpdateOnlyProfile.find_by(update_only_nested_author_id: author.id).should be_nil
    end

    it "updates existing records when update_only is true" do
      author = NestedAttributeUpdateOnlyAuthor.create(name: "Jane Doe")
      profile = NestedAttributeUpdateOnlyProfile.create(bio: "Original bio", update_only_nested_author_id: author.id)

      author.profile_attributes = {
        id:  profile.id,
        bio: "Updated bio",
      }

      author.save.should be_true

      # NestedAttributeProfile should be updated
      updated_profile = NestedAttributeUpdateOnlyProfile.find!(profile.id)
      updated_profile.bio.should eq("Updated bio")
    end
  end

  describe "validation propagation" do
    it "propagates validation errors from nested records" do
      author = NestedAttributeAuthor.new(name: "John Doe")
      author.posts_attributes = [
        {title: "", content: "Content"}, # Invalid - title required
      ]

      author.valid?.should be_false
      author.errors.size.should be > 0
      # Should have error related to nested post
      author.errors.any? { |e| e.field.to_s.includes?("post") || e.field.to_s.includes?("nested") }.should be_true
    end
  end

  describe "complex nested scenarios" do
    it "handles mixed create, update, and destroy operations" do
      author = NestedAttributeAuthor.create(name: "John Doe")
      post1 = NestedAttributePost.create(title: "NestedAttributePost 1", author_id: author.id)
      post2 = NestedAttributePost.create(title: "NestedAttributePost 2", author_id: author.id)

      author.posts_attributes = [
        {id: post1.id, title: "NestedAttributePost 1 Updated"},   # Update
        {id: post2.id, _destroy: true},                           # Destroy
        {title: "NestedAttributePost 3", content: "New content"}, # Create
      ]

      author.save.should be_true

      # Verify results
      posts = NestedAttributePost.where(author_id: author.id).select
      posts.size.should eq(2)

      # post1 should be updated
      NestedAttributePost.find!(post1.id).title.should eq("NestedAttributePost 1 Updated")

      # post2 should be destroyed
      posts.any? { |post| post.title == "NestedAttributePost 2" }.should be_false

      # New post should exist
      posts.any? { |p| p.title == "NestedAttributePost 3" }.should be_true
    end
  end
end
