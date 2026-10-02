require "./bulk_support"

describe "upsert_all" do
  before_all { BulkSupport.prepare }
  before_each { BulkItem.clear }

  it "updates the colliding row by unique_by columns" do
    BulkItem.insert_all([BulkSupport.item("a", "Old", 1)])
    BulkItem.upsert_all([BulkSupport.item("a", "New", 5), BulkSupport.item("b")], unique_by: [:sku])

    BulkItem.count.should eq(2)
    BulkItem.find_by!(sku: "a").name.should eq("New")
    BulkItem.find_by!(sku: "a").stock.should eq(5)
  end

  it "resolves unique_by from an index name" do
    BulkItem.insert_all([BulkSupport.item("a", "Old")])
    BulkItem.upsert_all([BulkSupport.item("a", "New")], unique_by: "idx_bulk_items_sku")

    BulkItem.count.should eq(1)
    BulkItem.find_by!(sku: "a").name.should eq("New")
  end

  it "raises for an index name that does not exist" do
    expect_raises(ArgumentError, /No unique index named/) do
      BulkItem.upsert_all([BulkSupport.item("a")], unique_by: "idx_missing")
    end
  end

  it "updates only the update_only columns" do
    BulkItem.insert_all([BulkSupport.item("a", "Old", 1)])
    BulkItem.upsert_all([BulkSupport.item("a", "New", 5)], unique_by: [:sku], update_only: [:stock])

    item = BulkItem.find_by!(sku: "a")
    item.name.should eq("Old")
    item.stock.should eq(5)
  end

  it "keeps created_at and refreshes updated_at" do
    stamp = Time.utc(2020, 1, 1)
    BulkItem.insert_all([BulkSupport.item("a").merge({"created_at" => stamp, "updated_at" => stamp})], record_timestamps: false)
    BulkItem.upsert_all([BulkSupport.item("a", "New")], unique_by: [:sku])

    item = BulkItem.find_by!(sku: "a")
    item.created_at.should eq(stamp)
    (item.updated_at.not_nil! > stamp).should be_true
  end

  it "uses an on_duplicate fragment as the SET list" do
    BulkItem.insert_all([BulkSupport.item("a", "Old", 10)])
    # The fragment is raw SQL: MySQL names the proposed row with VALUES(), the
    # others with EXCLUDED.
    on_duplicate = if CURRENT_ADAPTER == "mysql"
                     Grant::Sql.fragment("stock = bulk_items.stock + VALUES(stock)")
                   else
                     Grant::Sql.fragment("stock = bulk_items.stock + EXCLUDED.stock")
                   end
    BulkItem.upsert_all([BulkSupport.item("a", "Ignored", 5)], unique_by: [:sku], on_duplicate: on_duplicate)

    item = BulkItem.find_by!(sku: "a")
    item.stock.should eq(15)
    item.name.should eq("Old")
  end

  it "rejects update_only together with on_duplicate" do
    expect_raises(ArgumentError, /not both/) do
      BulkItem.upsert_all([BulkSupport.item("a")], unique_by: [:sku], update_only: [:stock],
        on_duplicate: Grant::Sql.fragment("stock = 1"))
    end
  end

  it "rejects update_only columns that are not in the rows" do
    expect_raises(ArgumentError, /update_only/) do
      BulkItem.upsert_all([{"sku" => "a", "name" => "A", "stock" => 1, "status" => 0}], unique_by: [:sku], update_only: [:created_at], record_timestamps: false)
    end
  end

  it "upserts on the primary key by default" do
    item = BulkItem.create!(sku: "a", name: "Old", stock: 1, status: BulkStatus::Draft)
    BulkItem.upsert_all([{"id" => item.id, "sku" => "a", "name" => "New", "stock" => 1, "status" => 0}])

    BulkItem.count.should eq(1)
    BulkItem.find!(item.id).name.should eq("New")
  end

  it "returns the written records" do
    BulkItem.insert_all([BulkSupport.item("a")])
    if CURRENT_ADAPTER == "mysql"
      # MySQL has no RETURNING, so asking for columns is refused up front.
      expect_raises(ArgumentError, /RETURNING/) do
        BulkItem.upsert_all([BulkSupport.item("a", "New")], unique_by: [:sku], returning: [:id, :sku])
      end
      next
    end
    records = BulkItem.upsert_all([BulkSupport.item("a", "New"), BulkSupport.item("b")], unique_by: [:sku], returning: [:id, :sku])

    records.map(&.sku).sort!.should eq(["a", "b"])
    records.all?(&.id).should be_true
  end

  it "builds a Fragment only from a literal" do
    Grant::Sql.fragment("stock = 1").sql.should eq("stock = 1")
    Grant::Sql::Fragment.new("x").should eq(Grant::Sql.fragment("x"))
  end
end
