require "../../spec_helper"

describe "inverse_of" do
  before_all do
    InverseAuthor.migrator.drop_and_create
    InversePost.migrator.drop_and_create
    InverseComment.migrator.drop_and_create
  end

  before_each do
    InverseComment.clear
    InversePost.clear
    InverseAuthor.clear
  end

  describe "has_many inverse_of" do
    it "sets the inverse association on loaded records from #all" do
      author = InverseAuthor.new
      author.name = "Jane"
      author.save.should be_true

      post = InversePost.new
      post.title = "Post 1"
      post.inverse_author_id = author.id
      post.save.should be_true

      # Load posts through the association
      posts = author.inverse_posts.all

      # The inverse should be pre-loaded — post.inverse_author should
      # return the same author without hitting the database
      loaded_post = posts.first
      loaded_post.should_not be_nil

      # Check that the inverse association is loaded
      loaded_post.association_loaded?("inverse_author").should be_true

      # Accessing the inverse should return the owner
      loaded_author = loaded_post.inverse_author
      loaded_author.should_not be_nil
      loaded_author.not_nil!.id.should eq(author.id)
    end

    it "sets the inverse on records returned by find_by" do
      author = InverseAuthor.new
      author.name = "Bob"
      author.save.should be_true

      post = InversePost.new
      post.title = "Specific Post"
      post.inverse_author_id = author.id
      post.save.should be_true

      found = author.inverse_posts.find_by(title: "Specific Post")
      found.should_not be_nil
      found.not_nil!.association_loaded?("inverse_author").should be_true
      found.not_nil!.inverse_author.not_nil!.id.should eq(author.id)
    end

    it "sets inverse on all records in a collection" do
      author = InverseAuthor.new
      author.name = "Carol"
      author.save.should be_true

      3.times do |i|
        post = InversePost.new
        post.title = "Post #{i}"
        post.inverse_author_id = author.id
        post.save.should be_true
      end

      posts = author.inverse_posts.all
      posts.each do |post|
        post.association_loaded?("inverse_author").should be_true
      end
    end
  end

  describe "has_one inverse_of" do
    it "sets the inverse association on the loaded record" do
      author = InverseAuthor.new
      author.name = "Dave"
      author.save.should be_true

      comment = InverseComment.new
      comment.body = "First comment"
      comment.inverse_author_id = author.id
      comment.save.should be_true

      # Access has_one association
      loaded_comment = author.featured_comment
      loaded_comment.should_not be_nil

      # Check inverse is loaded
      loaded_comment.not_nil!.association_loaded?("comment_author").should be_true
      loaded_comment.not_nil!.comment_author.not_nil!.id.should eq(author.id)
    end

    it "sets the inverse on bang method too" do
      author = InverseAuthor.new
      author.name = "Eve"
      author.save.should be_true

      comment = InverseComment.new
      comment.body = "Important"
      comment.inverse_author_id = author.id
      comment.save.should be_true

      loaded_comment = author.featured_comment!
      loaded_comment.association_loaded?("comment_author").should be_true
      loaded_comment.comment_author.not_nil!.id.should eq(author.id)
    end
  end

  describe "belongs_to inverse_of" do
    it "sets the inverse association on the loaded parent" do
      author = InverseAuthor.new
      author.name = "Frank"
      author.save.should be_true

      post = InversePost.new
      post.title = "My Post"
      post.inverse_author_id = author.id
      post.save.should be_true

      # Access belongs_to — should set inverse on the returned author
      loaded_author = post.inverse_author
      loaded_author.should_not be_nil

      # The inverse (has_many posts) should be pre-loaded on the author
      # For belongs_to -> has_many inverse, we set the individual record
      loaded_author.not_nil!.association_loaded?("inverse_posts").should be_true
    end

    it "sets inverse on bang method" do
      author = InverseAuthor.new
      author.name = "Grace"
      author.save.should be_true

      post = InversePost.new
      post.title = "Another Post"
      post.inverse_author_id = author.id
      post.save.should be_true

      loaded_author = post.inverse_author!
      loaded_author.association_loaded?("inverse_posts").should be_true
    end
  end

  describe "without inverse_of" do
    it "does not pre-load the inverse association" do
      author = InverseAuthor.new
      author.name = "Hank"
      author.save.should be_true

      comment = InverseComment.new
      comment.body = "No inverse"
      comment.inverse_author_id = author.id
      comment.save.should be_true

      # InverseComment.comment_author does NOT have inverse_of set
      # So accessing it should not pre-load anything on the author
      loaded_author = comment.comment_author
      loaded_author.should_not be_nil
      # The inverse (featured_comment) should NOT be pre-loaded
      loaded_author.not_nil!.association_loaded?("featured_comment").should be_false
    end
  end
end

# Test models for inverse_of
class InverseAuthor < Grant::Base
  connection sqlite
  table inverse_authors

  column id : Int64, primary: true
  column name : String?

  has_many :inverse_posts, class_name: InversePost, foreign_key: :inverse_author_id, inverse_of: :inverse_author
  has_one :featured_comment, class_name: InverseComment, foreign_key: :inverse_author_id, inverse_of: :comment_author
end

class InversePost < Grant::Base
  connection sqlite
  table inverse_posts

  column id : Int64, primary: true
  column title : String?
  column inverse_author_id : Int64?

  belongs_to :inverse_author, optional: true, inverse_of: :inverse_posts
end

class InverseComment < Grant::Base
  connection sqlite
  table inverse_comments

  column id : Int64, primary: true
  column body : String?
  column inverse_author_id : Int64?

  # Note: comment_author has inverse_of on the has_one side, not here
  belongs_to :comment_author, class_name: InverseAuthor, foreign_key: :inverse_author_id, optional: true
end
