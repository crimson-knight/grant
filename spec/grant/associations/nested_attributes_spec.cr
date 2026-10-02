require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class NatAuthor < Grant::Base
    connection {{ adapter_literal }}
    table nat_authors
    column id : Int64, primary: true
    column name : String?

    has_many :nat_posts, class_name: NatPost, foreign_key: :nat_author_id, index_errors: true
    has_many :nat_notes, class_name: NatNote, foreign_key: :nat_author_id
    has_one :nat_profile, class_name: NatProfile, foreign_key: :nat_author_id

    accepts_nested_attributes_for nat_posts : NatPost,
      allow_destroy: true,
      reject_if: ->(attrs : Hash(String, Grant::Columns::Type)) { attrs["title"]?.to_s.starts_with?("skip") },
      limit: 5
    accepts_nested_attributes_for nat_notes : NatNote, reject_if: :untitled?
    accepts_nested_attributes_for nat_profile : NatProfile, update_only: true
    enable_nested_saves

    def untitled?(attrs : Hash(String, Grant::Columns::Type)) : Bool
      attrs["text"]?.to_s.blank?
    end
  end

  class NatPost < Grant::Base
    connection {{ adapter_literal }}
    table nat_posts
    column id : Int64, primary: true
    column nat_author_id : Int64?
    column title : String?
    column body : String?
    validates_presence_of :title
    validates_presence_of :body
  end

  class NatNote < Grant::Base
    connection {{ adapter_literal }}
    table nat_notes
    column id : Int64, primary: true
    column nat_author_id : Int64?
    column text : String?
  end

  class NatProfile < Grant::Base
    connection {{ adapter_literal }}
    table nat_profiles
    column id : Int64, primary: true
    column nat_author_id : Int64?
    column bio : String?
  end

  class NatPublisher < Grant::Base
    connection {{ adapter_literal }}
    table nat_publishers
    column id : Int64, primary: true
    column name : String?
    validates_presence_of :name
  end

  class NatBook < Grant::Base
    connection {{ adapter_literal }}
    table nat_books
    column id : Int64, primary: true
    column nat_publisher_id : Int64?
    column title : String?

    belongs_to :nat_publisher, class_name: NatPublisher, foreign_key: nat_publisher_id : Int64?, optional: true
    accepts_nested_attributes_for nat_publisher : NatPublisher, allow_destroy: true, reject_if: :all_blank
  end
{% end %}

