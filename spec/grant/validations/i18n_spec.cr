require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02iBlogPost < Grant::Base
    connection {{ adapter_literal }}
    table v02i_blog_posts

    column id : Int64, primary: true
    column first_name : String?
    column author_id : Int64?

    validates_presence_of :first_name
  end

  module V02iAdmin
    class Widget < Grant::Base
      connection {{ adapter_literal }}
      table v02i_widgets

      column id : Int64, primary: true
      column label : String?
    end
  end
{% end %}

# A translator that answers in German, the way an app would wrap its i18n shard.
class V02iGermanTranslator < Grant::I18n::Translator
  TABLE = {
    "de.errors.messages.blank"                => "darf nicht leer sein",
    "de.errors.messages.too_short"            => "ist zu kurz (mindestens %{count} Zeichen)",
    "de.errors.format"                        => "%{message} (%{attribute})",
    "de.attributes.v02i_blog_post.first_name" => "Vorname",
  }

  def translate(locale : String, key : String) : String?
    TABLE["#{locale}.#{key}"]?
  end
end

describe "Grant::I18n" do
  after_each do
    Grant::I18n.translator = Grant::I18n::DefaultTranslator.new
    Grant::I18n.locale = "en"
  end

  describe ".human_attribute_name" do
    it "defaults to the humanized attribute" do
      V02iBlogPost.human_attribute_name(:first_name).should eq("First name")
      V02iBlogPost.human_attribute_name("first_name").should eq("First name")
      V02iBlogPost.human_attribute_name(:author_id).should eq("Author")
    end

    it "uses attributes.<model>.<attribute> and then attributes.<attribute> translations" do
      Grant::I18n.store("attributes.v02i_blog_post.first_name", "Given name")
      Grant::I18n.store("attributes.author_id", "Written by")
      V02iBlogPost.human_attribute_name(:first_name).should eq("Given name")
      V02iBlogPost.human_attribute_name(:author_id).should eq("Written by")
    end

    it "is used by full messages" do
      Grant::I18n.store("attributes.v02i_blog_post.first_name", "Given name")
      post = V02iBlogPost.new
      post.valid?.should be_false
      post.errors.full_messages.should eq(["Given name can't be blank"])
    end
  end

  describe ".model_name" do
    it "names the model" do
      name = V02iBlogPost.model_name
      name.name.should eq("V02iBlogPost")
      name.human.should eq("V02i blog post")
      name.i18n_key.should eq("v02i_blog_post")
      name.param_key.should eq("v02i_blog_post")
      name.element.should eq("v02i_blog_post")
    end

    it "handles namespaced models" do
      name = V02iAdmin::Widget.model_name
      name.name.should eq("V02iAdmin::Widget")
      name.i18n_key.should eq("v02i_admin/widget")
      name.param_key.should eq("v02i_admin_widget")
      name.singular.should eq("v02i_admin_widget")
      name.element.should eq("widget")
      name.human.should eq("Widget")
    end

    it "translates the human name" do
      Grant::I18n.store("models.v02i_admin/widget", "Gadget")
      V02iAdmin::Widget.model_name.human.should eq("Gadget")
    end
  end

  describe "pluggable translator" do
    it "serves messages, attribute names and the format from the installed translator" do
      Grant::I18n.translator = V02iGermanTranslator.new
      Grant::I18n.locale = "de"

      post = V02iBlogPost.new
      post.valid?.should be_false
      post.errors[:first_name].should eq(["darf nicht leer sein"])
      post.errors.full_messages.should eq(["darf nicht leer sein (Vorname)"])

      post.errors.add(:first_name, :too_short, count: 2)
      post.errors[:first_name].last.should eq("ist zu kurz (mindestens 2 Zeichen)")
    end

    it "falls back to the built-in wording for keys the translator lacks" do
      Grant::I18n.translator = V02iGermanTranslator.new
      Grant::I18n.locale = "de"
      Grant::Errors.new.generate_message(:x, :invalid).should eq("is invalid")
    end

    it "switching the translator or locale drops cached lookups" do
      post = V02iBlogPost.new
      post.errors.add(:first_name, :blank)
      post.errors.first.message.should eq("can't be blank")

      Grant::I18n.translator = V02iGermanTranslator.new
      Grant::I18n.locale = "de"
      other = V02iBlogPost.new
      other.errors.add(:first_name, :blank)
      other.errors.first.message.should eq("darf nicht leer sein")
    end

    it "stores per locale on the default translator" do
      Grant::I18n.store("errors.messages.blank", "no puede estar en blanco", "es")
      Grant::I18n.locale = "es"
      Grant::Errors.new.generate_message(:x, :blank).should eq("no puede estar en blanco")
      Grant::I18n.locale = "en"
      Grant::Errors.new.generate_message(:x, :blank).should eq("can't be blank")
    end

    it "refuses to store into a custom translator" do
      Grant::I18n.translator = V02iGermanTranslator.new
      expect_raises(ArgumentError, /default translator/) { Grant::I18n.store("a", "b") }
    end
  end

  describe "interpolation" do
    it "fills %{attribute}, %{model} and any option" do
      Grant::I18n.store("errors.messages.custom", "for %{attribute} on %{model}: %{count}/%{other}")
      post = V02iBlogPost.new
      post.errors.add(:first_name, :custom, count: 2, other: "x")
      post.errors[:first_name].should eq(["for First name on V02i blog post: 2/x"])
    end

    it "leaves unknown placeholders alone" do
      Grant::I18n.store("errors.messages.custom", "has %{nothing}")
      Grant::Errors.new.generate_message(:x, :custom).should eq("has %{nothing}")
    end
  end
end
