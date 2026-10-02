require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6VwCounter < Grant::Base
  end

  module W6Vw
    # The typed form: the record arrives as the model, not as Grant::Base.
    class EvenValidator < Grant::TypedValidator(W6VwCounter)
      def validate(record : W6VwCounter)
        # A message only: the validator's kind becomes the error's type.
        record.errors.add(:value, "must be even") if record.value.odd?
      end
    end

    class LimitValidator < Grant::Validator
      def validate(record)
        counter = record.as(W6VwCounter)
        limit = options[:limit].as(Int32)
        counter.errors.add(:value, :too_big, count: limit, message: options[:message].as(String)) if counter.value > limit
      end
    end

    class StrictCheckValidator < Grant::Validator
      def validate(record)
        record.errors.add(:base, "first problem", type: :first)
        record.errors.add(:base, "second problem", type: :second)
      end
    end

    class NicknamePresenceValidator < Grant::EachValidator
      def validate_each(record, attribute, value)
        record.errors.add(attribute, :blank) if value.nil? || value.to_s.blank?
      end
    end

    class PlainValidator < Grant::Validator
      def validate(record)
        record.errors.add(:base, "plain problem")
      end
    end
  end

  class W6VwCounter < Grant::Base
    connection {{ adapter_literal }}
    table w6_vw_counters

    column id : Int64, primary: true
    column value : Int32 = 0

    property nickname : String?
    property mode : Symbol = :none

    validates_with W6Vw::EvenValidator, if: ->(record : W6VwCounter) { record.mode == :even }
    validates_with W6Vw::LimitValidator, limit: 10, message: "is over the limit", if: ->(record : W6VwCounter) { record.mode == :limit }
    validates_with W6Vw::NicknamePresenceValidator, :nickname, if: ->(record : W6VwCounter) { record.mode == :each }
    validates_with W6Vw::PlainValidator, on: :audit
  end

  class W6VwStrict < Grant::Base
    connection {{ adapter_literal }}
    table w6_vw_stricts

    column id : Int64, primary: true

    validates_with W6Vw::StrictCheckValidator, strict: true
  end
{% end %}

describe "validates_with" do
  before_all do
    W6VwCounter.migrator.drop_and_create
    W6VwStrict.migrator.drop_and_create
  end

  it "derives the validator's kind from its class name" do
    W6Vw::EvenValidator.kind.should eq(:even)
    W6Vw::LimitValidator.kind.should eq(:limit)
    W6Vw::NicknamePresenceValidator.kind.should eq(:nickname_presence)
  end

  it "hands a TypedValidator(T) the record as T" do
    counter = W6VwCounter.new(value: 3)
    counter.mode = :even
    counter.valid?.should be_false
    counter.errors[:value].should eq(["must be even"])
    counter.value = 4
    counter.valid?.should be_true
  end

  it "ties errors added without a type to the validator's kind" do
    counter = W6VwCounter.new(value: 3)
    counter.mode = :even
    counter.valid?
    counter.errors.first.type.should eq(:even)
    counter.errors.details["value"].should eq([{:error => :even}])
    counter.errors.of_type(:value, :even).should be_true
  end

  it "keeps a type the validator set itself" do
    counter = W6VwCounter.new(value: 3)
    counter.mode = :limit
    counter.value = 11
    counter.valid?.should be_false
    counter.errors.first.type.should eq(:too_big)
  end

  it "exposes the keyword options as validator.options" do
    counter = W6VwCounter.new(value: 11)
    counter.mode = :limit
    counter.valid?.should be_false
    counter.errors[:value].should eq(["is over the limit"])
    counter.errors.details["value"].should eq([{:error => :too_big, :count => 10}])
    validator = W6Vw::LimitValidator.new(limit: 7, name: "x")
    validator.options.should eq({:limit => 7, :name => "x"})
    W6Vw::EvenValidator.new.options.should be_empty
  end

  it "does not pass on:, if:, unless: or strict: as options" do
    validator = W6Vw::StrictCheckValidator.new
    validator.options.should be_empty
  end

  it "reads virtual (non-column) attributes for an EachValidator" do
    counter = W6VwCounter.new(value: 2)
    counter.mode = :each
    counter.valid?.should be_false
    counter.errors[:nickname].should eq(["can't be blank"])
    counter.nickname = "nick"
    counter.valid?.should be_true
    counter.__read_attribute_for_validation("nickname").should eq("nick")
    counter.__read_attribute_for_validation("value").should eq(2)
    counter.__read_attribute_for_validation("nope").should be_nil
  end

  it "runs only in its on: context" do
    counter = W6VwCounter.new(value: 2)
    counter.valid?.should be_true
    counter.valid?(:audit).should be_false
    counter.errors.first.type.should eq(:plain)
  end

  it "leaves no errors behind when strict: raises" do
    record = W6VwStrict.new
    expect_raises(Grant::StrictValidationFailed, /first problem/) { record.valid? }
    record.errors.should be_empty
  end

  it "reports validates_with in validators" do
    W6VwCounter.validators.select { |info| info.kind == :with }.size.should eq(4)
  end

  it "saves a valid record and raises Grant::RecordInvalid for an invalid one" do
    counter = W6VwCounter.new(value: 3)
    counter.mode = :even
    expect_raises(Grant::RecordInvalid, "Validation failed: Value must be even") { counter.save! }
    counter.value = 4
    counter.save!.should be_true
    W6VwCounter.find!(counter.id).value.should eq(4)
  end
end
