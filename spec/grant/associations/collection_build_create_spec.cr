require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class BcAuthor < Grant::Base
    connection {{ adapter_literal }}
    table bc_authors
    column id : Int64, primary: true
    column name : String?
    has_many :bc_books, class_name: BcBook, foreign_key: :bc_author_id, inverse_of: :bc_author
  end

  class BcBook < Grant::Base
    connection {{ adapter_literal }}
    table bc_books
    column id : Int64, primary: true
    column title : String?
    column pages : Int32?
    column bc_author_id : Int64?
    belongs_to :bc_author, class_name: BcAuthor, foreign_key: :bc_author_id, optional: true
    validate "title must be present" do |book|
      !book.title.to_s.empty?
    end
  end
{% end %}

describe "collection build, create and create!" do
  before_all do
    BcAuthor.migrator.drop_and_create
    BcBook.migrator.drop_and_create
  end

  before_each do
    BcBook.clear
    BcAuthor.clear
  end

  describe "#build" do
    it "sets the foreign key and the inverse association" do
      author = BcAuthor.create!(name: "a")

      book = author.bc_books.build(title: "T")

      book.persisted?.should be_false
      book.bc_author_id.should eq(author.id)
      book.association_loaded?(:bc_author).should be_true
      book.bc_author.should be(author)
    end

    it "yields the new record to a block after attributes are assigned" do
      author = BcAuthor.create!(name: "a")
      seen_title = nil.as(String?)

      book = author.bc_books.build(title: "T") do |built|
        seen_title = built.title
        built.pages = 12
      end

      seen_title.should eq("T")
      book.pages.should eq(12)
    end

    it "accepts a Hash of attributes" do
      author = BcAuthor.create!(name: "a")

      book = author.bc_books.build({"title" => "H", "pages" => 3})

      book.title.should eq("H")
      book.pages.should eq(3)
      book.bc_author_id.should eq(author.id)
    end

    it "accepts an Array of Hashes and NamedTuples" do
      author = BcAuthor.create!(name: "a")

      from_hashes = author.bc_books.build([{"title" => "1"}, {"title" => "2"}])
      from_tuples = author.bc_books.build([{title: "3"}, {title: "4"}])

      from_hashes.map(&.title).should eq(["1", "2"])
      from_tuples.map(&.title).should eq(["3", "4"])
      (from_hashes + from_tuples).all? { |book| book.bc_author_id == author.id }.should be_true
      BcBook.count.should eq(0)
    end

    it "works on an owner that is not saved yet" do
      author = BcAuthor.new(name: "new")

      book = author.bc_books.build(title: "T")

      book.bc_author_id.should be_nil
      book.persisted?.should be_false
    end

    it "tracks the built record in a loaded collection" do
      author = BcAuthor.create!(name: "a")
      collection = author.bc_books
      collection.load_target

      book = collection.build(title: "T")

      collection.to_a.should contain(book)
    end
  end

  describe "#create" do
    it "saves the record with the owner's key" do
      author = BcAuthor.create!(name: "a")

      book = author.bc_books.create(title: "T")

      book.persisted?.should be_true
      BcBook.find!(book.id).bc_author_id.should eq(author.id)
    end

    it "returns the unsaved record when validation fails" do
      author = BcAuthor.create!(name: "a")

      book = author.bc_books.create(title: "")

      book.persisted?.should be_false
      BcBook.count.should eq(0)
    end

    it "supports the block form and a Hash" do
      author = BcAuthor.create!(name: "a")

      first = author.bc_books.create(title: "T", &.pages=(7))
      second = author.bc_books.create({"title" => "H"})

      BcBook.find!(first.id).pages.should eq(7)
      BcBook.find!(second.id).title.should eq("H")
    end

    it "creates every element of an Array inside one transaction" do
      author = BcAuthor.create!(name: "a")

      created = [] of BcBook
      statements = StatementRecorder.statements do
        created = author.bc_books.create([{title: "1"}, {title: "2"}, {title: "3"}])
      end

      created.size.should eq(3)
      BcBook.where(bc_author_id: author.id).count.should eq(3)
      # MySQL opens a transaction with START TRANSACTION, the others with BEGIN.
      StatementRecorder.count(statements, CURRENT_ADAPTER == "mysql" ? "START TRANSACTION" : "BEGIN").should eq(1)
      StatementRecorder.count(statements, "COMMIT").should eq(1)
    end

    it "raises RecordNotSaved for an owner that is not saved" do
      author = BcAuthor.new(name: "new")

      error = expect_raises(Grant::RecordNotSaved) { author.bc_books.create(title: "T") }

      error.message.to_s.should contain("parent is saved")
      BcBook.count.should eq(0)
    end
  end

  describe "#create!" do
    it "raises when the record is invalid" do
      author = BcAuthor.create!(name: "a")

      expect_raises(Grant::RecordInvalid) { author.bc_books.create!(title: "") }
    end

    it "raises RecordNotSaved for an owner that is not saved" do
      author = BcAuthor.new(name: "new")

      expect_raises(Grant::RecordNotSaved) { author.bc_books.create!(title: "T") }
      expect_raises(Grant::RecordNotSaved) { author.bc_books.create!([{title: "T"}]) }
    end

    it "supports the block form" do
      author = BcAuthor.create!(name: "a")

      book = author.bc_books.create!(title: "T", &.pages=(9))

      BcBook.find!(book.id).pages.should eq(9)
    end
  end
end
