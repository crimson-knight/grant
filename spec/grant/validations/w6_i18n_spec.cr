require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6IProfile < Grant::Base
    connection {{ adapter_literal }}
    table w6_i_profiles

    column id : Int64, primary: true
    column nick : String?
    column email : String?
    column website : String?
    column age : Int32?
    column pin : String?
    column ended_on : Int32?
    column started_on : Int32?

    validates_length_of :nick, minimum: 3, maximum: 6
    validates_length_of :pin, is: 4
    validates_email :email
    validates_url :website
    validates_comparison_of :age, greater_than_or_equal_to: 18, allow_nil: true
    validates_comparison_of :ended_on, greater_than: :started_on, allow_nil: true
  end
{% end %}

# Answers in German for the "de" locale and in English for everything else.
class W6IGermanTranslator < Grant::I18n::Translator
  TABLE = {
    "de.errors.messages.too_short"                            => "ist zu kurz (mindestens %{count} Zeichen)",
    "de.errors.messages.too_long"                             => "ist zu lang (hoechstens %{count} Zeichen)",
    "de.errors.messages.wrong_length"                         => "hat die falsche Laenge (%{count} Zeichen erwartet)",
    "de.errors.messages.invalid_email"                        => "ist keine gueltige E-Mail-Adresse",
    "de.errors.messages.invalid_url"                          => "ist keine gueltige URL",
    "de.errors.messages.greater_than_or_equal_to"             => "muss mindestens %{count} sein",
    "de.errors.messages.greater_than"                         => "muss groesser als %{count} sein",
    "de.errors.format"                                        => "%{attribute}: %{message}",
    "de.attributes.w6_i_profile.nick"                         => "Spitzname",
    "de.errors.models.w6_i_profile.attributes.nick.too_short" => "ist fuer einen Spitznamen zu kurz",
  }

  def translate(locale : String, key : String) : String?
    TABLE["#{locale}.#{key}"]? || (locale == "en" ? Grant::I18n::DefaultTranslator::MESSAGES[key]? : nil)
  end
end

private def w6_profile(**attributes)
  profile = W6IProfile.new(**attributes)
  profile.valid?
  profile
end

