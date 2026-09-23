require "../../spec_helper"
require "../../support/polymorphic_models"

describe "Grant::Associations::Polymorphic" do
  before_all do
    PolymorphicComment.migrator.drop_and_create
    Image.migrator.drop_and_create
    PolymorphicPost.migrator.drop_and_create
    PolyBook.migrator.drop_and_create
  end
  describe "polymorphic belongs_to" do
    it "creates the necessary columns" do
      PolymorphicComment.fields.includes?("commentable_id").should be_true
      PolymorphicComment.fields.includes?("commentable_type").should be_true
    end

    it "allows setting a polymorphic association" do
      post = PolymorphicPost.create!(name: "Test PolymorphicPost")
      comment = PolymorphicComment.new(content: "Great post!")

      comment.commentable = post
      comment.commentable_id.should eq(post.id)
      comment.commentable_type.should eq("PolymorphicPost")

      comment.save!
    end

    it "retrieves the polymorphic association" do
      post = PolymorphicPost.create!(name: "Test PolymorphicPost")
      comment = PolymorphicComment.new(content: "Great post!")
      comment.commentable = post
      comment.save!

      loaded_comment = PolymorphicComment.find!(comment.id.not_nil!)
      loaded_comment.commentable.should be_a(PolymorphicPost)
      loaded_commentable = loaded_comment.commentable.not_nil!
      loaded_commentable.should be_a(PolymorphicPost)
      loaded_commentable.as(PolymorphicPost).id.should eq(post.id)
    end

    it "handles different polymorphic types" do
      post = PolymorphicPost.create!(name: "Test PolymorphicPost")
      book = PolyBook.create!(name: "Test PolyBook")

      comment1 = PolymorphicComment.new(content: "About the post")
      comment1.commentable = post
      comment1.save!
      
      comment2 = PolymorphicComment.new(content: "About the book")
      comment2.commentable = book
      comment2.save!

      PolymorphicComment.find!(comment1.id.not_nil!).commentable.should be_a(PolymorphicPost)
      PolymorphicComment.find!(comment2.id.not_nil!).commentable.should be_a(PolyBook)
    end

    it "handles nil polymorphic associations" do
      comment = PolymorphicComment.create!(content: "Standalone comment")
      comment.commentable.should be_nil
      comment.commentable_id.should be_nil
      comment.commentable_type.should be_nil
    end
  end

  describe "polymorphic has_many" do
    it "retrieves associated records through polymorphic association" do
      post = PolymorphicPost.create!(name: "Test PolymorphicPost")
      book = PolyBook.create!(name: "Test PolyBook")

      comment1 = PolymorphicComment.new(content: "First post comment")
      comment1.commentable = post
      comment1.save!
      
      comment2 = PolymorphicComment.new(content: "Second post comment")
      comment2.commentable = post
      comment2.save!
      
      comment3 = PolymorphicComment.new(content: "PolyBook comment")
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
      post = PolymorphicPost.create!(name: "Test PolymorphicPost")
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
