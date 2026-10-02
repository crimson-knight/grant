require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6PmArticle < Grant::Base
    connection {{ adapter_literal }}
    table w6_pm_articles

    column id : Int64, primary: true
    column title : String?
    column summary : String?
    column body : String?
    column tags : String?
    column flagged : Bool?

    validates_presence_of :title, message: ->(record : W6PmArticle, data : Grant::Error::Options) { "needs a title (#{record.class.name}, #{data.size} options)" }
    validates_presence_of :summary, message: :w6_summary_required
    validates_presence_of :body, message: "is required", on: [:create, :publish]
    validates_presence_of :tags, allow_blank: true
    validates_presence_of :flagged, message: :w6_flag_required, if: ->(record : W6PmArticle) { record.title == "flag" }
  end
{% end %}

describe "validates_presence_of message:" do
  before_all do
    W6PmArticle.migrator.drop_and_create
  end

  after_each do
    Grant::I18n.translator = Grant::I18n::DefaultTranslator.new
    Grant::I18n.locale = "en"
  end

  it "accepts a Proc taking the record and the error's options" do
    article = W6PmArticle.new(summary: "s", body: "b")
    article.valid?.should be_false
    article.errors[:title].should eq(["needs a title (W6PmArticle, 0 options)"])
    article.errors.first.type.should eq(:blank)
    article.errors.details["title"].should eq([{:error => :blank}])
  end

  it "accepts a Symbol that names a translation key" do
    Grant::I18n.store("errors.messages.w6_summary_required", "must say something")
    article = W6PmArticle.new(title: "t", body: "b")
    article.valid?.should be_false
    article.errors[:summary].should eq(["must say something"])
    article.errors.full_messages.should eq(["Summary must say something"])
    # The error keeps its type: the key only picks the text.
    article.errors.first.type.should eq(:blank)
  end

  it "finds the Symbol key per model and per attribute" do
    Grant::I18n.store("errors.messages.w6_summary_required", "generic")
    Grant::I18n.store("errors.models.w6_pm_article.attributes.summary.w6_summary_required", "model specific")
    article = W6PmArticle.new(title: "t", body: "b")
    article.valid?
    article.errors[:summary].should eq(["model specific"])
  end

  it "falls back to the invalid message for an unknown Symbol key" do
    article = W6PmArticle.new(title: "t", body: "b")
    article.valid?
    article.errors[:summary].should eq(["is invalid"])
  end

  it "accepts a String and honors on: contexts" do
    article = W6PmArticle.new(title: "t", summary: "s")
    article.valid?.should be_false
    article.errors[:body].should eq(["is required"])
    article.valid?(:update).should be_true
    article.valid?(:publish).should be_false
  end

  it "combines with allow_blank:, if: and a Symbol on a Bool column" do
    article = W6PmArticle.new(title: "flag", summary: "s", body: "b", tags: "")
    article.valid?.should be_false
    article.errors.attribute_names.should eq(["flagged"])
    article.errors[:flagged].should eq(["is invalid"])
    article.flagged = true
    article.valid?.should be_true
  end

  it "persists nothing and raises Grant::RecordInvalid with the generated text" do
    Grant::I18n.store("errors.messages.w6_summary_required", "must say something")
    article = W6PmArticle.new(title: "t", body: "b")
    ex = expect_raises(Grant::RecordInvalid, "Validation failed: Summary must say something") { article.save! }
    ex.record.should be(article)
    W6PmArticle.count.should eq(0)
    W6PmArticle.create!(title: "t", summary: "s", body: "b").persisted?.should be_true
  end

  describe "Grant::Validators.blank?" do
    it "follows ActiveRecord's blank? without allocating a String for non-Strings" do
      Grant::Validators.blank?(nil).should be_true
      Grant::Validators.blank?("  \n").should be_true
      Grant::Validators.blank?(false).should be_true
      Grant::Validators.blank?(true).should be_false
      Grant::Validators.blank?(0).should be_false
      Grant::Validators.blank?([] of Int32).should be_true
      Grant::Validators.blank?({} of String => Int32).should be_true
      Grant::Validators.blank?(Set(Int32).new).should be_true
      Grant::Validators.blank?([1]).should be_false
      Grant::Validators.blank?(:name).should be_false
    end
  end
end
