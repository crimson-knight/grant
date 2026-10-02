require "../../spec_helper"

describe "Transaction return value" do
  it "returns the block value" do
    Parent.clear

    parent = Parent.transaction { Parent.create!(name: "Ada") }

    parent.should be_a(Parent)
    parent.try(&.name).should eq("Ada")
  end

  it "types the result as the block type or nil" do
    typeof(Parent.transaction { 1 }).should eq(Int32?)
    typeof(Parent.transaction { "x" }).should eq(String?)
    typeof(Parent.transaction(requires_new: true) { 1_i64 }).should eq(Int64?)
    typeof(Parent.new.transaction { :a }).should eq(Symbol?)
  end

  it "returns nil when the block raises Rollback" do
    Parent.transaction { raise Grant::Transaction::Rollback.new; 1 }.should be_nil
  end

  it "returns the value from joined, savepoint, and independent levels" do
    Parent.transaction do
      Parent.transaction { 1 }.should eq(1)
      Parent.transaction(requires_new: true) { 2 }.should eq(2)
      Parent.transaction(independent: true) { 3 }.should eq(3)
      Parent.transaction(Grant::Transaction::Options.new) { 4 }.should eq(4)
    end
    value = Parent.transaction { Parent.transaction(requires_new: true) { 5 } }
    value.should eq(5)
  end

  it "allows a nil block value" do
    Parent.transaction { nil }.should be_nil
  end

  it "returns the value from the instance form, Grant.transaction, and the connection" do
    Parent.new.transaction { 7 }.should eq(7)
    Grant.transaction { 8 }.should eq(8)
    Grant.connection.transaction { 9 }.should eq(9)
  end

  it "does not return a value from a block that raised" do
    expect_raises(Exception, "nope") { Parent.transaction { raise "nope" } }
  end
end
