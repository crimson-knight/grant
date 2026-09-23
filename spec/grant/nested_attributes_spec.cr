require "../spec_helper"

# Test models
class NestedAuthor < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table nested_authors

  column id : Int64, primary: true
  column name : String
  timestamps

  has_many :posts, class_name: NestedPost, foreign_key: :author_id
  has_one :profile, class_name: NestedProfile, foreign_key: :author_id

  # Enable nested attributes with explicit types
  accepts_nested_attributes_for posts : NestedPost,
    allow_destroy: true,
    reject_if: :all_blank,
    limit: 5

  accepts_nested_attributes_for profile : NestedProfile

  # Enable automatic nested saves via callbacks
  enable_nested_saves
end

class NestedPost < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table nested_posts

  column id : Int64, primary: true
  column title : String
  column content : String?
  timestamps

  belongs_to author : NestedAuthor, foreign_key: author_id : Int64?, optional: true
  has_many :comments, class_name: NestedComment, foreign_key: :post_id

  validate :title, "Title cannot be blank" do |post|
    !post.title.blank?
  end

  accepts_nested_attributes_for comments : NestedComment,
    allow_destroy: true

  enable_nested_saves
end

class NestedComment < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table nested_comments

  column id : Int64, primary: true
  column body : String
  timestamps

  belongs_to post : NestedPost, foreign_key: post_id : Int64?, optional: true
end

class NestedProfile < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table nested_profiles

  column id : Int64, primary: true
  column bio : String?
  column website : String?
  timestamps

  belongs_to author : NestedAuthor, foreign_key: author_id : Int64?, optional: true
end

class UpdateOnlyNestedAuthor < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table update_only_nested_authors

  column id : Int64, primary: true
  column name : String

  has_one :profile, class_name: UpdateOnlyNestedProfile, foreign_key: :update_only_nested_author_id
  accepts_nested_attributes_for profile : UpdateOnlyNestedProfile, update_only: true
  enable_nested_saves
end

class UpdateOnlyNestedProfile < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table update_only_nested_profiles

  column id : Int64, primary: true
  column bio : String?
  column website : String?
  belongs_to :update_only_nested_author, optional: true
end

# Set up each fixture table through its model migration so both supported
# adapters receive the columns declared by these models.
def setup_nested_attributes_tables
  NestedAuthor.migrator.drop_and_create
  NestedPost.migrator.drop_and_create
  NestedComment.migrator.drop_and_create
  NestedProfile.migrator.drop_and_create
  UpdateOnlyNestedAuthor.migrator.drop_and_create
  UpdateOnlyNestedProfile.migrator.drop_and_create
end

