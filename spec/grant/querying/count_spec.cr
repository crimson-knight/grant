require "../../spec_helper"

module CountSpecSupport
  # Feeds a driver-returned Int64 through the model count path without generating
  # billions of rows.
  class LargeCountScope
    def count : Int64
      value = Grant.connection(CURRENT_ADAPTER).select_value("SELECT 2147483648") ||
              raise DB::Error.new("The count probe query returned no value")
      Grant::Result.integer_count(value)
    end
  end

  class LargeCountProbe
    extend Grant::Querying::ClassMethods

    def self.current_scope : LargeCountScope
      LargeCountScope.new
    end
  end
end

describe "#count" do
  it "round-trips a count larger than Int32::MAX" do
    CountSpecSupport::LargeCountProbe.count.should eq(2_147_483_648_i64)
  end

  it "returns Int64 for model, relation, grouped, and relation size counts" do
    Parent.clear
    Parent.new(name: "count probe").tap(&.save)

    Parent.count.should be_a(Int64)

    relation = Parent.where(name: "count probe")
    relation.count.should be_a(Int64)
    relation.size.should be_a(Int64)

    Parent.group_by(:name).count.should be_a(Hash(Grant::Columns::Type, Int64))

    grouped_size = Parent.group_by(:name).size
    grouped_size.should be_a(Int64)
    grouped_size.should eq(1_i64)
  end

  it "returns 0 if no result" do
    Parent.clear
    count = Parent.count
    count.should eq 0
  end

  it "returns a number of the all records for the model" do
    count = Parent.count
    2.times do |i|
      Parent.new(name: "model_#{i}").tap(&.save)
    end

    (Parent.count - count).should eq 2
  end
end
