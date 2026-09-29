require "../../spec_helper"
require "../../support/convenience_models"

describe "find_or_create_by and find_or_initialize_by" do
  before_all { ConvenienceSpecSupport.reset_items }
  before_each { ConvItem.clear }

  describe "class level" do
    it "runs the block only when it creates" do
      calls = 0
      first = ConvItem.find_or_create_by(name: "a") { |record| calls += 1; record.status = "new" }
      first.status.should eq("new")
      again = ConvItem.find_or_create_by(name: "a") { |record| calls += 1 }
      again.id.should eq(first.id)
      calls.should eq(1)
    end

    it "raises from the bang form when the create is invalid" do
      expect_raises(Grant::RecordInvalid) { ConvItem.find_or_create_by!(name: "") }
    end

    it "returns the existing record from the bang form" do
      existing = ConvItem.create!(name: "a")
      ConvItem.find_or_create_by!(name: "a").id.should eq(existing.id)
      ConvItem.count.should eq(1)
    end

    it "builds without saving in find_or_initialize_by and runs the block" do
      item = ConvItem.find_or_initialize_by(name: "z") { |record| record.kind = "blk" }
      item.new_record?.should be_true
      item.kind.should eq("blk")
      ConvItem.count.should eq(0)
    end
  end

  describe "on a relation" do
    it "creates with the equality attributes of the where clause" do
      item = ConvItem.where(status: "active", kind: "k").find_or_create_by(name: "rel")
      item.persisted?.should be_true
      item.status.should eq("active")
      item.kind.should eq("k")
    end

    it "finds within the relation only" do
      ConvItem.create!(name: "a", status: "other")
      item = ConvItem.where(status: "active").find_or_create_by(name: "z")
      item.status.should eq("active")
      ConvItem.where(status: "active").find_or_create_by(name: "a").persisted?.should be_false
      ConvItem.count.should eq(2)
    end

    it "does not turn ranges, IN lists or other operators into defaults" do
      relation = ConvItem.where(qty: 1..5).where(kind: ["a", "b"]).where(:name, :like, "x%")
      relation.scope_attributes.empty?.should be_true
      relation.find_or_initialize_by(name: "n").qty.should be_nil
    end

    it "lets explicit attributes win over the scope attributes" do
      ConvItem.where(status: "active").create(name: "a", status: "explicit").status.should eq("explicit")
    end

    it "flows through named scopes" do
      item = ConvItem.drafts.find_or_create_by(name: "scoped")
      item.status.should eq("draft")
      ConvItem.drafts.find_or_create_by(name: "scoped").id.should eq(item.id)
    end

    it "supports the bang, initialize and block forms" do
      relation = ConvItem.where(status: "active")
      relation.find_or_create_by!(name: "b") { |record| record.qty = 4 }.qty.should eq(4)
      built = relation.find_or_initialize_by(name: "c")
      built.new_record?.should be_true
      built.status.should eq("active")
      expect_raises(Grant::RecordInvalid) { relation.find_or_create_by!(name: "") }
    end

    it "exposes first_or_create, first_or_create! and first_or_initialize" do
      relation = ConvItem.where(status: "active")
      relation.first_or_initialize(name: "x").new_record?.should be_true
      created = relation.first_or_create(name: "x")
      created.persisted?.should be_true
      relation.first_or_create(name: "ignored").id.should eq(created.id)
      relation.first_or_create!(name: "ignored").id.should eq(created.id)
      expect_raises(Grant::RecordInvalid) { ConvItem.where(status: "none").first_or_create!(name: "") }
    end

    it "builds through new and build" do
      relation = ConvItem.where(status: "active")
      relation.build(name: "b").status.should eq("active")
      relation.new(name: "n") { |record| record.qty = 2 }.qty.should eq(2)
      relation.create(name: "c").persisted?.should be_true
      relation.create!(name: "d").status.should eq("active")
    end
  end
end
