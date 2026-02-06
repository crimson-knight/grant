require "../../spec_helper"

describe "Grant::Validators::BuiltIn::Presence" do
  describe "validates_presence_of" do
    it "validates string is not blank" do
      article = PresenceArticle.new
      article.title = "Hello"
      article.body = "World"
      article.category_id = 1
      article.valid?.should be_true
    end

    it "fails when string field is nil" do
      article = PresenceArticle.new
      article.title = nil
      article.body = "content"
      article.valid?.should be_false
      article.errors.first.field.should eq("title")
      article.errors.first.message.not_nil!.should eq("can't be blank")
    end

    it "fails when string field is blank" do
      article = PresenceArticle.new
      article.title = ""
      article.body = "content"
      article.valid?.should be_false
      article.errors.first.field.should eq("title")
    end

    it "fails when string field is whitespace only" do
      article = PresenceArticle.new
      article.title = "   "
      article.body = "content"
      article.valid?.should be_false
      article.errors.first.field.should eq("title")
    end

    it "validates non-nil for non-string types" do
      article = PresenceArticle.new
      article.title = "Hello"
      article.body = "World"
      article.category_id = nil
      article.valid?.should be_false
      article.errors.map(&.field).should contain("category_id")
    end

    it "passes for non-string non-nil values" do
      article = PresenceArticle.new
      article.title = "Hello"
      article.body = "World"
      article.category_id = 42
      article.valid?.should be_true
    end

    it "supports custom message" do
      article = PresenceArticle.new
      article.title = "Hello"
      article.body = nil
      article.valid?.should be_false
      article.errors.first.message.not_nil!.should eq("is required")
    end

    it "supports if: conditional" do
      article = ConditionalPresenceArticle.new
      article.title = "Hello"
      article.published = false
      article.summary = nil
      # Summary not required when not published
      article.valid?.should be_true

      article.published = true
      article.summary = nil
      article.valid?.should be_false
      article.errors.first.field.should eq("summary")
    end

    it "supports unless: conditional" do
      article = ConditionalPresenceArticle.new
      article.title = "Hello"
      article.published = false
      article.summary = "summary"
      article.draft = true
      article.review_notes = nil
      # review_notes not required when draft
      article.valid?.should be_true

      article.draft = false
      article.published = false
      article.review_notes = nil
      article.valid?.should be_false
      article.errors.map(&.field).should contain("review_notes")
    end

    it "collects multiple presence errors" do
      article = PresenceArticle.new
      article.title = nil
      article.body = nil
      article.category_id = nil
      article.valid?.should be_false
      article.errors.size.should eq(3)
    end
  end
end

# Test models for presence validation
class PresenceArticle < Grant::Base
  connection sqlite
  table presence_articles

  column id : Int64, primary: true
  column title : String?
  column body : String?
  column category_id : Int32?

  validates_presence_of :title
  validates_presence_of :body, message: "is required"
  validates_presence_of :category_id
end

class ConditionalPresenceArticle < Grant::Base
  connection sqlite
  table conditional_presence_articles

  column id : Int64, primary: true
  column title : String?
  column summary : String?
  column review_notes : String?
  column published : Bool = false
  column draft : Bool = true

  validates_presence_of :title
  validates_presence_of :summary, if: :published?

  def published?
    !!published
  end

  validates_presence_of :review_notes, unless: :draft?

  def draft?
    !!draft
  end
end