describe "nested attributes" do
  before_all do
    NatAuthor.migrator.drop_and_create
    NatPost.migrator.drop_and_create
    NatNote.migrator.drop_and_create
    NatProfile.migrator.drop_and_create
    NatPublisher.migrator.drop_and_create
    NatBook.migrator.drop_and_create
  end

  before_each do
    NatPost.clear
    NatNote.clear
    NatProfile.clear
    NatBook.clear
    NatAuthor.clear
    NatPublisher.clear
  end

  describe "reject_if" do
    it "accepts a proc" do
      author = NatAuthor.new(name: "a")
      author.nat_posts_attributes = [
        {title: "skip me", body: "x"},
        {title: "keep me", body: "y"},
      ]

      author.save.should be_true
      NatPost.where(nat_author_id: author.id).select.map { |post| post.title.to_s }.should eq(["keep me"])
    end

    it "accepts the name of an instance method" do
      author = NatAuthor.new(name: "a")
      author.nat_notes_attributes = [{text: ""}, {text: "real"}]

      author.save.should be_true
      NatNote.where(nat_author_id: author.id).select.map { |note| note.text.to_s }.should eq(["real"])
    end
  end

  describe "submitted ids" do
    it "raises Grant::RecordNotFound for an id outside the association" do
      author = NatAuthor.create!(name: "a")
      other = NatAuthor.create!(name: "b")
      foreign = NatPost.create!(nat_author_id: other.id, title: "theirs", body: "b")

      error = expect_raises(Grant::RecordNotFound) do
        author.nat_posts_attributes = [{id: foreign.id, title: "hijacked"}]
      end
      error.message.to_s.should contain("NatPost")
      error.message.to_s.should contain(foreign.id.to_s)
      NatPost.find!(foreign.id).title.should eq("theirs")
    end

    it "raises for an id that does not exist at all" do
      author = NatAuthor.create!(name: "a")

      expect_raises(Grant::RecordNotFound) do
        author.nat_posts_attributes = [{id: 999_999, title: "ghost"}]
      end
    end

    it "resolves all ids with one IN query" do
      author = NatAuthor.create!(name: "a")
      posts = 3.times.map { |i| NatPost.create!(nat_author_id: author.id, title: "p#{i}", body: "b") }.to_a
      author = NatAuthor.find!(author.id)

      statements = StatementRecorder.statements do
        author.nat_posts_attributes = posts.map { |post| {id: post.id, title: "edited #{post.title}"} }
      end

      StatementRecorder.count(statements, "SELECT", "nat_posts").should eq(1)
      author.save.should be_true
      NatPost.where(nat_author_id: author.id).select.map { |post| post.title.to_s }.sort.should eq(["edited p0", "edited p1", "edited p2"])
    end

    it "does not load the whole association to save an update" do
      author = NatAuthor.create!(name: "a")
      target = NatPost.create!(nat_author_id: author.id, title: "t", body: "b")
      5.times { |i| NatPost.create!(nat_author_id: author.id, title: "other #{i}", body: "b") }
      author = NatAuthor.find!(author.id)

      author.nat_posts_attributes = [{id: target.id, title: "changed"}]
      statements = StatementRecorder.statements { author.save.should be_true }

      StatementRecorder.count(statements, "SELECT", "nat_posts").should eq(0)
      NatPost.find!(target.id).title.should eq("changed")
    end
  end

  describe "validation" do
    it "validates an updated record against its stored values" do
      author = NatAuthor.create!(name: "a")
      post = NatPost.create!(nat_author_id: author.id, title: "t", body: "kept")

      author.nat_posts_attributes = [{id: post.id, title: "only the title"}]

      author.valid?.should be_true
      author.save.should be_true
      NatPost.find!(post.id).body.should eq("kept")
    end

    it "keys errors by position with index_errors: true" do
      author = NatAuthor.new(name: "a")
      author.nat_posts_attributes = [
        {title: "fine", body: "b"},
        {title: "", body: "b"},
      ]

      author.valid?.should be_false
      author.errors["nat_posts[1].title"].should eq(["can't be blank"])
    end

    it "keys errors by association name otherwise" do
      author = NatAuthor.new(name: "a")
      author.nat_profile_attributes = {bio: "hi"}
      author.valid?.should be_true
    end
  end

  describe "_destroy" do
    it "destroys the record with allow_destroy" do
      author = NatAuthor.create!(name: "a")
      post = NatPost.create!(nat_author_id: author.id, title: "t", body: "b")

      author.nat_posts_attributes = [{id: post.id, _destroy: "1"}]
      author.save.should be_true

      NatPost.find(post.id).should be_nil
      author.nat_posts.to_a.should be_empty
    end
  end

  describe "belongs_to" do
    it "builds the parent and saves it before the child" do
      book = NatBook.new(title: "Guide")
      book.nat_publisher_attributes = {name: "Acme"}

      book.save.should be_true

      publisher = NatPublisher.find_by(name: "Acme").not_nil!
      book.nat_publisher_id.should eq(publisher.id)
      NatBook.find!(book.id).nat_publisher_id.should eq(publisher.id)
    end

    it "updates the existing parent when its id is given" do
      publisher = NatPublisher.create!(name: "Old")
      book = NatBook.create!(title: "Guide", nat_publisher_id: publisher.id)

      book = NatBook.find!(book.id)
      book.nat_publisher_attributes = {id: publisher.id, name: "New"}
      book.save.should be_true

      NatPublisher.find!(publisher.id).name.should eq("New")
      NatPublisher.count.should eq(1)
    end

    it "ignores all-blank attributes" do
      book = NatBook.new(title: "Guide")
      book.nat_publisher_attributes = {name: ""}

      book.save.should be_true
      NatPublisher.count.should eq(0)
      book.nat_publisher_id.should be_nil
    end

    it "carries the parent's validation errors onto the child" do
      publisher = NatPublisher.create!(name: "P")
      book = NatBook.create!(title: "Two", nat_publisher_id: publisher.id)

      book = NatBook.find!(book.id)
      book.nat_publisher_attributes = {id: publisher.id, name: ""}

      book.save.should be_false
      book.errors["nat_publisher.name"].should eq(["can't be blank"])
      NatPublisher.find!(publisher.id).name.should eq("P")
    end

    it "raises Grant::RecordNotFound for an id that is not the current parent" do
      mine = NatPublisher.create!(name: "mine")
      theirs = NatPublisher.create!(name: "theirs")
      book = NatBook.create!(title: "Guide", nat_publisher_id: mine.id)

      book = NatBook.find!(book.id)
      expect_raises(Grant::RecordNotFound) do
        book.nat_publisher_attributes = {id: theirs.id, name: "hijacked"}
      end
      NatPublisher.find!(theirs.id).name.should eq("theirs")
    end

    it "destroys the parent with _destroy and allow_destroy" do
      publisher = NatPublisher.create!(name: "gone")
      book = NatBook.create!(title: "Guide", nat_publisher_id: publisher.id)

      book = NatBook.find!(book.id)
      book.nat_publisher_attributes = {id: publisher.id, _destroy: true}
      book.save.should be_true

      NatPublisher.find(publisher.id).should be_nil
      NatBook.find!(book.id).nat_publisher_id.should be_nil
    end
  end

  describe "limit" do
    it "raises for more records than the limit" do
      author = NatAuthor.new(name: "a")
      expect_raises(ArgumentError, /Maximum 5 records/) do
        author.nat_posts_attributes = (1..6).map { |i| {title: "p#{i}", body: "b"} }
      end
    end
  end
end
