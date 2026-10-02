require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V01Article < Grant::Base
    connection {{ adapter_literal }}
    table v01_articles

    column id : Int64, primary: true
    column title : String?
    column slug : String?
    column summary : String?
    column notes : String?

    property seen_contexts = [] of Symbol?

    validates_presence_of :title
    validates_presence_of :slug, on: :create
    validates_presence_of :notes, on: :update
    validates_presence_of :summary, on: :publish
    validate :record_context

    before_validation :note_before, on: :create
    after_validation :note_after, on: [:update, :publish]

    private def record_context
      seen_contexts << validation_context
    end

    private def note_before
      seen_contexts << :before_create
    end

    private def note_after
      seen_contexts << :after_update_or_publish
    end
  end

  class V01ArticleSubclass < V01Article
  end
{% end %}

Spec.before_suite do
  V01Article.migrator.drop_and_create
end

private def fresh_article(**attrs) : V01Article
  article = V01Article.new
  article.title = "Title"
  article.slug = "slug"
  attrs.each do |key, value|
    case key
    when :summary then article.summary = value.as(String?)
    when :notes   then article.notes = value.as(String?)
    when :title   then article.title = value.as(String?)
    when :slug    then article.slug = value.as(String?)
    end
  end
  article
end

describe "validation contexts" do
  describe "default context" do
    it "is :create for a new record: on: :update validators do not run" do
      article = fresh_article(notes: nil)
      article.valid?.should be_true
      article.errors.empty?.should be_true
    end

    it "runs on: :create validators for a new record" do
      article = fresh_article(slug: nil)
      article.valid?.should be_false
      article.errors.map(&.field.to_s).should eq(["slug"])
    end

    it "is :update for a persisted record: on: :create validators do not run" do
      article = fresh_article(notes: "n")
      article.save.should be_true
      article.persisted?.should be_true

      article.slug = nil
      article.notes = nil
      article.valid?.should be_false
      article.errors.map(&.field.to_s).should eq(["notes"])
    end

    it "does not run custom-context validators by default" do
      fresh_article(summary: nil).valid?.should be_true
    end
  end

  describe "custom contexts" do
    it "runs on: :publish validators plus the ones without on:" do
      article = fresh_article(summary: nil, title: nil)
      article.valid?(:publish).should be_false
      article.errors.map(&.field.to_s).sort.should eq(["summary", "title"])
    end

    it "does not run :create or :update validators in a custom context" do
      article = fresh_article(slug: nil, notes: nil, summary: "s")
      article.valid?(:publish).should be_true
    end

    it "accepts the positional and keyword forms" do
      article = fresh_article(summary: nil)
      article.valid?(:publish).should be_false
      article.valid?(context: :publish).should be_false
      article.invalid?(:publish).should be_true
      article.invalid?(context: :publish).should be_true
      article.valid?(context: [:create, :publish]).should be_false
      article.valid?(:other).should be_true
    end

    it "runs every validator for an explicit :save context" do
      article = fresh_article(slug: nil, notes: nil, summary: nil)
      article.valid?(:save).should be_false
      article.errors.map(&.field.to_s).sort.should eq(["notes", "slug", "summary"])
    end

    it "applies to subclasses" do
      article = V01ArticleSubclass.new
      article.title = "t"
      article.slug = "s"
      article.valid?(:publish).should be_false
    end
  end

  describe "save(context:)" do
    it "validates with the given context" do
      article = fresh_article(summary: nil)
      article.save.should be_true # :create; summary is only required on :publish

      other = fresh_article(summary: nil)
      other.save(context: :publish).should be_false
      other.persisted?.should be_false
      other.errors.map(&.field.to_s).should eq(["summary"])

      other.summary = "now present"
      other.save(context: :publish).should be_true
      other.persisted?.should be_true
    end

    it "accepts an Array of contexts and save!" do
      article = fresh_article(summary: nil, notes: nil)
      ex = expect_raises(Grant::RecordInvalid) do
        article.save!(context: [:create, :update])
      end
      ex.record.errors.map(&.field.to_s).should eq(["notes"])
    end

    it "raises RecordInvalid from save! for a custom context" do
      article = fresh_article(summary: nil)
      expect_raises(Grant::RecordInvalid, /Summary can't be blank/) do
        article.save!(context: :publish)
      end
    end

    it "supports context: on the hash forms of create, create! and update" do
      created = V01Article.create({"title" => "T", "slug" => "s"}, context: :publish)
      created.persisted?.should be_false

      expect_raises(Grant::RecordInvalid) do
        V01Article.create!({"title" => "T", "slug" => "s"}, context: :publish)
      end

      ok = V01Article.create!({"title" => "T", "slug" => "s", "summary" => "x"}, context: :publish)
      ok.persisted?.should be_true
      ok.update({"notes" => "n"}, context: :publish).should be_true
      ok.update({"summary" => ""}, context: :publish).should be_false
      expect_raises(Grant::RecordInvalid) { ok.update!({"summary" => ""}, context: :publish) }
    end

    it "skips validation entirely with validate: false" do
      article = fresh_article(summary: nil)
      article.save(validate: false, context: :publish).should be_true
    end
  end

  describe "validation_context accessor" do
    it "is nil outside validation" do
      article = fresh_article
      article.validation_context.should be_nil
      article.validation_contexts.should eq([] of Symbol)
    end

    it "is visible to custom validators during valid?" do
      article = fresh_article
      article.valid?
      article.seen_contexts.should contain(:create)

      article.seen_contexts.clear
      article.valid?(:publish)
      article.seen_contexts.should contain(:publish)
      article.validation_context.should be_nil
    end

    it "is the context save derives, and is restored afterwards" do
      article = fresh_article
      article.save.should be_true
      article.seen_contexts.should contain(:create)
      article.seen_contexts.clear
      article.notes = "needed on update"
      article.save.should be_true
      article.seen_contexts.should contain(:update)
      article.validation_context.should be_nil
    end
  end

  describe "on: for before_validation / after_validation" do
    it "runs a callback only in its contexts" do
      article = fresh_article
      article.valid?(:create)
      article.seen_contexts.should contain(:before_create)
      article.seen_contexts.should_not contain(:after_update_or_publish)

      article.seen_contexts.clear
      article.valid?(:update)
      article.seen_contexts.should_not contain(:before_create)
      article.seen_contexts.should contain(:after_update_or_publish)

      article.seen_contexts.clear
      article.valid?(:publish)
      article.seen_contexts.should contain(:after_update_or_publish)
    end

    it "uses the default context when none is given" do
      article = fresh_article
      article.valid?
      article.seen_contexts.should contain(:before_create)
      article.save.should be_true
      article.seen_contexts.clear
      article.valid?
      article.seen_contexts.should contain(:after_update_or_publish)
    end
  end

  describe "positional valid? on a fresh record" do
    it "does not change the errors of a valid record" do
      fresh_article.valid?(:publish).should be_false # summary missing
      fresh_article(summary: "s").valid?(:publish).should be_true
    end
  end
end
