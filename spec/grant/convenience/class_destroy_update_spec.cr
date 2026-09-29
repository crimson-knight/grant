require "../../spec_helper"
require "../../support/convenience_models"
require "../../support/association_query_counter"

describe "class-level destroy, delete and update" do
  before_all { ConvenienceSpecSupport.reset_items }
  before_each { ConvItem.clear }

  describe ".destroy" do
    it "destroys one record by id and returns it" do
      item = ConvItem.create!(name: "a")
      destroyed = ConvItem.destroy(item.id.not_nil!)
      destroyed.destroyed?.should be_true
      ConvItem.count.should eq(0)
    end

    it "raises NotFound for a missing id" do
      expect_raises(Grant::Querying::NotFound) { ConvItem.destroy(999_999) }
    end

    it "destroys many with one SELECT, then destroys each record" do
      ids = 3.times.map { |i| ConvItem.create!(name: "n#{i}").id.not_nil! }.to_a
      destroyed = [] of ConvItem
      statements = AssociationQueryCounter.statements { destroyed = ConvItem.destroy(ids) }
      statements.count(&.includes?("SELECT")).should eq(1)
      destroyed.map(&.id).should eq(ids)
      destroyed.all?(&.destroyed?).should be_true
      ConvItem.count.should eq(0)
    end

    it "raises NotFound for the array form when an id is missing, deleting nothing" do
      item = ConvItem.create!(name: "a")
      expect_raises(Grant::Querying::NotFound) { ConvItem.destroy([item.id.not_nil!, 999_999_i64]) }
      ConvItem.count.should eq(1)
    end
  end

  describe ".delete" do
    it "deletes by id with a count and no callbacks" do
      item = ConvItem.create!(name: "a")
      ConvItem.delete(item.id.not_nil!).should eq(1)
      ConvItem.delete(item.id.not_nil!).should eq(0)
    end

    it "deletes many ids without loading records" do
      ids = 3.times.map { |i| ConvItem.create!(name: "n#{i}").id.not_nil! }.to_a
      count = 0_i64
      selects = AssociationQueryCounter.selects { count = ConvItem.delete(ids[0, 2]) }
      count.should eq(2)
      selects.should eq(0)
      ConvItem.count.should eq(1)
    end

    it "does nothing for an empty list" do
      ConvItem.create!(name: "a")
      ConvItem.delete([] of Int64).should eq(0)
      ConvItem.count.should eq(1)
    end
  end

  describe ".update" do
    it "updates one record by id" do
      item = ConvItem.create!(name: "a")
      updated = ConvItem.update(item.id.not_nil!, status: "done")
      updated.status.should eq("done")
      ConvItem.find!(item.id).status.should eq("done")
    end

    it "accepts an attributes hash" do
      item = ConvItem.create!(name: "a")
      ConvItem.update(item.id.not_nil!, {"kind" => "hash"}).kind.should eq("hash")
    end

    it "updates many ids and returns the records in order" do
      a = ConvItem.create!(name: "a")
      b = ConvItem.create!(name: "b")
      records = ConvItem.update([b.id.not_nil!, a.id.not_nil!], status: "bulk")
      records.map(&.name).should eq(["b", "a"])
      ConvItem.where(status: "bulk").count.should eq(2)
    end

    it "returns the record with errors when validation rejects the change" do
      item = ConvItem.create!(name: "a")
      ConvItem.update(item.id.not_nil!, name: "").errors.empty?.should be_false
      ConvItem.find!(item.id).name.should eq("a")
    end

    it "raises NotFound for a missing id" do
      expect_raises(Grant::Querying::NotFound) { ConvItem.update(999_999, status: "x") }
    end
  end
end
