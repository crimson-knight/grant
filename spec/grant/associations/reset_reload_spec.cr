require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class RrOwner < Grant::Base
    connection {{ adapter_literal }}
    table rr_owners
    column id : Int64, primary: true
    column name : String
    has_many :rr_items, class_name: RrItem, foreign_key: :rr_owner_id
    has_one :rr_detail, class_name: RrDetail, foreign_key: :rr_owner_id
  end

  class RrItem < Grant::Base
    connection {{ adapter_literal }}
    table rr_items
    column id : Int64, primary: true
    column label : String
    column rr_owner_id : Int64?
    belongs_to :rr_owner, class_name: RrOwner, foreign_key: :rr_owner_id, optional: true
  end

  class RrDetail < Grant::Base
    connection {{ adapter_literal }}
    table rr_details
    column id : Int64, primary: true
    column note : String
    column rr_owner_id : Int64?
  end
{% end %}

describe "association reset and reload" do
  before_all do
    RrOwner.migrator.drop_and_create
    RrItem.migrator.drop_and_create
    RrDetail.migrator.drop_and_create
  end

  before_each do
    RrItem.clear
    RrDetail.clear
    RrOwner.clear
  end

  it "reset_<name> forgets a has_one and the next read queries" do
    owner = RrOwner.create!(name: "o")
    RrDetail.create!(note: "first", rr_owner_id: owner.id)
    loaded = RrOwner.includes(:rr_detail).where(id: owner.id).select.first
    loaded.association_loaded?(:rr_detail).should be_true

    loaded.reset_rr_detail
    loaded.association_loaded?(:rr_detail).should be_false
    AssociationQueryCounter.selects { loaded.rr_detail }.should eq(1)
    loaded.association_loaded?(:rr_detail).should be_true
  end

  it "reload_<name> re-reads a has_one with exactly one query" do
    owner = RrOwner.create!(name: "o")
    detail = RrDetail.create!(note: "first", rr_owner_id: owner.id)
    loaded = RrOwner.find!(owner.id)
    loaded.rr_detail.try(&.note).should eq("first")

    detail.update!(note: "second")
    loaded.rr_detail.try(&.note).should eq("first")
    result = nil
    AssociationQueryCounter.selects { result = loaded.reload_rr_detail }.should eq(1)
    result.try(&.note).should eq("second")
  end

  it "reload_<name> and reset_<name> work on belongs_to" do
    owner = RrOwner.create!(name: "before")
    item = RrItem.create!(label: "i", rr_owner_id: owner.id)
    loaded = RrItem.includes(:rr_owner).where(id: item.id).select.first
    loaded.rr_owner.try(&.name).should eq("before")

    owner.update!(name: "after")
    loaded.rr_owner.try(&.name).should eq("before")
    AssociationQueryCounter.selects { loaded.reload_rr_owner }.should eq(1)
    loaded.rr_owner.try(&.name).should eq("after")
    loaded.reset_rr_owner
    loaded.association_loaded?(:rr_owner).should be_false
  end

  it "reload_<name> re-reads a has_many" do
    owner = RrOwner.create!(name: "o")
    RrItem.create!(label: "a", rr_owner_id: owner.id)
    loaded = RrOwner.includes(:rr_items).where(id: owner.id).select.first
    loaded.rr_items.size.should eq(1)

    RrItem.create!(label: "b", rr_owner_id: owner.id)
    loaded.rr_items.size.should eq(1)
    AssociationQueryCounter.selects { loaded.reload_rr_items }.should eq(1)
    loaded.rr_items.size.should eq(2)
    loaded.reset_rr_items
    loaded.association_loaded?(:rr_items).should be_false
  end

  it "has collection loaded?, reload, reset, and load_target" do
    owner = RrOwner.create!(name: "o")
    RrItem.create!(label: "a", rr_owner_id: owner.id)
    fresh = RrOwner.find!(owner.id)

    fresh.rr_items.loaded?.should be_false
    fresh.rr_items.load_target.size.should eq(1)
    fresh.rr_items.loaded?.should be_true

    RrItem.create!(label: "b", rr_owner_id: owner.id)
    fresh.rr_items.size.should eq(1)
    fresh.rr_items.reload.size.should eq(2)
    fresh.rr_items.reset
    fresh.rr_items.loaded?.should be_false
    fresh.association_loaded?(:rr_items).should be_false
  end

  it "Base#reload clears the association cache" do
    owner = RrOwner.create!(name: "o")
    RrItem.create!(label: "a", rr_owner_id: owner.id)
    RrDetail.create!(note: "d", rr_owner_id: owner.id)
    loaded = RrOwner.includes(:rr_items, :rr_detail).where(id: owner.id).select.first
    loaded.association_loaded?(:rr_items).should be_true

    loaded.reload
    loaded.association_loaded?(:rr_items).should be_false
    loaded.association_loaded?(:rr_detail).should be_false
    AssociationQueryCounter.selects { loaded.rr_detail }.should eq(1)
  end

  it "exposes the association proxy with loaded?, target, reset, and reload" do
    owner = RrOwner.create!(name: "o")
    RrItem.create!(label: "a", rr_owner_id: owner.id)
    loaded = RrOwner.find!(owner.id)

    proxy = loaded.association(:rr_items)
    proxy.loaded?.should be_false
    loaded.association_cached?(:rr_items).should be_false
    proxy.target.as(Array(Grant::Base)).size.should eq(1)
    proxy.loaded?.should be_true
    loaded.association_cached?(:rr_items).should be_true

    RrItem.create!(label: "b", rr_owner_id: owner.id)
    proxy.reload.as(Array(Grant::Base)).size.should eq(2)
    proxy.reset
    proxy.loaded?.should be_false
    proxy.reflection.macro.should eq(:has_many)
  end
end
