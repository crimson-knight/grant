require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class PlAuthor < Grant::Base
    connection {{ adapter_literal }}
    table pl_authors
    column id : Int64, primary: true
    column name : String
    has_many :pl_posts, class_name: PlPost, foreign_key: :pl_author_id
    has_one :pl_badge, class_name: PlBadge, foreign_key: :pl_author_id
  end

  class PlPost < Grant::Base
    connection {{ adapter_literal }}
    table pl_posts
    column id : Int64, primary: true
    column title : String
    column pl_author_id : Int64?
    belongs_to :pl_author, class_name: PlAuthor, foreign_key: :pl_author_id, optional: true
    has_many :pl_comments, class_name: PlComment, foreign_key: :pl_post_id
  end

  class PlComment < Grant::Base
    connection {{ adapter_literal }}
    table pl_comments
    column id : Int64, primary: true
    column body : String
    column pl_post_id : Int64?
  end

  class PlBadge < Grant::Base
    connection {{ adapter_literal }}
    table pl_badges
    column id : Int64, primary: true
    column label : String
    column pl_author_id : Int64?
  end
{% end %}

def seed_pl(authors : Int32)
  authors.times do |index|
    author = PlAuthor.create!(name: "author #{index}")
    PlBadge.create!(label: "badge #{index}", pl_author_id: author.id)
    2.times do |post_index|
      post = PlPost.create!(title: "post #{index}-#{post_index}", pl_author_id: author.id)
      PlComment.create!(body: "comment", pl_post_id: post.id)
    end
  end
end

describe Grant::Preloader do
  before_all do
    {% for model in [PlAuthor, PlPost, PlComment, PlBadge] %}
      {{ model }}.migrator.drop_and_create
    {% end %}
  end

  before_each do
    {% for model in [PlComment, PlPost, PlBadge, PlAuthor] %}
      {{ model }}.clear
    {% end %}
  end

  it "loads associations on records that are already in memory" do
    seed_pl(3)
    authors = PlAuthor.order(:id).select.to_a

    queries = AssociationQueryCounter.selects do
      Grant::Preloader.new(authors, [:pl_posts, {pl_posts: [:pl_comments]}, :pl_badge]).call
    end
    queries.should eq(3)

    AssociationQueryCounter.selects do
      authors.each do |author|
        author.pl_posts.size.should eq(2)
        author.pl_badge.should_not be_nil
        author.pl_posts.each(&.pl_comments.size.should(eq(1)))
      end
    end.should eq(0)
  end

  it "accepts the keyword form and returns the records" do
    seed_pl(2)
    authors = PlAuthor.order(:id).select.to_a
    result = Grant::Preloader.new(authors, pl_posts: :pl_comments).call
    result.size.should eq(2)
    authors.first.pl_posts.first!.association_loaded?(:pl_comments).should be_true
  end

  it "skips records that already have the association loaded" do
    seed_pl(2)
    authors = PlAuthor.order(:id).select.to_a
    Grant::Preloader.new([authors.first], :pl_posts).call
    authors.first.association_loaded?(:pl_posts).should be_true
    authors.last.association_loaded?(:pl_posts).should be_false

    kept = authors.first.pl_posts.to_a
    statements = AssociationQueryCounter.statements { Grant::Preloader.new(authors, :pl_posts).call }
    statements.size.should eq(1)
    authors.first.pl_posts.first!.should be(kept.first)

    AssociationQueryCounter.selects { Grant::Preloader.new(authors, :pl_posts).call }.should eq(0)
  end

  it "still descends into nested records of an association that was already loaded" do
    seed_pl(1)
    authors = PlAuthor.select.to_a
    Grant::Preloader.new(authors, :pl_posts).call
    Grant::Preloader.new(authors, pl_posts: :pl_comments).call
    authors.first.pl_posts.each { |post| post.association_loaded?(:pl_comments).should be_true }
  end

  it "raises AssociationNotFoundError for an unknown name" do
    seed_pl(1)
    authors = PlAuthor.select.to_a
    expect_raises(Grant::AssociationNotFoundError, /'nope' was not found on PlAuthor/) do
      Grant::Preloader.new(authors, :nope).call
    end
    expect_raises(Grant::AssociationNotFoundError, /'nope' was not found on PlPost/) do
      Grant::Preloader.new(authors, pl_posts: :nope).call
    end
  end

  it "does nothing for an empty list of records" do
    Grant::Preloader.new([] of PlAuthor, :pl_posts).call.should be_empty
  end

  it "chunks IN lists above the configured limit" do
    seed_pl(5)
    authors = PlAuthor.order(:id).select.to_a
    original = Grant.settings.in_clause_limit
    begin
      Grant.settings.in_clause_limit = 2
      statements = AssociationQueryCounter.statements { Grant::Preloader.new(authors, :pl_posts).call }
      statements.size.should eq(3)
      authors.each(&.pl_posts.size.should(eq(2)))
    ensure
      Grant.settings.in_clause_limit = original
    end
  end

  it "keeps one query per level for many owners" do
    authors = [] of PlAuthor
    150.times { |index| authors << PlAuthor.create!(name: "a#{index}") }
    authors.each { |author| PlBadge.create!(label: "b", pl_author_id: author.id) }
    loaded = PlAuthor.order(:id).select.to_a
    AssociationQueryCounter.selects { Grant::Preloader.new(loaded, :pl_badge).call }.should eq(1)
  end
end
