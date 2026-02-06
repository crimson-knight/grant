require "../../spec_helper"

describe "AssociationCollection methods" do
  before_all do
    CollectionAuthor.migrator.drop_and_create
    CollectionPost.migrator.drop_and_create
  end

  before_each do
    CollectionPost.clear
    CollectionAuthor.clear
  end

  describe "#build" do
    it "creates a new unsaved record with foreign key set" do
      author = CollectionAuthor.new
      author.name = "Jane"
      author.save.should be_true

      post = author.posts.build(title: "New Post", body: "Content")

      post.should be_a(CollectionPost)
      post.title.should eq("New Post")
      post.body.should eq("Content")
      post.collection_author_id.should eq(author.id)
      post.new_record?.should be_true
    end

    it "does not persist the record" do
      author = CollectionAuthor.new
      author.name = "Bob"
      author.save.should be_true

      author.posts.build(title: "Draft")

      CollectionPost.where(collection_author_id: author.id).count.should eq(0)
    end
  end

  describe "#create" do
    it "creates and saves a new record with foreign key set" do
      author = CollectionAuthor.new
      author.name = "Alice"
      author.save.should be_true

      post = author.posts.create(title: "Published", body: "Text")

      post.should be_a(CollectionPost)
      post.title.should eq("Published")
      post.collection_author_id.should eq(author.id)
      post.new_record?.should be_false
    end

    it "returns record with errors if validation fails" do
      author = CollectionAuthor.new
      author.name = "Author"
      author.save.should be_true

      # title is required, so nil title should fail validation
      post = author.posts.create(body: "no title")

      post.errors.any?.should be_true
    end

    it "persists the record in the database" do
      author = CollectionAuthor.new
      author.name = "Charlie"
      author.save.should be_true

      author.posts.create(title: "Saved Post", body: "Body")

      CollectionPost.where(collection_author_id: author.id).count.should eq(1)
    end
  end

  describe "#create!" do
    it "creates and saves a new record" do
      author = CollectionAuthor.new
      author.name = "Dave"
      author.save.should be_true

      post = author.posts.create!(title: "Must Save", body: "Body")

      post.should be_a(CollectionPost)
      post.collection_author_id.should eq(author.id)
      post.new_record?.should be_false
    end

    it "raises on validation failure" do
      author = CollectionAuthor.new
      author.name = "Eve"
      author.save.should be_true

      expect_raises(Grant::RecordNotSaved) do
        author.posts.create!(body: "no title")
      end
    end
  end

  describe "#delete_all" do
    it "deletes all associated records via SQL" do
      author = CollectionAuthor.new
      author.name = "Frank"
      author.save.should be_true

      3.times do |i|
        author.posts.create(title: "Post #{i}", body: "Body #{i}")
      end

      CollectionPost.where(collection_author_id: author.id).count.should eq(3)

      deleted = author.posts.delete_all
      deleted.should eq(3)

      CollectionPost.where(collection_author_id: author.id).count.should eq(0)
    end

    it "returns 0 when no associated records exist" do
      author = CollectionAuthor.new
      author.name = "Grace"
      author.save.should be_true

      author.posts.delete_all.should eq(0)
    end
  end

  describe "#destroy_all" do
    it "destroys all associated records with callbacks" do
      author = CollectionAuthor.new
      author.name = "Hank"
      author.save.should be_true

      3.times do |i|
        author.posts.create(title: "Post #{i}", body: "Body #{i}")
      end

      count = author.posts.destroy_all
      count.should eq(3)

      CollectionPost.where(collection_author_id: author.id).count.should eq(0)
    end
  end
end

# Test models for collection methods
class CollectionAuthor < Grant::Base
  connection sqlite
  table collection_authors

  column id : Int64, primary: true
  column name : String?

  has_many :posts, class_name: "CollectionPost", foreign_key: :collection_author_id
end

class CollectionPost < Grant::Base
  connection sqlite
  table collection_posts

  column id : Int64, primary: true
  column title : String?
  column body : String?
  column collection_author_id : Int64?

  belongs_to :collection_author, optional: true

  validates_presence_of :title
end
