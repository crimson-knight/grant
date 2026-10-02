require "../../spec_helper"
require "log/spec"

enum BulkStatus
  Draft
  Live
end

class BulkItem < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table bulk_items

  column id : Int64, primary: true
  column sku : String
  column name : String
  column stock : Int32
  column status : BulkStatus, converter: Grant::Converters::Enum(BulkStatus, Int32), column_type: "INT"
  column created_at : Time?
  column updated_at : Time?
end

class BulkTwoColumn < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table bulk_two_columns

  column id : Int64, primary: true
  column label : String
end

module BulkSupport
  def self.prepare : Nil
    BulkItem.migrator.drop_and_create
    BulkItem.exec("CREATE UNIQUE INDEX idx_bulk_items_sku ON bulk_items(sku)")
    BulkTwoColumn.migrator.drop_and_create
  end

  def self.item(sku : String, name : String = "Item", stock : Int32 = 1) : Hash(String, String | Int32)
    {"sku" => sku, "name" => name, "stock" => stock, "status" => 0}
  end

  # The INSERT statements Grant logs while the block runs.
  def self.inserts(&) : Array(String)
    backend = Log::MemoryBackend.new
    Log.builder.bind("grant.sql", Log::Severity::Debug, backend)
    begin
      yield
    ensure
      Log.builder.unbind("grant.sql", Log::Severity::Debug, backend)
    end
    backend.entries.map(&.message).select(&.includes?("INSERT INTO"))
  end
end
