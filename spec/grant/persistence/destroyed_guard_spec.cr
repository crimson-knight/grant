require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class GuardedItem < Grant::Base
    connection {{ adapter_literal }}
    table guarded_items

    column id : Int64, primary: true
    column name : String?
    column counter : Int32?
    column active : Bool?
    timestamps
  end
{% end %}

GuardedItem.migrator.drop_and_create

private def destroyed_item : GuardedItem
  item = GuardedItem.create!(name: "gone", counter: 1, active: true)
  item.destroy.should be_true
  item
end

describe "Destroyed record guard" do
  before_each { GuardedItem.clear }

  it "freezes a record after destroy" do
    item = GuardedItem.create!(name: "live")
    item.frozen?.should be_false
    item.destroy
    item.destroyed?.should be_true
    item.frozen?.should be_true
    item.persisted?.should be_false
  end

  it "raises from save, save!, update and update!" do
    item = destroyed_item
    item.name = "again"
    expect_raises(Grant::RecordDestroyedError, /destroyed GuardedItem/) { item.save }
    expect_raises(Grant::RecordDestroyedError) { item.save! }
    expect_raises(Grant::RecordDestroyedError) { item.update(name: "x") }
    expect_raises(Grant::RecordDestroyedError) { item.update!(name: "x") }
    expect_raises(Grant::RecordDestroyedError) { item.update_attribute(:name, "x") }
    expect_raises(Grant::RecordDestroyedError) { item.toggle!(:active) }
  end

  it "raises from update_columns, update_column and touch" do
    item = destroyed_item
    expect_raises(Grant::RecordDestroyedError) { item.update_columns(name: "x") }
    expect_raises(Grant::RecordDestroyedError) { item.update_column(:name, "x") }
    expect_raises(Grant::RecordDestroyedError) { item.touch }
  end

  it "raises from increment!, decrement! and a second destroy" do
    item = destroyed_item
    expect_raises(Grant::RecordDestroyedError) { item.increment!(:counter) }
    expect_raises(Grant::RecordDestroyedError) { item.decrement!(:counter) }
    expect_raises(Grant::RecordDestroyedError) { item.destroy }
    expect_raises(Grant::RecordDestroyedError) { item.destroy! }
  end

  it "does not write a row back for a destroyed record" do
    item = destroyed_item
    id = item.id
    expect_raises(Grant::RecordDestroyedError) { item.save }
    GuardedItem.find(id).should be_nil
    GuardedItem.count.should eq(0)
  end

  it "is a Grant::ErrorBase" do
    item = destroyed_item
    begin
      item.save
      fail "expected RecordDestroyedError"
    rescue error : Grant::ErrorBase
      error.should be_a(Grant::RecordDestroyedError)
    end
  end

  it "still allows in-memory reads and the in-memory increment" do
    item = destroyed_item
    item.name.should eq("gone")
    item.increment(:counter)
    item.counter.should eq(2)
  end

  it "leaves live records alone" do
    item = GuardedItem.create!(name: "alive")
    item.update!(name: "still alive")
    item.touch.should be_true
    GuardedItem.find!(item.id).name.should eq("still alive")
  end
end
