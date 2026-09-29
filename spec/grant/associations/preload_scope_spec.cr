require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class PsAuthor < Grant::Base
    connection {{ adapter_literal }}
    table ps_authors
    column id : Int64, primary: true
    column name : String
    column vip : Bool = false
    has_many :posts, class_name: PsPost, foreign_key: :ps_author_id
    has_many :published_posts, -> { where(published: true) }, class_name: PsPost, foreign_key: :ps_author_id
    has_many :newest_posts, ->(q : Grant::Query::Builder(PsPost)) { q.where(published: true).order(id: :desc) },
      class_name: PsPost, foreign_key: :ps_author_id
    has_one :top_post, -> { where(published: true) }, class_name: PsPost, foreign_key: :ps_author_id
  end

  class PsPost < Grant::Base
    connection {{ adapter_literal }}
    table ps_posts
    column id : Int64, primary: true
    column title : String
    column published : Bool = false
    column ps_author_id : Int64?
    belongs_to :ps_author, class_name: PsAuthor, foreign_key: :ps_author_id, optional: true
    belongs_to :vip_author, -> { where(vip: true) }, class_name: PsAuthor, foreign_key: :ps_author_id, optional: true
  end
{% end %}

def seed_authors(count : Int32) : Array(PsAuthor)
  Array(PsAuthor).new(count) do |index|
    author = PsAuthor.create!(name: "author #{index}", vip: index.even?)
    PsPost.create!(title: "published #{index}", published: true, ps_author_id: author.id)
    PsPost.create!(title: "draft #{index}", published: false, ps_author_id: author.id)
    PsPost.create!(title: "published again #{index}", published: true, ps_author_id: author.id)
    author
  end
end

describe "association scopes when preloading" do
  before_all do
    PsAuthor.migrator.drop_and_create
    PsPost.migrator.drop_and_create
  end

  before_each do
    PsPost.clear
    PsAuthor.clear
  end

  it "loads only the rows the has_many scope allows, matching the lazy result" do
    seed_authors(3)

    preloaded = PsAuthor.includes(:published_posts).order(:id).select
    preloaded.each do |author|
      author.association_loaded?(:published_posts).should be_true
      lazy = PsAuthor.find!(author.id).published_posts.to_a
      author.published_posts.map(&.id.not_nil!).sort!.should eq(lazy.map(&.id.not_nil!).sort!)
      author.published_posts.all?(&.published).should be_true
      author.published_posts.size.should eq(2)
    end
  end

  it "applies the scope with preload and eager_load as well" do
    seed_authors(2)

    PsAuthor.preload(:published_posts).select.each { |author| author.published_posts.size.should eq(2) }
    PsAuthor.eager_load(:published_posts).select.each { |author| author.published_posts.size.should eq(2) }
  end

  it "honors a scope written as a lambda over the relation" do
    author = seed_authors(1).first
    newest = PsAuthor.includes(:newest_posts).where(id: author.id).select.first
    lazy = PsAuthor.find!(author.id).newest_posts.to_a
    newest.newest_posts.map(&.id.not_nil!).should eq(lazy.map(&.id.not_nil!))
    newest.newest_posts.map(&.id.not_nil!).should eq(newest.newest_posts.map(&.id.not_nil!).sort.reverse)
  end

  it "applies a has_one scope" do
    author = PsAuthor.create!(name: "solo")
    PsPost.create!(title: "draft", published: false, ps_author_id: author.id)
    published = PsPost.create!(title: "live", published: true, ps_author_id: author.id)

    loaded = PsAuthor.includes(:top_post).where(id: author.id).select.first
    loaded.association_loaded?(:top_post).should be_true
    loaded.top_post.try(&.id).should eq(published.id)
    PsAuthor.find!(author.id).top_post.try(&.id).should eq(published.id)
  end

  it "applies a belongs_to scope" do
    authors = seed_authors(2)
    vip = authors.first
    other = authors.last
    PsPost.where(ps_author_id: vip.id).select.each do |post|
      PsPost.find!(post.id).vip_author.try(&.id).should eq(vip.id)
    end

    posts = PsPost.includes(:vip_author).order(:id).select
    posts.each do |post|
      expected = post.ps_author_id == vip.id ? vip.id : nil
      post.vip_author.try(&.id).should eq(expected)
      post.vip_author.try(&.id).should_not eq(other.id)
    end
  end

  it "costs the same number of queries for one owner or many" do
    seed_authors(1)
    one = AssociationQueryCounter.selects { PsAuthor.includes(:published_posts).select.to_a }
    PsPost.clear
    PsAuthor.clear
    seed_authors(8)
    many = AssociationQueryCounter.selects { PsAuthor.includes(:published_posts).select.to_a }
    one.should eq(2)
    many.should eq(2)
  end
end
