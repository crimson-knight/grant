require "../../spec_helper"
require "../../support/where_family_models"

private def titles(relation : Grant::Query::Builder(WfPost)) : Array(String)
  relation.order(:id).select.map { |post| post.title.to_s }
end

describe "unscope(where: column)" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    ann = WfAuthor.create!(name: "ann", active: true)
    WfPost.create!(title: "a", published: true, score: 1, author_id: ann.id)
    WfPost.create!(title: "b", published: false, score: 2)
    WfPost.create!(title: "c", published: true, score: 3)
  end

  it "drops only the named column's conditions" do
    relation = WfPost.where(published: true, score: 3).unscope(where: :published)
    titles(relation).should eq(["c"])
    relation.to_sql.split("FROM").last.should_not contain("published")
  end

  it "accepts an array of columns" do
    relation = WfPost.where(published: true, score: 3, title: "c").unscope(where: [:published, :score])
    titles(relation).should eq(["c"])
  end

  it "drops every condition on the column, ranges and lists included" do
    relation = WfPost.where(score: 1..2).where(score: [1, 2]).where(published: false).unscope(where: :score)
    titles(relation).should eq(["b"])
  end

  it "combines with plain components" do
    relation = WfPost.where(published: true).order(score: :desc).unscope(:order, where: :published)
    relation.to_sql.should_not contain("ORDER BY")
    relation.to_sql.split("FROM").last.should_not contain("published")
    titles(relation).size.should eq(3)
  end

  it "leaves the receiver untouched" do
    base = WfPost.where(published: true)
    base.unscope(where: :published)
    titles(base).should eq(["a", "c"])
  end

  it "does nothing for a column with no condition" do
    titles(WfPost.where(published: true).unscope(where: :score)).should eq(["a", "c"])
  end

  it "resolves a belongs_to name to its foreign key" do
    author = WfAuthor.first!
    relation = WfPost.where(author: author, published: true).unscope(where: :author)
    titles(relation).should eq(["a", "c"])
  end

  it "unscopes includes, preload and eager_load" do
    relation = WfPost.includes(:author).preload(:tags).eager_load(:comments)
    relation.unscope(:includes).includes_associations.should be_empty
    relation.unscope(:preload).preload_associations.should be_empty
    relation.unscope(:eager_load).eager_load_associations.should be_empty
    relation.unscope(:includes).preload_associations.should_not be_empty
  end

  it "still rejects unknown components" do
    expect_raises(ArgumentError, /unknown component/) { WfPost.where(score: 1).unscope(:nonsense) }
  end
end
