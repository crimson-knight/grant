require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class LoAuthor < Grant::Base
    connection {{ adapter_literal }}
    table lo_authors
    column id : Int64, primary: true
    column name : String
    has_many :books, class_name: LoBook, foreign_key: :lo_author_id
  end

  class LoBook < Grant::Base
    connection {{ adapter_literal }}
    table lo_books
    column id : Int64, primary: true
    column title : String
    column lo_author_id : Int64?
    belongs_to :lo_author, class_name: LoAuthor, foreign_key: :lo_author_id, optional: true
    has_many :chapters, class_name: LoChapter, foreign_key: :lo_book_id
  end

  class LoChapter < Grant::Base
    connection {{ adapter_literal }}
    table lo_chapters
    column id : Int64, primary: true
    column heading : String
    column lo_book_id : Int64?
  end
{% end %}

describe "left_outer_joins" do
  before_all do
    LoAuthor.migrator.drop_and_create
    LoBook.migrator.drop_and_create
    LoChapter.migrator.drop_and_create
  end

  before_each do
    LoChapter.clear
    LoBook.clear
    LoAuthor.clear
    ada = LoAuthor.create!(name: "Ada")
    LoAuthor.create!(name: "Grace")
    book = LoBook.create!(title: "Notes", lo_author_id: ada.id)
    LoChapter.create!(heading: "One", lo_book_id: book.id)
  end

  it "is the same query as left_joins for every form" do
    LoAuthor.left_outer_joins(:books).raw_sql.should eq(LoAuthor.left_joins(:books).raw_sql)
    LoAuthor.left_outer_joins(books: :chapters).raw_sql.should eq(LoAuthor.left_joins(books: :chapters).raw_sql)
    LoAuthor.left_outer_joins("lo_books", on: "lo_books.lo_author_id = lo_authors.id").raw_sql
      .should eq(LoAuthor.left_joins("lo_books", on: "lo_books.lo_author_id = lo_authors.id").raw_sql)
    LoBook.left_outer_joins(:lo_author, as: "writers").raw_sql.should eq(LoBook.left_joins(:lo_author, as: "writers").raw_sql)
  end

  it "keeps rows that have no match" do
    LoAuthor.left_outer_joins(:books).order(:name).select.map(&.name).should eq(["Ada", "Grace"])
    LoAuthor.joins(:books).select.map(&.name).should eq(["Ada"])
  end

  it "finds the rows without an association, the classic anti-join" do
    LoAuthor.left_outer_joins(:books).where("lo_books.id IS NULL").select.map(&.name).should eq(["Grace"])
  end

  it "resolves nested associations" do
    relation = LoAuthor.left_outer_joins(books: :chapters)
    relation.raw_sql.should contain("LEFT JOIN lo_books ON lo_books.lo_author_id = lo_authors.id")
    relation.raw_sql.should contain("LEFT JOIN lo_chapters ON lo_chapters.lo_book_id = lo_books.id")
    relation.where("lo_chapters.id IS NULL").select.map(&.name).should eq(["Grace"])
  end

  it "accepts several associations and a raw fragment" do
    LoBook.left_outer_joins(:lo_author, :chapters).raw_sql.should contain("LEFT JOIN lo_chapters")
    fragment = "LEFT OUTER JOIN lo_books ON lo_books.lo_author_id = lo_authors.id"
    LoAuthor.left_outer_joins(fragment).order(:name).select.map(&.name).should eq(["Ada", "Grace"])
  end

  it "de-duplicates a join requested twice" do
    LoAuthor.left_outer_joins(:books).left_joins(:books).join_clauses.size.should eq(1)
  end

  it "is available on the model class and as a bang form" do
    LoAuthor.left_outer_joins(:books).select.size.should eq(2)
    relation = LoAuthor.all
    relation.left_outer_joins!(:books)
    relation.join_clauses.size.should eq(1)
  end

  it "does not change the receiver" do
    base = LoAuthor.where(name: "Ada")
    base.left_outer_joins(:books)
    base.join_clauses.should be_empty
  end
end
