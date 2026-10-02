require "./bulk_support"

describe "bulk chunking" do
  before_all { BulkSupport.prepare }
  before_each do
    BulkItem.clear
    BulkTwoColumn.clear
  end

  it "fits rows under the adapter's bind cap" do
    adapter = BulkItem.adapter
    adapter.bulk_chunk_rows(2).should eq(adapter.bulk_bind_limit // 2)
    expected = if adapter.sqlite?
                 32_766
               elsif adapter.postgres?
                 32_767 # crystal-pg's signed 16-bit Bind count
               else
                 65_535
               end
    adapter.bulk_bind_limit.should eq(expected)
  end

  it "splits rows above the cap into several statements" do
    per_chunk = BulkTwoColumn.adapter.bulk_chunk_rows(1)
    total = per_chunk + 10
    rows = Array.new(total) { |index| {"label" => "row #{index}"} }

    statements = BulkSupport.inserts { BulkTwoColumn.insert_all(rows, returning: [] of Symbol) }

    statements.size.should eq(2)
    BulkTwoColumn.count.should eq(total)
  end

  it "sends one multi-row statement for rows under the cap" do
    rows = Array.new(500) { |index| BulkSupport.item("sku#{index}") }

    statements = BulkSupport.inserts { BulkItem.insert_all(rows) }

    statements.size.should eq(1)
    BulkItem.count.should eq(500)
  end

  it "returns records from every chunk" do
    next unless BulkTwoColumn.adapter.supports_insert_returning?
    per_chunk = BulkTwoColumn.adapter.bulk_chunk_rows(1)
    rows = Array.new(per_chunk + 5) { |index| {"label" => "row #{index}"} }

    BulkTwoColumn.insert_all(rows).size.should eq(per_chunk + 5)
  end

  it "rolls every chunk back when a later chunk fails" do
    per_chunk = BulkItem.adapter.bulk_chunk_rows(4 + 2)
    rows = Array.new(per_chunk + 2) { |index| BulkSupport.item("sku#{index}") }
    rows << BulkSupport.item("sku0")

    expect_raises(Grant::RecordNotUnique) { BulkItem.insert_all!(rows) }
    BulkItem.count.should eq(0)
  end
end
