require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02uArticle < Grant::Base
    connection {{ adapter_literal }}
    table v02u_articles

    column id : Int64, primary: true
    column slug : String?
    column status : String?
    column order : String?
    column nickname : String?
    column code : String?

    validates_uniqueness_of :slug, conditions: ->(query : Grant::Query::Builder(V02uArticle)) { query.where(status: "live") }
    validates_uniqueness_of :order, case_sensitive: false, on: :create
    validates_uniqueness_of :nickname, allow_blank: true
    validates_uniqueness_of :code, conditions: ->(query : Grant::Query::Builder(V02uArticle), article : V02uArticle) { query.where("status != ?", article.status) }
  end

  class V02uAuthor < Grant::Base
    connection {{ adapter_literal }}
    table v02u_authors

    column id : Int64, primary: true
    column name : String?
  end

  class V02uBook < Grant::Base
    connection {{ adapter_literal }}
    table v02u_books

    column id : Int64, primary: true
    column title : String?
    belongs_to v02u_author : V02uAuthor

    validates_uniqueness_of :title, scope: :v02u_author
  end
{% end %}

describe "validates_uniqueness_of options" do
  before_all do
    V02uArticle.migrator.drop_and_create
    V02uAuthor.migrator.drop_and_create
    V02uBook.migrator.drop_and_create
  end

  before_each do
    V02uArticle.clear
    V02uBook.clear
    V02uAuthor.clear
  end

  describe "conditions:" do
    it "narrows the rows compared with a typed builder proc" do
      V02uArticle.create!(slug: "intro", status: "draft")
      V02uArticle.new(slug: "intro", status: "live").valid?.should be_true # only live rows are compared

      V02uArticle.create!(slug: "intro", status: "live")
      duplicate = V02uArticle.new(slug: "intro", status: "draft")
      duplicate.valid?.should be_false
      duplicate.errors[:slug].should eq(["has already been taken"])
    end

    it "does not count rows the proc filters out" do
      V02uArticle.create!(slug: "old", status: "archived")
      V02uArticle.new(slug: "old", status: "live").valid?.should be_true
    end

    it "passes the record as a second argument when the proc takes it" do
      V02uArticle.create!(code: "A-1", status: "one")
      V02uArticle.new(code: "A-1", status: "one").valid?.should be_true
      V02uArticle.new(code: "A-1", status: "two").valid?.should be_false
    end
  end

  describe "quoted identifiers" do
    it "compares a reserved-word column case-insensitively" do
      V02uArticle.create!(order: "First")
      duplicate = V02uArticle.new(order: "FIRST")
      duplicate.valid?.should be_false
      duplicate.errors.first.type.should eq(:taken)
      V02uArticle.new(order: "Second").valid?.should be_true
    end

    it "quotes the identifiers of the comparison and the primary key exclusion" do
      article = V02uAuthor.create!(name: "Only")
      V02uAuthor.find!(article.id).valid?.should be_true
      V02uArticle.create!(order: "Only")
      duplicate = V02uArticle.new(order: "ONLY")
      duplicate.valid?.should be_false
    end
  end

  describe "allow_blank:" do
    it "skips blank values, so several records may have an empty value" do
      V02uArticle.create!(nickname: "")
      V02uArticle.new(nickname: "").valid?.should be_true
      V02uArticle.new(nickname: "   ").valid?.should be_true
    end

    it "still checks present values" do
      V02uArticle.create!(nickname: "neo")
      V02uArticle.new(nickname: "neo").valid?.should be_false
    end
  end

  describe "scope: naming a belongs_to association" do
    it "scopes by the association's foreign key" do
      first_author = V02uAuthor.create!(name: "A")
      second_author = V02uAuthor.create!(name: "B")
      V02uBook.create!(title: "Draft", v02u_author_id: first_author.id)

      V02uBook.new(title: "Draft", v02u_author_id: first_author.id).valid?.should be_false
      V02uBook.new(title: "Draft", v02u_author_id: second_author.id).valid?.should be_true
    end
  end

  describe "validator reflection" do
    it "records the uniqueness kind and its options" do
      infos = V02uBook.validators_on(:title)
      infos.map(&.kind).should eq([:uniqueness])
    end
  end
end