describe "Grant::I18n for every built-in validator" do
  before_all do
    W6IProfile.migrator.drop_and_create
  end

  after_each do
    Grant::I18n.translator = Grant::I18n::DefaultTranslator.new
    Grant::I18n.locale = "en"
  end

  describe "default English messages" do
    it "uses the ActiveRecord wording for length" do
      profile = w6_profile(nick: "ab", pin: "123", email: "a@b.co", website: "https://a.co")
      profile.errors[:nick].should eq(["is too short (minimum is 3 characters)"])
      profile.errors[:pin].should eq(["is the wrong length (should be 4 characters)"])
      w6_profile(nick: "abcdefg", pin: "1234", email: "a@b.co", website: "https://a.co").errors[:nick].should eq(["is too long (maximum is 6 characters)"])
    end

    it "uses the translator for email and url" do
      profile = w6_profile(nick: "abc", pin: "1234", email: "nope", website: "nope")
      profile.errors[:email].should eq(["is not a valid email"])
      profile.errors[:website].should eq(["is not a valid URL"])
      profile.errors.first.type.should eq(:invalid)
    end

    it "uses the translator for comparison" do
      profile = w6_profile(nick: "abc", pin: "1234", email: "a@b.co", website: "https://a.co", age: 12, started_on: 5, ended_on: 3)
      profile.errors[:age].should eq(["must be greater than or equal to 18"])
      profile.errors[:ended_on].should eq(["must be greater than 5"])
    end
  end

  describe "overrides" do
    it "lets an application store a message for the length, email, url and comparison keys" do
      Grant::I18n.store("errors.messages.too_short", "needs %{count}+ characters")
      Grant::I18n.store("errors.messages.invalid_email", "looks wrong")
      Grant::I18n.store("errors.messages.greater_than_or_equal_to", "is under %{count}")
      profile = w6_profile(nick: "ab", pin: "1234", email: "nope", website: "https://a.co", age: 3)
      profile.errors[:nick].should eq(["needs 3+ characters"])
      profile.errors[:email].should eq(["looks wrong"])
      profile.errors[:age].should eq(["is under 18"])
    end

    it "lets a per-model, per-attribute key win" do
      Grant::I18n.store("errors.models.w6_i_profile.attributes.email.invalid_email", "needs an @")
      w6_profile(nick: "abc", pin: "1234", email: "nope", website: "https://a.co").errors[:email].should eq(["needs an @"])
    end
  end

  describe "a custom translator" do
    it "translates length, comparison, email and url, humanized attribute names and the format" do
      Grant::I18n.translator = W6IGermanTranslator.new
      Grant::I18n.with_locale("de") do
        profile = w6_profile(nick: "ab", pin: "123", email: "nope", website: "nope", age: 3, started_on: 5, ended_on: 3)
        profile.errors[:nick].should eq(["ist fuer einen Spitznamen zu kurz"])
        profile.errors[:pin].should eq(["hat die falsche Laenge (4 Zeichen erwartet)"])
        profile.errors[:email].should eq(["ist keine gueltige E-Mail-Adresse"])
        profile.errors[:website].should eq(["ist keine gueltige URL"])
        profile.errors[:age].should eq(["muss mindestens 18 sein"])
        profile.errors[:ended_on].should eq(["muss groesser als 5 sein"])
        profile.errors.full_messages.first.should eq("Spitzname: ist fuer einen Spitznamen zu kurz")
      end
    end
  end

  describe "fiber-local locale" do
    it "applies inside with_locale and restores the previous locale after it" do
      Grant::I18n.translator = W6IGermanTranslator.new
      Grant::I18n.locale.should eq("en")
      Grant::I18n.with_locale("de") do
        Grant::I18n.locale.should eq("de")
        Grant::I18n.with_locale("en") { Grant::I18n.locale.should eq("en") }
        Grant::I18n.locale.should eq("de")
      end
      Grant::I18n.locale.should eq("en")
      w6_profile(nick: "ab", pin: "1234", email: "a@b.co", website: "https://a.co").errors[:nick].should eq(["is too short (minimum is 3 characters)"])
    end

    it "restores the locale when the block raises" do
      expect_raises(Exception, "boom") do
        Grant::I18n.with_locale("de") { raise "boom" }
      end
      Grant::I18n.locale.should eq("en")
    end

    it "does not leak into other fibers" do
      Grant::I18n.translator = W6IGermanTranslator.new
      german = Channel(String).new
      english = Channel(String).new
      started = Channel(Nil).new
      release = Channel(Nil).new

      spawn do
        Grant::I18n.with_locale("de") do
          started.send(nil)
          release.receive
          german.send(w6_profile(nick: "ab", pin: "1234", email: "a@b.co", website: "https://a.co").errors[:nick].first)
        end
      end

      started.receive
      # The other fiber is inside with_locale("de") right now.
      spawn { english.send(w6_profile(nick: "ab", pin: "1234", email: "a@b.co", website: "https://a.co").errors[:nick].first) }
      english.receive.should eq("is too short (minimum is 3 characters)")
      release.send(nil)
      german.receive.should eq("ist fuer einen Spitznamen zu kurz")
      Grant::I18n.locale.should eq("en")
    end

    it "caches messages per locale" do
      Grant::I18n.translator = W6IGermanTranslator.new
      3.times do
        Grant::I18n.with_locale("de") { w6_profile(nick: "ab", pin: "1234", email: "a@b.co", website: "https://a.co").errors[:email].should be_empty }
        w6_profile(nick: "ab", pin: "1234", email: "nope", website: "https://a.co").errors[:email].should eq(["is not a valid email"])
        Grant::I18n.with_locale("de") { w6_profile(nick: "abc", pin: "1234", email: "nope", website: "https://a.co").errors[:email].should eq(["ist keine gueltige E-Mail-Adresse"]) }
      end
    end

    it "changes human_attribute_name and the errors.format template per fiber" do
      Grant::I18n.translator = W6IGermanTranslator.new
      W6IProfile.human_attribute_name(:nick).should eq("Nick")
      Grant::I18n.with_locale("de") { W6IProfile.human_attribute_name(:nick).should eq("Spitzname") }
      W6IProfile.human_attribute_name(:nick).should eq("Nick")
      Grant::I18n.with_locale("de") { Grant::I18n.full_message("Name", "ist leer").should eq("Name: ist leer") }
      Grant::I18n.full_message("Name", "is empty").should eq("Name is empty")
    end

    it "keeps the process default separate from the fiber override" do
      Grant::I18n.translator = W6IGermanTranslator.new
      Grant::I18n.locale = "de"
      w6_profile(nick: "ab", pin: "1234", email: "a@b.co", website: "https://a.co").errors[:nick].should eq(["ist fuer einen Spitznamen zu kurz"])
      Grant::I18n.with_locale("en") { Grant::I18n.locale.should eq("en") }
      Grant::I18n.locale.should eq("de")
    end
  end
end
