require "../../spec_helper"
require "../../support/convenience_models"
require "../../support/association_query_counter"

describe "create with a block and with an array" do
  before_all { ConvenienceSpecSupport.reset_items }
  before_each { ConvItem.clear }

  describe "new with an initializer block" do
    it "yields the record after the attributes are assigned" do
      seen = nil
      item = ConvItem.new(name: "a") do |record|
        seen = record.name
        record.status = "block"
      end
      seen.should eq("a")
      item.status.should eq("block")
      item.new_record?.should be_true
    end

    it "tracks values set in the block as changes" do
      item = ConvItem.new(name: "a", &.status=("x"))
      item.status_changed?.should be_true
    end

    it "accepts an attributes hash" do
      item = ConvItem.new({"name" => "h"} of Symbol | String => Grant::Columns::Type) { |record| record.kind = "hash" }
      item.name.should eq("h")
      item.kind.should eq("hash")
    end
  end

  describe "create / create! with a block" do
    it "yields the record before it is saved" do
      item = ConvItem.create(name: "a", &.status=("from block"))
      item.persisted?.should be_true
      ConvItem.find!(item.id).status.should eq("from block")
    end

    it "lets the block fix an otherwise invalid record" do
      ConvItem.create(name: "", &.name=("fixed")).persisted?.should be_true
    end

    it "raises from create! with a block when the save fails" do
      expect_raises(Grant::RecordInvalid) { ConvItem.create!(name: "", &.status=("x")) }
    end

    it "persists from create! with a block" do
      item = ConvItem.create!(name: "b", &.qty=(3))
      ConvItem.find!(item.id).qty.should eq(3)
    end
  end

  describe "array form" do
    it "creates every record and returns them in order" do
      items = ConvItem.create([{name: "one"}, {name: "two"}, {name: "three"}])
      items.map(&.name).should eq(["one", "two", "three"])
      items.all?(&.persisted?).should be_true
      ConvItem.count.should eq(3)
    end

    it "yields each record to the block" do
      items = ConvItem.create([{name: "one"}, {name: "two"}]) { |record| record.status = "bulk" }
      items.map(&.status).should eq(["bulk", "bulk"])
    end

    it "returns invalid records unsaved without stopping the others" do
      items = ConvItem.create([{name: "ok"}, {name: ""}, {name: "ok2"}])
      items.map(&.persisted?).should eq([true, false, true])
    end

    it "raises from create! and rolls the whole batch back" do
      expect_raises(Grant::RecordInvalid) do
        ConvItem.create!([{name: "first"}, {name: ""}])
      end
      ConvItem.count.should eq(0)
    end

    it "rolls the whole batch back when a database constraint fails" do
      ConvItem.create!(name: "taken")
      expect_raises(Grant::RecordNotSaved) do
        ConvItem.create!([{name: "fresh"}, {name: "taken"}])
      end
      ConvItem.where(name: "fresh").exists?.should be_false
    end

    it "runs the whole batch inside one transaction" do
      opened_inside = [] of Bool
      ConvItem.create([{name: "x"}, {name: "y"}]) { |_| opened_inside << ConvItem.transaction_open? }
      opened_inside.should eq([true, true])
    end
  end
end