def cleanup_nested_attributes_tables
  NestedComment.exec("DROP TABLE IF EXISTS nested_comments")
  NestedPost.exec("DROP TABLE IF EXISTS nested_posts")
  NestedProfile.exec("DROP TABLE IF EXISTS nested_profiles")
  NestedAuthor.exec("DROP TABLE IF EXISTS nested_authors")
  UpdateOnlyNestedProfile.exec("DROP TABLE IF EXISTS update_only_nested_profiles")
  UpdateOnlyNestedAuthor.exec("DROP TABLE IF EXISTS update_only_nested_authors")
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
      author = NestedAuthor.new(name: "John Doe")
      author.responds_to?(:posts_attributes=).should be_true
      author.responds_to?(:profile_attributes=).should be_true
    end
  end

  describe "creating nested records" do
    it "creates child records with has_many association" do
      author = NestedAuthor.new(name: "John Doe")
      author.posts_attributes = [
        {title: "First NestedPost", content: "Content 1"},
        {title: "Second NestedPost", content: "Content 2"},
      ]

      author.save.should be_true
      author.id.should_not be_nil

      # Verify posts were created
      posts = NestedPost.where(author_id: author.id).select
      posts.size.should eq(2)

      titles = posts.map(&.title).sort
      titles.should eq(["First NestedPost", "Second NestedPost"])
    end

    it "creates child record with has_one association" do
      author = NestedAuthor.new(name: "Jane Doe")
      author.profile_attributes = {
        bio:     "Software developer",
        website: "https://example.com",
      }

      author.save.should be_true

      # Verify profile was created
      profile = NestedProfile.find_by(author_id: author.id)
      profile.should_not be_nil
      profile.not_nil!.bio.should eq("Software developer")
      profile.not_nil!.website.should eq("https://example.com")
    end
  end

  describe "updating nested records" do
    it "updates existing child records" do
      author = NestedAuthor.create(name: "John Doe")
      post = NestedPost.create(title: "Original Title", author_id: author.id)

      author.posts_attributes = [
        {id: post.id, title: "Updated Title"},
      ]

      author.save.should be_true

      # Verify post was updated
      updated_post = NestedPost.find!(post.id)
      updated_post.title.should eq("Updated Title")
    end
  end

  describe "destroying nested records" do
    it "destroys child records when _destroy is true" do
      author = NestedAuthor.create(name: "John Doe")
      post1 = NestedPost.create(title: "NestedPost 1", author_id: author.id)
      post2 = NestedPost.create(title: "NestedPost 2", author_id: author.id)

      author.posts_attributes = [
        {id: post1.id, _destroy: true},
        {id: post2.id, title: "NestedPost 2 Updated"},
      ]

      author.save.should be_true

      # Verify post1 was destroyed and post2 was updated
      NestedPost.find(post1.id).should be_nil
      NestedPost.find!(post2.id).title.should eq("NestedPost 2 Updated")
    end

    it "ignores _destroy when allow_destroy is false" do
      # NestedProfile doesn't have allow_destroy
      author = NestedAuthor.create(name: "Jane Doe")
      profile = NestedProfile.create(bio: "Original bio", author_id: author.id)

      author.profile_attributes = {
        id:       profile.id,
        _destroy: true,
        bio:      "This should update",
      }

      author.save.should be_true

      # NestedProfile should still exist and be updated
      updated_profile = NestedProfile.find!(profile.id)
      updated_profile.bio.should eq("This should update")
    end
  end

  describe "reject_if option" do
    it "rejects all blank attributes" do
      author = NestedAuthor.new(name: "John Doe")
      author.posts_attributes = [
        {title: "Valid NestedPost", content: "Content"},
        {title: "", content: ""},   # Should be rejected
        {title: nil, content: nil}, # Should be rejected
      ]

      author.save.should be_true

      # Only one post should be created
      posts = NestedPost.where(author_id: author.id).select
      posts.size.should eq(1)
      posts[0].title.should eq("Valid NestedPost")
    end
  end

  describe "limit option" do
    it "raises error when exceeding limit" do
      posts_attrs = (1..6).map { |i| {title: "NestedPost #{i}"} }

      expect_raises(ArgumentError, /Maximum 5 records/) do
        author = NestedAuthor.new(name: "John Doe")
        author.posts_attributes = posts_attrs
      end
    end
  end

  describe "update_only option" do
    it "does not create new records when update_only is true" do
      author = UpdateOnlyNestedAuthor.create(name: "Jane Doe")

      # Try to create a profile (should be ignored)
      author.profile_attributes = {
        bio:     "New bio",
        website: "https://example.com",
      }

      author.save.should be_true

      # No profile should be created
      UpdateOnlyNestedProfile.find_by(update_only_nested_author_id: author.id).should be_nil
    end

    it "updates existing records when update_only is true" do
      author = UpdateOnlyNestedAuthor.create(name: "Jane Doe")
      profile = UpdateOnlyNestedProfile.create(bio: "Original bio", update_only_nested_author_id: author.id)

      author.profile_attributes = {
        id:  profile.id,
        bio: "Updated bio",
      }

      author.save.should be_true

      # NestedProfile should be updated
      updated_profile = UpdateOnlyNestedProfile.find!(profile.id)
      updated_profile.bio.should eq("Updated bio")
    end
  end

  describe "validation propagation" do
    it "propagates validation errors from nested records" do
      author = NestedAuthor.new(name: "John Doe")
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
      author = NestedAuthor.create(name: "John Doe")
      post1 = NestedPost.create(title: "NestedPost 1", author_id: author.id)
      post2 = NestedPost.create(title: "NestedPost 2", author_id: author.id)

      author.posts_attributes = [
        {id: post1.id, title: "NestedPost 1 Updated"},   # Update
        {id: post2.id, _destroy: true},            # Destroy
        {title: "NestedPost 3", content: "New content"}, # Create
      ]

      author.save.should be_true

      # Verify results
      posts = NestedPost.where(author_id: author.id).select
      posts.size.should eq(2)

      # post1 should be updated
      NestedPost.find!(post1.id).title.should eq("NestedPost 1 Updated")

      # post2 should be destroyed
      posts.any? { |post| post.title == "NestedPost 2" }.should be_false

      # New post should exist
      posts.any? { |p| p.title == "NestedPost 3" }.should be_true
    end
  end
end
