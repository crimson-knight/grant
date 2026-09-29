require "../../spec_helper"
require "../../support/relation_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class EaAuthor < Grant::Base
    connection {{ adapter_literal }}
    table ea_authors
    column id : Int64, primary: true
    column name : String
    has_many :articles, class_name: EaArticle, foreign_key: :ea_author_id
  end

  class EaArticle < Grant::Base
    connection {{ adapter_literal }}
    table ea_articles
    column id : Int64, primary: true
    column title : String
    column published : Bool = false
    column ea_author_id : Int64?
    belongs_to :ea_author, class_name: EaAuthor, foreign_key: :ea_author_id, optional: true
  end
{% end %}

describe "extract_associated" do
  before_all do
    EaAuthor.migrator.drop_and_create
    EaArticle.migrator.drop_and_create
  end

  before_each do
    EaArticle.clear
    EaAuthor.clear
    ada = EaAuthor.create!(name: "Ada")
    grace = EaAuthor.create!(name: "Grace")
    EaAuthor.create!(name: "Unpublished")
    EaArticle.create!(title: "A1", published: true, ea_author_id: ada.id)
    EaArticle.create!(title: "A2", published: true, ea_author_id: ada.id)
    EaArticle.create!(title: "G1", published: true, ea_author_id: grace.id)
    EaArticle.create!(title: "Draft", published: false, ea_author_id: grace.id)
    EaArticle.create!(title: "Orphan", published: true)
  end

  it "returns the belongs_to targets, unique by primary key" do
    authors = EaArticle.where(published: true).order(:id).extract_associated(:ea_author)
    authors.map { |author| author.as(EaAuthor).name }.should eq(["Ada", "Grace"])
  end

  it "returns has_many members flattened" do
    articles = EaAuthor.order(:id).extract_associated(:articles)
    articles.map { |article| article.as(EaArticle).title }.should eq(["A1", "A2", "G1", "Draft"])
  end

  it "respects the relation's conditions" do
    EaArticle.where(title: "G1").extract_associated(:ea_author).map { |author| author.as(EaAuthor).name }.should eq(["Grace"])
    EaArticle.where(title: "nothing").extract_associated(:ea_author).should be_empty
  end

  it "preloads instead of querying per record" do
    statements = capture_sql { EaAuthor.order(:id).extract_associated(:articles) }
    statements.size.should eq(2)
  end

  it "skips records without the association" do
    EaArticle.where(title: "Orphan").extract_associated(:ea_author).should be_empty
  end

  it "is available on the model class" do
    EaArticle.extract_associated(:ea_author).size.should eq(2)
  end
end
