require "../../spec_helper"
require "../../support/polymorphic_models"

describe "Granite::Associations::Polymorphic" do
  before_all do
    Comment.migrator.drop_and_create
    Image.migrator.drop_and_create
    Post.migrator.drop_and_create
    PolyBook.migrator.drop_and_create
  end
  describe "polymorphic belongs_to" do
    it "creates the necessary columns" do
      Comment.fields.includes?("commentable_id").should be_true
      Comment.fields.includes?("commentable_type").should be_true
    end

    it "allows setting a polymorphic association" do
      post = Post.create!(name: "Test Post")
      comment = Comment.new(content: "Great post!")

      comment.commentable = post
      comment.commentable_id.should eq(post.id)
      comment.commentable_type.should eq("Post")

      comment.save!
    end

    it "retrieves the polymorphic association" do
      post = Post.create!(name: "Test Post")
      comment = Comment.new(content: "Great post!")
      comment.commentable = post
      comment.save!

      loaded_comment = Comment.find!(comment.id.not_nil!)
      loaded_comment.commentable.should be_a(Post)
      loaded_commentable = loaded_comment.commentable.not_nil!
      loaded_commentable.should be_a(Post)
      loaded_commentable.as(Post).id.should eq(post.id)
    end

    it "handles different polymorphic types" do
      post = Post.create!(name: "Test Post")
      book = PolyBook.create!(name: "Test PolyBook")

      comment1 = Comment.new(content: "About the post")
      comment1.commentable = post
      comment1.save!
      
      comment2 = Comment.new(content: "About the book")
      comment2.commentable = book
      comment2.save!

      Comment.find!(comment1.id.not_nil!).commentable.should be_a(Post)
      Comment.find!(comment2.id.not_nil!).commentable.should be_a(PolyBook)
    end

    it "handles nil polymorphic associations" do
      comment = Comment.create!(content: "Standalone comment")
      comment.commentable.should be_nil
      comment.commentable_id.should be_nil
      comment.commentable_type.should be_nil
    end
  end

  describe "polymorphic has_many" do
    it "retrieves associated records through polymorphic association" do
      post = Post.create!(name: "Test Post")
      book = PolyBook.create!(name: "Test PolyBook")

      comment1 = Comment.new(content: "First post comment")
      comment1.commentable = post
      comment1.save!
      
      comment2 = Comment.new(content: "Second post comment")
      comment2.commentable = post
      comment2.save!
      
      comment3 = Comment.new(content: "PolyBook comment")
      comment3.commentable = book
      comment3.save!

      post_comments = post.comments.to_a
      post_comments.size.should eq(2)
      post_comments.map(&.content).should contain("First post comment")
      post_comments.map(&.content).should contain("Second post comment")

      book_comments = book.comments.to_a
      book_comments.size.should eq(1)
      book_comments.first.content.should eq("PolyBook comment")
    end
  end

  describe "polymorphic has_one" do
    it "retrieves a single associated record through polymorphic association" do
      post = Post.create!(name: "Test Post")
      book = PolyBook.create!(name: "Test PolyBook")

      post_image = Image.new(url: "post.jpg")
      post_image.imageable = post
      post_image.save!
      
      book_image = Image.new(url: "book.jpg")
      book_image.imageable = book
      book_image.save!

      post.image.not_nil!.url.should eq("post.jpg")
      book.image.not_nil!.url.should eq("book.jpg")
    end
  end
end
