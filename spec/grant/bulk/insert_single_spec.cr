require "./bulk_support"

describe "insert / insert! / upsert (single row)" do
  before_all { BulkSupport.prepare }
  before_each { BulkItem.clear }

  it "insert returns the new record with its primary key" do
    item = BulkItem.insert(BulkSupport.item("a"))

    item.should_not be_nil
    item.try(&.id).should_not be_nil
    BulkItem.find_by!(sku: "a").id.should eq(item.try(&.id))
  end

  it "insert returns nil when the row is skipped as a duplicate" do
    BulkItem.insert(BulkSupport.item("a")).should_not be_nil
    BulkItem.insert(BulkSupport.item("a", "Changed")).should be_nil
    BulkItem.count.should eq(1)
  end

  it "insert! returns the record and raises on a duplicate" do
    BulkItem.insert!(BulkSupport.item("a")).id.should_not be_nil

    expect_raises(Grant::RecordNotUnique) { BulkItem.insert!(BulkSupport.item("a")) }
  end

  it "insert runs no callbacks and no validations" do
    BulkItem.insert(BulkSupport.item("a", "")).should_not be_nil
  end

  it "upsert inserts a new row and updates an existing one" do
    first = BulkItem.upsert(BulkSupport.item("a", "One"), unique_by: [:sku])
    second = BulkItem.upsert(BulkSupport.item("a", "Two", 9), unique_by: [:sku])

    BulkItem.count.should eq(1)
    first.try(&.id).should eq(second.try(&.id))
    BulkItem.find_by!(sku: "a").name.should eq("Two")
    BulkItem.find_by!(sku: "a").stock.should eq(9)
  end
end
