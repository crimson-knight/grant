require "../../spec_helper"
require "../../support/relation_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class DestroyAllChild < Grant::Base
    connection {{ adapter_literal }}
    table destroy_all_children

    column id : Int64, primary: true
    column owner_id : Int64?
    column note : String = "child"
  end

  class DestroyAllPinned < Grant::Base
    connection {{ adapter_literal }}
    table destroy_all_pins

    column id : Int64, primary: true
    column owner_id : Int64?
  end

  class DestroyAllOwner < Grant::Base
    connection {{ adapter_literal }}
    table destroy_all_owners

    column id : Int64, primary: true
    column label : String

    has_many :children, class_name: DestroyAllChild, foreign_key: :owner_id, dependent: :destroy
    has_many :pins, class_name: DestroyAllPinned, foreign_key: :owner_id, dependent: :restrict

    before_destroy :log_before
    after_destroy :log_after

    class_property events = [] of String
    class_property transaction_flags = [] of Bool

    def log_before
      self.class.events << "before #{label}"
      self.class.transaction_flags << self.class.transaction_open?
    end

    def log_after
      self.class.events << "after #{label}"
    end
  end
{% end %}

private def reset_destroy_tables : Nil
  DestroyAllChild.migrator.drop_and_create
  DestroyAllPinned.migrator.drop_and_create
  DestroyAllOwner.migrator.drop_and_create
  DestroyAllOwner.events.clear
  DestroyAllOwner.transaction_flags.clear
end

describe "Relation destroy_all with callbacks" do
  it "runs before_destroy and after_destroy around each record, in order" do
    reset_destroy_tables
    ["a", "b", "c"].each { |label| DestroyAllOwner.create!(label: label) }

    count = DestroyAllOwner.where(:label, :neq, "c").destroy_all

    count.should eq(2)
    DestroyAllOwner.events.should eq(["before a", "after a", "before b", "after b"])
    DestroyAllOwner.pluck(:label).flatten.should eq(["c"])
  end

  it "destroys dependent children through their own destroy" do
    reset_destroy_tables
    owner = DestroyAllOwner.create!(label: "parent")
    kept = DestroyAllOwner.create!(label: "other")
    3.times { DestroyAllChild.create!(owner_id: owner.id) }
    DestroyAllChild.create!(owner_id: kept.id)

    DestroyAllOwner.where(label: "parent").destroy_all.should eq(1)

    DestroyAllChild.where(owner_id: owner.id).select.should be_empty
    DestroyAllChild.where(owner_id: kept.id).select.size.should eq(1)
  end

  it "skips a record whose dependent: :restrict aborts the destroy" do
    reset_destroy_tables
    blocked = DestroyAllOwner.create!(label: "blocked")
    free = DestroyAllOwner.create!(label: "free")
    DestroyAllPinned.create!(owner_id: blocked.id)

    destroyed = DestroyAllOwner.all.destroy_all_records

    destroyed.map(&.id).should eq([free.id])
    DestroyAllOwner.pluck(:label).flatten.should eq(["blocked"])
    DestroyAllOwner.events.should contain("after free")
    DestroyAllOwner.events.should_not contain("after blocked")
  end

  it "iterates in keyset batches with one transaction per batch" do
    reset_destroy_tables
    12.times { |index| DestroyAllOwner.create!(label: "o#{index}") }

    statements = capture_sql { DestroyAllOwner.all.destroy_all.should eq(12) }

    statements.select(&.starts_with?("SELECT")).each { |sql| sql.should_not contain("OFFSET") }
    DestroyAllOwner.pluck(:id).should be_empty
    DestroyAllOwner.transaction_flags.should eq(Array.new(12, true))
  end

  it "honors the relation's limit and leaves the rest" do
    reset_destroy_tables
    5.times { |index| DestroyAllOwner.create!(label: "o#{index}") }

    DestroyAllOwner.order(id: :asc).limit(2).destroy_all.should eq(2)
    DestroyAllOwner.pluck(:label).flatten.should eq(["o2", "o3", "o4"])
  end

  it "returns zero for an empty or none relation" do
    reset_destroy_tables
    DestroyAllOwner.where(label: "nothing").destroy_all.should eq(0)
    DestroyAllOwner.none.destroy_all.should eq(0)
  end
end
