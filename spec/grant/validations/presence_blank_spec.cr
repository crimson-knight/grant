require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V01PresenceModel < Grant::Base
    connection {{ adapter_literal }}
    table v01_presence_models

    column id : Int64, primary: true
    column title : String?

    property flag : Bool? = true
    property meta : Hash(String, String)? = {"k" => "v"}
    property tags : Array(String)? = ["a"]
    property labels : Set(String)? = Set{"a"}
    property score : Int32? = 1

    validates_presence_of :title, :flag, :meta, :tags, :labels, :score
  end

  class V01PresenceAllowBlank < Grant::Base
    connection {{ adapter_literal }}
    table v01_presence_allow_blanks

    column id : Int64, primary: true
    column code : String?

    validates_presence_of :code, allow_blank: true
    validates_length_of :code, minimum: 3, allow_blank: true
  end

  class V01PresenceContexts < Grant::Base
    connection {{ adapter_literal }}
    table v01_presence_contexts

    column id : Int64, primary: true
    column reason : String?

    validates_presence_of :reason, on: [:update, :publish]
  end
{% end %}

private def valid_presence_model : V01PresenceModel
  model = V01PresenceModel.new
  model.title = "Hello"
  model
end

describe "validates_presence_of blankness (ActiveRecord blank?)" do
  describe "Grant::Validators.blank?" do
    it "treats nil, false, blank strings and empty collections as blank" do
      Grant::Validators.blank?(nil).should be_true
      Grant::Validators.blank?(false).should be_true
      Grant::Validators.blank?("").should be_true
      Grant::Validators.blank?(" \t\n").should be_true
      Grant::Validators.blank?([] of String).should be_true
      Grant::Validators.blank?({} of String => String).should be_true
      Grant::Validators.blank?(Set(String).new).should be_true
    end

    it "treats true, numbers, text and non-empty collections as present" do
      Grant::Validators.blank?(true).should be_false
      Grant::Validators.blank?(0).should be_false
      Grant::Validators.blank?(0.0).should be_false
      Grant::Validators.blank?("x").should be_false
      Grant::Validators.blank?(["x"]).should be_false
      Grant::Validators.blank?({"a" => 1}).should be_false
      Grant::Validators.blank?(:sym).should be_false
      Grant::Validators.blank?(Time.utc).should be_false
    end
  end

  describe "on a model" do
    it "passes when every value is present" do
      valid_presence_model.valid?.should be_true
    end

    it "fails for Bool false" do
      model = valid_presence_model
      model.flag = false
      model.valid?.should be_false
      model.errors.map(&.field.to_s).should eq(["flag"])
      model.errors.first.type.should eq(:blank)
    end

    it "fails for nil Bool" do
      model = valid_presence_model
      model.flag = nil
      model.valid?.should be_false
    end

    it "fails for an empty Hash" do
      model = valid_presence_model
      model.meta = {} of String => String
      model.valid?.should be_false
      model.errors.map(&.field.to_s).should eq(["meta"])
    end

    it "fails for an empty Array and an empty Set" do
      model = valid_presence_model
      model.tags = [] of String
      model.labels = Set(String).new
      model.valid?.should be_false
      model.errors.map(&.field.to_s).should eq(["tags", "labels"])
    end

    it "keeps zero present" do
      model = valid_presence_model
      model.score = 0
      model.valid?.should be_true
    end

    it "fails for a whitespace-only string" do
      model = valid_presence_model
      model.title = "  "
      model.valid?.should be_false
    end
  end

  describe "allow_blank:" do
    it "skips the check (and other validators) for blank values" do
      [nil, "", "   "].each do |value|
        model = V01PresenceAllowBlank.new
        model.code = value
        model.valid?.should be_true
      end
    end

    it "still applies the other validators to non-blank values" do
      model = V01PresenceAllowBlank.new
      model.code = "ab"
      model.valid?.should be_false
      model.errors.first.type.should eq(:too_short)
      model.code = "abc"
      model.valid?.should be_true
    end
  end

  describe "on: an Array of contexts" do
    it "runs in every listed context" do
      model = V01PresenceContexts.new
      model.valid?(:publish).should be_false
      model.valid?(context: :update).should be_false
      model.valid?(context: [:create, :publish]).should be_false
    end

    it "does not run in an unlisted context" do
      model = V01PresenceContexts.new
      model.valid?(:create).should be_true
      model.valid?(:other).should be_true
      model.valid?.should be_true # new record => :create
    end

    it "passes when the value is present" do
      model = V01PresenceContexts.new
      model.reason = "because"
      model.valid?(:publish).should be_true
    end
  end
end
