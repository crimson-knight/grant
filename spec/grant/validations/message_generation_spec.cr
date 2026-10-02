require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02mPost < Grant::Base
    connection {{ adapter_literal }}
    table v02m_posts

    column id : Int64, primary: true
    column title : String?
    column body : String?
    column slug : String?

    validates_presence_of :title
    validates_presence_of :body, message: :body_required
    validates_format_of :slug, with: /\A[a-z-]+\z/, message: ->(post : V02mPost, data : Grant::Error::Options) { "#{post.title} has a bad slug" }, allow_nil: true
  end
{% end %}

# Counts the lookups it serves.
class V02mCountingTranslator < Grant::I18n::Translator
  getter calls = 0
  getter keys = [] of String

  def translate(locale : String, key : String) : String?
    @calls += 1
    @keys << key
    Grant::I18n::DefaultTranslator::MESSAGES[key]?
  end
end

describe "message generation" do
  after_each do
    Grant::I18n.translator = Grant::I18n::DefaultTranslator.new
    Grant::I18n.locale = "en"
  end

  describe "errors.add(attribute, :type, **options)" do
    it "generates the message from the type and interpolates the options" do
      errors = Grant::Errors.new
      errors.add(:name, :too_short, count: 3)
      errors.add(:name, :too_long, count: 20)
      errors.add(:name, :blank)
      errors[:name].should eq([
        "is too short (minimum is 3 characters)",
        "is too long (maximum is 20 characters)",
        "can't be blank",
      ])
      errors.first.type.should eq(:too_short)
    end

    it "uses the message: option (a String, a Symbol key or a Proc) instead of the type's message" do
      errors = Grant::Errors.new
      errors.add(:name, :invalid, message: "is weird")
      errors.add(:name, :invalid, message: :blank)
      errors.add(:name, :too_short, message: ->(record : Grant::Base, data : Grant::Error::Options) { "needs #{data[:count]} more" }, count: 2)
      # (a record is required for Proc messages; the collection below has none)
      errors.first.message.should eq("is weird")
      errors.to_a[1].message.should eq("can't be blank")
      errors.to_a[1].type.should eq(:invalid)
      expect_raises(ArgumentError, /Proc message needs the record/) { errors.to_a[2].message }
    end

    it "gives Proc messages the record and the options when the collection belongs to a record" do
      post = V02mPost.new(title: "T")
      post.errors.add(:title, :too_short, message: ->(record : Grant::Base, data : Grant::Error::Options) { "#{record.as(V02mPost).title}: #{data[:count]}" }, count: 5)
      post.errors[:title].should eq(["T: 5"])
    end

    it "generate_message builds a message without adding an error" do
      errors = Grant::Errors.new
      errors.generate_message(:name, :too_short, count: 3).should eq("is too short (minimum is 3 characters)")
      errors.generate_message(:name).should eq("is invalid")
      errors.should be_empty
    end

    it "falls back to the invalid message for an unknown type" do
      errors = Grant::Errors.new
      errors.add(:name, :no_such_type)
      errors[:name].should eq(["is invalid"])
    end
  end

  describe "validators" do
    it "generates default messages from the type through the translator" do
      post = V02mPost.new
      post.valid?.should be_false
      post.errors[:title].should eq(["can't be blank"])
    end

    it "accepts message: as a Symbol translation key" do
      Grant::I18n.store("errors.messages.body_required", "must not be empty")
      post = V02mPost.new(title: "T")
      post.valid?.should be_false
      post.errors[:body].should eq(["must not be empty"])
      post.errors.details["body"].should eq([{:error => :blank}])
    end

    it "accepts message: as a lambda over the record" do
      post = V02mPost.new(title: "Hello", body: "b", slug: "Bad Slug")
      post.valid?.should be_false
      post.errors[:slug].should eq(["Hello has a bad slug"])
    end

    it "uses per-model and per-attribute overrides" do
      Grant::I18n.store("errors.models.v02m_post.attributes.title.blank", "is required for a post")
      post = V02mPost.new
      post.valid?
      post.errors[:title].should eq(["is required for a post"])
      post.errors.full_messages.first.should eq("Title is required for a post")
    end
  end

  describe "lazy formatting" do
    it "formats nothing until a message is read, then once" do
      translator = V02mCountingTranslator.new
      Grant::I18n.translator = translator

      errors = Grant::Errors.new
      1000.times { errors.add(:name, :too_short, count: 3) }
      translator.calls.should eq(0)

      errors.first.message.should eq("is too short (minimum is 3 characters)")
      calls_for_one_message = translator.calls
      calls_for_one_message.should be > 0

      errors.first.message # memoized on the error
      translator.calls.should eq(calls_for_one_message)
    end

    it "caches the template per (class, attribute, type)" do
      translator = V02mCountingTranslator.new
      Grant::I18n.translator = translator

      posts = Array.new(50) { V02mPost.new }
      posts.each { |post| post.errors.add(:title, :blank) }
      posts.each(&.errors.first.message)
      translator.calls.should be <= 6 # one lookup chain, not fifty
    end

    it "does not touch the translator when a failed validation is never read" do
      translator = V02mCountingTranslator.new
      Grant::I18n.translator = translator
      100.times { V02mPost.new.valid?.should be_false }
      translator.calls.should eq(0)
    end

    it "keeps literal messages free of any lookup" do
      translator = V02mCountingTranslator.new
      Grant::I18n.translator = translator
      errors = Grant::Errors.new
      errors.add(:name, "plain text")
      errors[:name].should eq(["plain text"])
      translator.calls.should eq(0)
    end
  end
end
