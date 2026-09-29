require "../../spec_helper"
require "../../support/convenience_models"
require "../../support/association_query_counter"

describe "find with several ids" do
  before_all { ConvenienceSpecSupport.reset_items }
  before_each { ConvItem.clear }

  it "returns records in the order of the ids with one IN query" do
    a = ConvItem.create!(name: "a")
    b = ConvItem.create!(name: "b")
    c = ConvItem.create!(name: "c")
    ids = [c.id.not_nil!, a.id.not_nil!, b.id.not_nil!]

    found = [] of ConvItem
    statements = AssociationQueryCounter.statements { found = ConvItem.find(ids) }
    found.map(&.id).should eq(ids)
    statements.size.should eq(1)
    statements.first.should contain(" IN ")
  end

  it "accepts several positional ids" do
    a = ConvItem.create!(name: "a")
    b = ConvItem.create!(name: "b")
    ConvItem.find(b.id.not_nil!, a.id.not_nil!).map(&.name).should eq(["b", "a"])
    ConvItem.find!(b.id.not_nil!, a.id.not_nil!).map(&.name).should eq(["b", "a"])
  end

  it "skips missing ids in find and returns an empty array for none" do
    a = ConvItem.create!(name: "a")
    ConvItem.find([a.id.not_nil!, 999_999_i64]).map(&.id).should eq([a.id])
    ConvItem.find([] of Int64).empty?.should be_true
  end

  it "raises NotFound naming every missing id from find!" do
    a = ConvItem.create!(name: "a")
    error = expect_raises(Grant::Querying::NotFound) do
      ConvItem.find!([a.id.not_nil!, 888_888_i64, 999_999_i64])
    end
    error.message.to_s.should contain("888888")
    error.message.to_s.should contain("999999")
    error.should be_a(Grant::RecordNotFound)
  end

  it "keeps the single-id behavior" do
    a = ConvItem.create!(name: "a")
    ConvItem.find(a.id).should_not be_nil
    ConvItem.find(999_999).should be_nil
    expect_raises(Grant::Querying::NotFound) { ConvItem.find!(999_999) }
  end

  it "applies relation conditions" do
    a = ConvItem.create!(name: "a", status: "x")
    b = ConvItem.create!(name: "b", status: "y")
    ConvItem.where(status: "x").find([a.id.not_nil!, b.id.not_nil!]).map(&.id).should eq([a.id])
    expect_raises(Grant::Querying::NotFound) do
      ConvItem.where(status: "x").find!([a.id.not_nil!, b.id.not_nil!])
    end
  end

  it "returns duplicates as many times as they were asked for" do
    a = ConvItem.create!(name: "a")
    id = a.id.not_nil!
    ConvItem.find([id, id]).size.should eq(2)
  end
end
