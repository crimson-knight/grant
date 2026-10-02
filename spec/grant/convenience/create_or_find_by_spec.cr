require "../../spec_helper"
require "../../support/convenience_models"
require "../../support/association_query_counter"

describe "create_or_find_by" do
  before_all { ConvenienceSpecSupport.reset_items }
  before_each { ConvItem.clear }

  it "creates without a prior SELECT" do
    statements = AssociationQueryCounter.statements { ConvItem.create_or_find_by(name: "fresh") }
    statements.any?(&.includes?("SELECT")).should be_false
    ConvItem.count.should eq(1)
  end

  it "returns the existing row when the unique index rejects the insert" do
    existing = ConvItem.create!(name: "dup", status: "old")
    found = ConvItem.create_or_find_by(name: "dup") { |record| record.status = "new" }
    found.id.should eq(existing.id)
    found.status.should eq("old")
    ConvItem.count.should eq(1)
  end

  it "resolves the race through RecordNotUnique inside an open transaction" do
    existing = ConvItem.create!(name: "dup")
    ConvItem.transaction do
      found = ConvItem.create_or_find_by!(name: "dup")
      found.id.should eq(existing.id)
      # The enclosing transaction is still usable after the failed insert.
      ConvItem.create!(name: "after")
    end
    ConvItem.count.should eq(2)
  end

  it "opens one more savepoint than a plain create when nested in a transaction" do
    ConvItem.transaction do
      state = Grant::Transaction.current_state?.not_nil!
      before = state.savepoint_counter
      ConvItem.create(name: "plain")
      plain_cost = state.savepoint_counter - before

      before = state.savepoint_counter
      ConvItem.create_or_find_by(name: "guarded")
      (state.savepoint_counter - before).should eq(plain_cost + 1)
    end
  end

  it "does not swallow a non-unique failure in the bang form" do
    expect_raises(Grant::RecordInvalid) { ConvItem.create_or_find_by!(name: "") }
  end

  it "returns the unsaved record from the non-bang form on validation failure" do
    record = ConvItem.create_or_find_by(name: "")
    record.persisted?.should be_false
    record.errors.empty?.should be_false
  end

  it "raises RecordNotFound when the conflict is not on the lookup attributes" do
    ConvItem.create!(name: "dup")
    expect_raises(Grant::RecordNotFound) do
      ConvItem.create_or_find_by!(name: "dup", status: "other")
    end
  end

  it "works on a relation and inherits its scope attributes" do
    item = ConvItem.where(status: "active").create_or_find_by(name: "rel")
    item.status.should eq("active")
    ConvItem.where(status: "active").create_or_find_by(name: "rel").id.should eq(item.id)
  end

  it "resolves a real race between fibers" do
    results = Channel(Int64?).new
    4.times do
      spawn do
        results.send(ConvItem.create_or_find_by(name: "raced").id)
      rescue
        results.send(nil)
      end
    end
    ids = Array(Int64?).new(4) { results.receive }
    ids.compact.uniq!.size.should eq(1)
    ConvItem.where(name: "raced").count.should eq(1)
  end
end
