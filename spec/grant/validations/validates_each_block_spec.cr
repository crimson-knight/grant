require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V01EachBlock < Grant::Base
    connection {{ adapter_literal }}
    table v01_each_blocks

    column id : Int64, primary: true
    column first_name : String?
    column last_name : String?
    column nickname : String?
    column skip_names : Bool = false

    property calls = [] of String

    validates_each :first_name, :last_name, allow_nil: true do |record, attr, value|
      record.calls << "#{attr}:#{value}"
      record.errors.add(attr, "must start with a capital letter", type: :capitalized) if value[0]? && value[0].lowercase?
    end

    validates_each :nickname, allow_blank: true, unless: :skip_names? do |rec, name, val|
      rec.errors.add(name, "is too short") if val.to_s.size < 3
    end

    validates_each :last_name do |record, attr, value|
      next if value.nil?
      next unless value.includes?(" ")
      record.errors.add(attr, "must be one word", type: :one_word)
    end

    def skip_names? : Bool
      !!skip_names
    end
  end

  class V01EachWithClass < Grant::Base
    connection {{ adapter_literal }}
    table v01_each_with_classes

    column id : Int64, primary: true
    column title : String?

    validates_each :title, with: V01NotShoutingValidator
  end
{% end %}

class V01NotShoutingValidator < Grant::EachValidator
  def validate_each(record, attribute, value)
    record.errors.add(attribute, "is shouting", type: :shouting) if value.to_s == value.to_s.upcase && !value.to_s.empty?
  end
end

describe "validates_each block form" do
  it "runs the block once per attribute with the record, attribute and value" do
    record = V01EachBlock.new
    record.first_name = "Ada"
    record.last_name = "Byron"
    record.valid?.should be_true
    record.calls.should eq(["first_name:Ada", "last_name:Byron"])
  end

  it "records errors added by the block" do
    record = V01EachBlock.new
    record.first_name = "ada"
    record.last_name = "Byron"
    record.valid?.should be_false
    record.errors.map(&.field.to_s).should eq(["first_name"])
    record.errors.first.message.should eq("must start with a capital letter")
    record.errors.first.type.should eq(:capitalized)
  end

  it "reports each failing attribute separately" do
    record = V01EachBlock.new
    record.first_name = "ada"
    record.last_name = "byron"
    record.valid?.should be_false
    record.errors.map(&.field.to_s).should eq(["first_name", "last_name"])
  end

  it "honors allow_nil: by not calling the block" do
    record = V01EachBlock.new
    record.valid?.should be_true
    record.calls.should be_empty
  end

  it "honors allow_blank: and unless:" do
    record = V01EachBlock.new
    record.nickname = ""
    record.valid?.should be_true

    record.nickname = "ab"
    record.valid?.should be_false
    record.errors.map(&.field.to_s).should eq(["nickname"])

    record.skip_names = true
    record.valid?.should be_true
  end

  it "lets a bare next skip the rest of the block" do
    record = V01EachBlock.new
    record.first_name = "Ada"
    record.valid?.should be_true
    record.last_name = "Byron"
    record.valid?.should be_true
    record.last_name = "Von Byron"
    record.valid?.should be_false
    record.errors.map(&.type).should eq([:one_word])
  end

  it "still supports with: naming an EachValidator subclass" do
    record = V01EachWithClass.new
    record.title = "quiet"
    record.valid?.should be_true
    record.title = "LOUD"
    record.valid?.should be_false
    record.errors.first.type.should eq(:shouting)
  end

  it "reads attributes through the typed reader, not to_h" do
    record = V01EachWithClass.new
    record.title = "QUIET"
    validator = V01NotShoutingValidator.new(:title, :id)
    validator.validate(record)
    record.errors.map(&.field.to_s).should eq(["title"])
  end
end
