require "./bulk_support"

describe "insert_all returning" do
  before_all { BulkSupport.prepare }
  before_each { BulkItem.clear }

  it "returns the primary key of each inserted row by default" do
    records = BulkItem.insert_all([BulkSupport.item("a"), BulkSupport.item("b")])

    if BulkItem.adapter.supports_insert_returning?
      records.size.should eq(2)
      records.compact_map(&.id).sort!.should eq(BulkItem.order(:id).select.compact_map(&.id))
    else
      records.should be_empty
    end
  end

  if CURRENT_ADAPTER == "mysql"
    it "raises clearly when RETURNING columns are requested" do
      expect_raises(ArgumentError, /does not support RETURNING/) do
        BulkItem.insert_all([BulkSupport.item("a")], returning: [:id, :sku])
      end
    end
  else
    it "returns the requested columns" do
      records = BulkItem.insert_all([BulkSupport.item("a", "Alpha", 3)], returning: [:id, :sku, :stock, :created_at])

      records.size.should eq(1)
      records.first.sku.should eq("a")
      records.first.stock.should eq(3)
      records.first.id.should_not be_nil
      records.first.created_at.should_not be_nil
    end

    it "returns nothing for skipped duplicates" do
      BulkItem.insert_all([BulkSupport.item("a")])
      records = BulkItem.insert_all([BulkSupport.item("a"), BulkSupport.item("b")], returning: [:sku])

      records.map(&.sku).should eq(["b"])
    end

    it "returns nothing when returning is empty" do
      BulkItem.insert_all([BulkSupport.item("a")], returning: [] of Symbol).should be_empty
      BulkItem.count.should eq(1)
    end

    it "rejects unknown returning columns" do
      expect_raises(ArgumentError, /Unknown returning column/) do
        BulkItem.insert_all([BulkSupport.item("a")], returning: [:bogus])
      end
    end
  end
end
