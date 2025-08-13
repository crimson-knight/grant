require "../../spec_helper"

enum TestEnum
  Zero
  One
  Two
  Three = 17
end

describe Grant::Converters::Enum do
  describe Number do
    describe ".to_db" do
      it "should convert a Test enum into a Number" do
        Grant::Converters::Enum(TestEnum, Int8).to_db(TestEnum::One).should eq 1_i64
        Grant::Converters::Enum(TestEnum, Float64).to_db(TestEnum::Two).should eq 2_i64
        Grant::Converters::Enum(TestEnum, Int32).to_db(TestEnum::Three).should eq 17_i64
      end
    end

    describe ".from_rs" do
      it "should convert the RS value into a Test enum" do
        rs = FieldEmitter.new.tap do |e|
          e._set_values([0])
        end

        Grant::Converters::Enum(TestEnum, Int32).from_rs(rs).should eq TestEnum::Zero
      end

      it "should convert the RS value into a Test enum" do
        rs = FieldEmitter.new.tap do |e|
          e._set_values([1_i16])
        end

        Grant::Converters::Enum(TestEnum, Int16).from_rs(rs).should eq TestEnum::One
      end

      it "should convert the RS value into a Test enum" do
        rs = FieldEmitter.new.tap do |e|
          e._set_values([17.0])
        end

        Grant::Converters::Enum(TestEnum, Float64).from_rs(rs).should eq TestEnum::Three
      end
    end
  end

  describe String do
    describe ".to_db" do
      it "should convert a Test enum into a string" do
        Grant::Converters::Enum(TestEnum, String).to_db(TestEnum::Two).should eq "Two"
      end
    end

    describe ".from_rs" do
      it "should convert the RS value into a Test enum" do
        rs = FieldEmitter.new.tap do |e|
          e._set_values(["Three"])
        end

        Grant::Converters::Enum(TestEnum, String).from_rs(rs).should eq TestEnum::Three
      end
    end
  end

  describe Bytes do
    describe ".to_db" do
      it "should convert a Test enum into a string" do
        Grant::Converters::Enum(TestEnum, Bytes).to_db(TestEnum::Two).should eq "Two"
      end
    end

    describe ".from_rs" do
      it "should convert an Int32 value into a Test enum" do
        rs = FieldEmitter.new.tap do |e|
          e._set_values([Bytes[90, 101, 114, 111]])
        end

        Grant::Converters::Enum(TestEnum, Bytes).from_rs(rs).should eq TestEnum::Zero
      end
    end
  end
end
