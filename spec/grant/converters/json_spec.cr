require "../../spec_helper"

describe Grant::Converters::Json do
  describe String do
    describe ".to_db" do
      it "should convert an Object into a String" do
        Grant::Converters::Json(MyType, String).to_db(MyType.new).should eq MyType.new.to_json
      end
    end

    describe ".from_rs" do
      it "should convert the RS value into a MyType" do
        rs = FieldEmitter.new.tap do |e|
          e._set_values([MyType.new.to_json])
        end

        Grant::Converters::Json(MyType, String).from_rs(rs).should eq MyType.new
      end
    end
  end

  describe String do
    describe ".to_db" do
      it "should convert an Object into a String" do
        Grant::Converters::Json(MyType, JSON::Any).to_db(MyType.new).should eq MyType.new.to_json
      end
    end

    describe ".from_rs" do
      it "should convert the RS value into a MyType" do
        rs = FieldEmitter.new.tap do |e|
          e._set_values([JSON.parse(MyType.new.to_json)])
        end

        Grant::Converters::Json(MyType, JSON::Any).from_rs(rs).should eq MyType.new
      end
    end
  end

  describe Bytes do
    describe ".to_db" do
      it "should convert an Object into Bytes" do
        Grant::Converters::Json(MyType, Bytes).to_db(MyType.new).should eq MyType.new.to_json.to_slice
      end
    end

    describe ".from_rs" do
      it "should convert the RS value into a MyType" do
        rs = FieldEmitter.new.tap do |e|
          e._set_values([
            Bytes[123,
              34,
              110,
              97,
              109,
              101,
              34,
              58,
              34,
              74,
              105,
              109,
              34,
              44,
              34,
              97,
              103,
              101,
              34,
              58,
              49,
              50,
              125],
          ])
        end

        Grant::Converters::Json(MyType, Bytes).from_rs(rs).should eq MyType.new
      end
    end
  end
end
