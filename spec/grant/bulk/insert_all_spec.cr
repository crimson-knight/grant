require "./bulk_support"

describe "insert_all / insert_all!" do
  before_all { BulkSupport.prepare }
  before_each { BulkItem.clear }

  it "inserts every row in one call and stamps timestamps" do
    BulkItem.insert_all([BulkSupport.item("a"), BulkSupport.item("b")])

    BulkItem.count.should eq(2)
    BulkItem.find_by!(sku: "a").created_at.should_not be_nil
  end

  it "skips rows that collide with a unique key by default" do
    BulkItem.create!(sku: "a", name: "Original", stock: 1, status: BulkStatus::Draft)

    records = BulkItem.insert_all([BulkSupport.item("a", "Changed"), BulkSupport.item("b")])

    BulkItem.count.should eq(2)
    BulkItem.find_by!(sku: "a").name.should eq("Original")
    # The returned records come from RETURNING, which MySQL does not have.
    records.size.should eq(CURRENT_ADAPTER == "mysql" ? 0 : 1)
  end

  it "skips only the named constraint with unique_by" do
    BulkItem.create!(sku: "a", name: "Original", stock: 1, status: BulkStatus::Draft)

    BulkItem.insert_all([BulkSupport.item("a", "Changed")], unique_by: [:sku])
    BulkItem.insert_all([BulkSupport.item("a", "Changed")], unique_by: "idx_bulk_items_sku")

    BulkItem.count.should eq(1)
  end

  it "still raises for a collision on a key other than unique_by" do
    existing = BulkItem.create!(sku: "a", name: "Original", stock: 1, status: BulkStatus::Draft)
    row = {"id" => existing.id, "sku" => "other", "name" => "Clash", "stock" => 1, "status" => 0}

    if CURRENT_ADAPTER == "mysql"
      # INSERT IGNORE cannot name a key: MySQL skips a collision on any of them.
      BulkItem.insert_all([row], unique_by: [:sku])
    else
      expect_raises(Grant::RecordNotUnique) { BulkItem.insert_all([row], unique_by: [:sku]) }
    end
    BulkItem.count.should eq(1)
  end

  it "raises Grant::RecordNotUnique from insert_all! on a duplicate" do
    BulkItem.create!(sku: "a", name: "Original", stock: 1, status: BulkStatus::Draft)

    expect_raises(Grant::RecordNotUnique) do
      BulkItem.insert_all!([BulkSupport.item("b"), BulkSupport.item("a")])
    end
    BulkItem.count.should eq(1)
  end

  it "inserts with insert_all! when nothing collides" do
    BulkItem.insert_all!([BulkSupport.item("a"), BulkSupport.item("b")])
    BulkItem.count.should eq(2)
  end

  it "raises ArgumentError when rows have different keys" do
    rows = [
      {"sku" => "a", "name" => "A", "stock" => 1, "status" => 0},
      {"sku" => "b", "name" => "B", "stock" => 1},
    ]
    expect_raises(ArgumentError, /same keys/) { BulkItem.insert_all(rows) }
    BulkItem.count.should eq(0)
  end

  it "accepts the same keys in a different order and as symbols" do
    BulkItem.insert_all([
      {:sku => "a", :name => "A", :stock => 1, :status => 0},
      {:status => 0, :stock => 2, :name => "B", :sku => "b"},
    ])
    BulkItem.count.should eq(2)
  end

  it "raises ArgumentError for an unknown column" do
    expect_raises(ArgumentError, /Unknown column/) do
      BulkItem.insert_all([{"sku" => "a", "bogus" => "x"}])
    end
  end

  it "applies the column converter to application values" do
    BulkItem.insert_all([{"sku" => "a", "name" => "A", "stock" => 1, "status" => BulkStatus::Live}])

    BulkItem.find_by!(sku: "a").status.should eq(BulkStatus::Live)
  end

  it "widens integers to the declared column width" do
    BulkItem.insert_all([{"sku" => "a", "name" => "A", "stock" => 7_i64, "status" => 1_i64}])
    BulkItem.find_by!(sku: "a").stock.should eq(7)
  end

  it "does nothing for an empty list" do
    BulkItem.insert_all([] of Hash(String, String)).should be_empty
    BulkItem.count.should eq(0)
  end
end
