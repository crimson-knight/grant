require "../../spec_helper"

class UntimedBulkRecord < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table untimed_bulk_records

  column id : Int64, primary: true
  column external_key : String
  column payload : String
end

describe "bulk write timestamps" do
  before_all do
    UntimedBulkRecord.migrator.drop_and_create
    UntimedBulkRecord.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_untimed_bulk_records_key ON untimed_bulk_records(external_key)")
  end

  before_each do
    UntimedBulkRecord.clear
  end

  it "does not add undeclared timestamp columns during insert_all" do
    UntimedBulkRecord.insert_all([{"external_key" => "insert", "payload" => "first"}])

    record = UntimedBulkRecord.find_by!(external_key: "insert")
    record.payload.should eq("first")
    UntimedBulkRecord.fields.should_not contain("created_at")
    UntimedBulkRecord.fields.should_not contain("updated_at")
  end

  it "does not add undeclared timestamp columns during upsert_all" do
    UntimedBulkRecord.insert_all([{"external_key" => "upsert", "payload" => "first"}])
    UntimedBulkRecord.upsert_all(
      [{"external_key" => "upsert", "payload" => "updated"}],
      unique_by: [:external_key]
    )

    UntimedBulkRecord.count.should eq(1)
    UntimedBulkRecord.find_by!(external_key: "upsert").payload.should eq("updated")
  end
end
