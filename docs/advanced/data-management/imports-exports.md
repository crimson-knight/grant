---
title: "Data Import and Export"
category: "advanced"
subcategory: "data-management"
tags: ["import", "export", "csv", "json", "etl", "bulk-operations", "data-migration"]
complexity: "intermediate"
version: "1.0.0"
prerequisites: ["../../core-features/crud-operations.md", "migrations.md", "../../core-features/validations.md"]
related_docs: ["migrations.md", "normalization.md", "../../advanced/performance/query-optimization.md"]
last_updated: "2025-01-13"
estimated_read_time: "16 minutes"
use_cases: ["data-migration", "reporting", "backup", "integration", "bulk-updates"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Data Import and Export

Comprehensive guide to importing and exporting data in Grant, including CSV, JSON, and custom formats, with support for bulk operations, validation, and transformation.

## Overview

Data import and export capabilities are essential for:
- Migrating data between systems
- Bulk data updates
- Report generation
- Data backups and archival
- Integration with external systems
- User data portability (GDPR compliance)

Grant provides flexible import/export functionality with validation, transformation, and error handling.

## CSV Import/Export

### Basic CSV Export

```crystal
require "csv"

module CsvExporter
  extend self
  
  def export(records : Array(Grant::Base), columns : Array(String)? = nil) : String
    return "" if records.empty?
    
    # Auto-detect columns if not specified
    columns ||= records.first.class.column_names
    
    CSV.build do |csv|
      # Header row
      csv.row(columns)
      
      # Data rows
      records.each do |record|
        csv.row(columns.map { |col| format_value(record.read_attribute(col)) })
      end
    end
  end
  
  def export_to_file(records : Array(Grant::Base), filename : String, columns : Array(String)? = nil)
    File.write(filename, export(records, columns))
  end
  
  private def format_value(value) : String
    case value
    when Nil
      ""
    when Time
      value.to_s("%Y-%m-%d %H:%M:%S")
    when Bool
      value ? "true" : "false"
    when Array
      value.join(", ")
    when JSON::Any
      value.to_json
    else
      value.to_s
    end
  end
end

class User < Grant::Base
  column id : Int64, primary: true
  column name : String
  column email : String
  column created_at : Time
  
  def self.export_to_csv(filename : String = "users.csv")
    users = all.to_a
    columns = ["id", "name", "email", "created_at"]
    
    CsvExporter.export_to_file(users, filename, columns)
  end
end
```

### Advanced CSV Export with Streaming

```crystal
class StreamingCsvExporter
  def self.export(scope : Grant::Query, columns : Array(String), io : IO)
    csv = CSV::Builder.new(io)
    
    # Write header
    csv.row(columns)
    
    # Stream records in batches
    scope.find_in_batches(batch_size: 1000) do |batch|
      batch.each do |record|
        csv.row(columns.map { |col| format_value(record, col) })
      end
    end
  end
  
  def self.export_with_associations(scope : Grant::Query, config : ExportConfig, io : IO)
    csv = CSV::Builder.new(io)
    
    # Build header with associations
    headers = build_headers(config)
    csv.row(headers)
    
    # Include associations for efficiency
    scope = apply_includes(scope, config)
    
    scope.find_in_batches(batch_size: config.batch_size) do |batch|
      batch.each do |record|
        csv.row(build_row(record, config))
      end
    end
  end
  
  private def self.build_headers(config : ExportConfig) : Array(String)
    headers = config.columns.dup
    
    config.associations.each do |assoc_name, assoc_columns|
      assoc_columns.each do |col|
        headers << "#{assoc_name}.#{col}"
      end
    end
    
    headers
  end
  
  private def self.build_row(record, config) : Array(String)
    row = config.columns.map { |col| format_value(record, col) }
    
    config.associations.each do |assoc_name, assoc_columns|
      assoc = record.send(assoc_name)
      if assoc
        assoc_columns.each do |col|
          row << format_value(assoc, col)
        end
      else
        assoc_columns.size.times { row << "" }
      end
    end
    
    row
  end
end

struct ExportConfig
  property columns : Array(String)
  property associations : Hash(String, Array(String))
  property batch_size : Int32 = 1000
  
  def initialize(@columns, @associations = {} of String => Array(String), @batch_size = 1000)
  end
end
```

### CSV Import

```crystal
class CsvImporter
  property errors : Array(ImportError) = [] of ImportError
  property imported_count : Int32 = 0
  property skipped_count : Int32 = 0
  
  struct ImportError
    property row : Int32
    property message : String
    property data : Hash(String, String)
    
    def initialize(@row, @message, @data)
    end
  end
  
  def import(file_path : String, model_class : Grant::Base.class, options = ImportOptions.new)
    CSV.each_row(File.open(file_path)) do |row, row_index|
      next if row_index == 0 && options.has_header
      
      import_row(row, row_index, model_class, options)
    end
    
    self
  end
  
  def import_from_string(csv_string : String, model_class : Grant::Base.class, options = ImportOptions.new)
    CSV.parse(csv_string) do |row, row_index|
      next if row_index == 0 && options.has_header
      
      import_row(row, row_index, model_class, options)
    end
    
    self
  end
  
  private def import_row(row : Array(String), row_index : Int32, model_class, options)
    data = map_row_to_hash(row, options.column_mapping)
    
    # Apply transformations
    data = apply_transformations(data, options.transformations)
    
    # Validate before import
    if options.validate_before_import
      errors = validate_data(data, model_class)
      if errors.any?
        @errors << ImportError.new(row_index, errors.join(", "), data)
        @skipped_count += 1
        return
      end
    end
    
    # Import the record
    begin
      if options.upsert
        upsert_record(model_class, data, options.unique_by)
      else
        create_record(model_class, data)
      end
      @imported_count += 1
    rescue ex
      @errors << ImportError.new(row_index, ex.message || "Unknown error", data)
      @skipped_count += 1
    end
  end
  
  private def map_row_to_hash(row : Array(String), mapping : Hash(Int32, String)) : Hash(String, String)
    data = {} of String => String
    
    mapping.each do |index, column|
      data[column] = row[index]? || ""
    end
    
    data
  end
  
  private def apply_transformations(data : Hash(String, String), transformations) : Hash(String, String)
    transformations.each do |column, transform|
      if value = data[column]?
        data[column] = transform.call(value)
      end
    end
    
    data
  end
  
  private def create_record(model_class, data : Hash(String, String))
    record = model_class.new
    
    data.each do |column, value|
      record.write_attribute(column, parse_value(value, model_class.column_type(column)))
    end
    
    record.save!
  end
  
  private def upsert_record(model_class, data : Hash(String, String), unique_by : Array(String))
    conditions = {} of String => String
    unique_by.each { |col| conditions[col] = data[col] }
    
    record = model_class.find_by(**conditions) || model_class.new
    
    data.each do |column, value|
      record.write_attribute(column, parse_value(value, model_class.column_type(column)))
    end
    
    record.save!
  end
end

struct ImportOptions
  property has_header : Bool = true
  property column_mapping : Hash(Int32, String)
  property transformations : Hash(String, Proc(String, String)) = {} of String => Proc(String, String)
  property validate_before_import : Bool = true
  property upsert : Bool = false
  property unique_by : Array(String) = [] of String
  
  def initialize(@has_header = true, @column_mapping = {} of Int32 => String)
  end
end

# Usage
importer = CsvImporter.new
options = ImportOptions.new(
  column_mapping: {
    0 => "name",
    1 => "email",
    2 => "age"
  },
  transformations: {
    "email" => ->(v : String) { v.downcase },
    "age" => ->(v : String) { v.to_i.to_s }
  },
  upsert: true,
  unique_by: ["email"]
)

importer.import("users.csv", User, options)
puts "Imported: #{importer.imported_count}"
puts "Errors: #{importer.errors.size}"
```

## JSON Import/Export

### JSON Export

```crystal
module JsonExporter
  extend self
  
  def export(records : Array(Grant::Base), includes : Array(String) = [] of String) : JSON::Any
    JSON.parse(records.map { |r| record_to_json(r, includes) }.to_json)
  end
  
  def export_single(record : Grant::Base, includes : Array(String) = [] of String) : JSON::Any
    JSON.parse(record_to_json(record, includes).to_json)
  end
  
  private def record_to_json(record, includes) : Hash(String, JSON::Any::Type)
    json = {} of String => JSON::Any::Type
    
    # Add attributes
    record.attributes.each do |key, value|
      json[key] = serialize_value(value)
    end
    
    # Add associations if requested
    includes.each do |association|
      if assoc_value = record.try(&.send(association))
        json[association] = case assoc_value
        when Array
          assoc_value.map { |v| record_to_json(v, [] of String) }
        when Grant::Base
          record_to_json(assoc_value, [] of String)
        else
          nil
        end
      end
    end
    
    json
  end
  
  private def serialize_value(value) : JSON::Any::Type
    case value
    when Time
      value.to_s("%Y-%m-%dT%H:%M:%S%:z")
    when Nil, String, Bool, Int32, Int64, Float32, Float64
      value
    when Array
      value.map { |v| serialize_value(v) }
    when Hash
      value.transform_values { |v| serialize_value(v) }
    else
      value.to_s
    end
  end
end

class Order < Grant::Base
  has_many :line_items
  belongs_to :customer
  
  def to_export_json
    JsonExporter.export_single(self, ["customer", "line_items"])
  end
  
  def self.export_all(filename : String)
    orders = includes(:customer, :line_items).to_a
    json = JsonExporter.export(orders, ["customer", "line_items"])
    File.write(filename, json.to_pretty_json)
  end
end
```

### JSON Import

```crystal
class JsonImporter
  property imported : Array(Grant::Base) = [] of Grant::Base
  property errors : Array(String) = [] of String
  
  def import(json_string : String, model_class : Grant::Base.class)
    data = JSON.parse(json_string)
    
    case data
    when .as_a?
      import_array(data.as_a, model_class)
    when .as_h?
      import_single(data.as_h, model_class)
    else
      @errors << "Invalid JSON format"
    end
    
    self
  end
  
  def import_with_associations(json : JSON::Any, model_class : Grant::Base.class, associations : Hash(String, Grant::Base.class))
    record_data = json.as_h
    
    # Extract association data
    assoc_data = {} of String => JSON::Any
    associations.keys.each do |key|
      if record_data.has_key?(key)
        assoc_data[key] = record_data.delete(key)
      end
    end
    
    # Create main record
    record = create_from_json(record_data, model_class)
    return unless record
    
    # Create associations
    assoc_data.each do |assoc_name, assoc_json|
      assoc_class = associations[assoc_name]
      
      case assoc_json
      when .as_a?
        # Has many relationship
        assoc_json.as_a.each do |item|
          assoc_record = create_from_json(item.as_h, assoc_class)
          if assoc_record
            # Set foreign key
            assoc_record.write_attribute("#{model_class.table_name.singularize}_id", record.id)
            assoc_record.save!
          end
        end
      when .as_h?
        # Has one relationship
        assoc_record = create_from_json(assoc_json.as_h, assoc_class)
        if assoc_record
          assoc_record.write_attribute("#{model_class.table_name.singularize}_id", record.id)
          assoc_record.save!
        end
      end
    end
    
    @imported << record
  rescue ex
    @errors << "Import failed: #{ex.message}"
  end
  
  private def create_from_json(data : Hash(String, JSON::Any), model_class) : Grant::Base?
    record = model_class.new
    
    data.each do |key, value|
      begin
        record.write_attribute(key, parse_json_value(value))
      rescue
        # Skip attributes that don't exist
      end
    end
    
    record.save!
    record
  rescue ex
    @errors << "Failed to create record: #{ex.message}"
    nil
  end
  
  private def parse_json_value(value : JSON::Any)
    case value.raw
    when String, Bool, Int32, Int64, Float32, Float64, Nil
      value.raw
    when Array
      value.as_a.map { |v| parse_json_value(v) }
    when Hash
      value.as_h.transform_values { |v| parse_json_value(v) }
    else
      value.to_s
    end
  end
end
```

## Bulk Operations

### Bulk Insert

```crystal
class BulkImporter
  def self.import(model_class : Grant::Base.class, data : Array(Hash(String, DB::Any)), batch_size : Int32 = 1000)
    total_imported = 0
    
    data.each_slice(batch_size) do |batch|
      import_batch(model_class, batch)
      total_imported += batch.size
      
      Log.info { "Imported #{total_imported}/#{data.size} records" }
    end
    
    total_imported
  end
  
  private def self.import_batch(model_class, batch : Array(Hash(String, DB::Any)))
    return if batch.empty?
    
    columns = batch.first.keys
    table = model_class.table_name
    
    # Build SQL
    placeholders = batch.map { |_|
      "(#{columns.map { "?" }.join(", ")})"
    }.join(", ")
    
    sql = <<-SQL
      INSERT INTO #{table} (#{columns.join(", ")})
      VALUES #{placeholders}
    SQL
    
    # Flatten values
    values = batch.flat_map { |row| columns.map { |col| row[col] } }
    
    # Execute
    Grant.connection.exec(sql, args: values)
  end
  
  # PostgreSQL COPY for maximum performance
  def self.copy_from_csv(model_class : Grant::Base.class, csv_path : String)
    table = model_class.table_name
    
    sql = <<-SQL
      COPY #{table} FROM STDIN WITH (FORMAT csv, HEADER true)
    SQL
    
    Grant.connection.exec(sql) do |conn|
      File.open(csv_path) do |file|
        IO.copy(file, conn)
      end
    end
  end
end
```

### Bulk Update

```crystal
class BulkUpdater
  def self.update_by_id(model_class : Grant::Base.class, updates : Hash(Int64, Hash(String, DB::Any)))
    updates.each_slice(100) do |batch|
      update_batch(model_class, batch)
    end
  end
  
  def self.update_batch(model_class, batch : Array({Int64, Hash(String, DB::Any)}))
    # PostgreSQL UPDATE with CASE
    table = model_class.table_name
    
    case_statements = {} of String => String
    ids = [] of Int64
    
    batch.each do |id, fields|
      ids << id
      
      fields.each do |column, value|
        case_statements[column] ||= "CASE id\n"
        case_statements[column] += "  WHEN #{id} THEN #{quote_value(value)}\n"
      end
    end
    
    case_statements.transform_values! { |v| v + "END" }
    
    set_clause = case_statements.map { |col, stmt| "#{col} = #{stmt}" }.join(", ")
    
    sql = <<-SQL
      UPDATE #{table}
      SET #{set_clause}
      WHERE id IN (#{ids.join(", ")})
    SQL
    
    Grant.connection.exec(sql)
  end
  
  private def self.quote_value(value : DB::Any) : String
    case value
    when String
      "'#{value.gsub("'", "''")}'"
    when Nil
      "NULL"
    else
      value.to_s
    end
  end
end
```

## Export Formats

### Excel Export (using CSV)

```crystal
class ExcelExporter
  def self.export(records : Array(Grant::Base), filename : String)
    # Excel-compatible CSV with UTF-8 BOM
    File.open(filename, "w") do |file|
      # Write UTF-8 BOM for Excel compatibility
      file.write_byte(0xEF_u8)
      file.write_byte(0xBB_u8)
      file.write_byte(0xBF_u8)
      
      csv = CSV::Builder.new(file)
      
      # Headers
      headers = records.first.class.column_names
      csv.row(headers)
      
      # Data
      records.each do |record|
        csv.row(headers.map { |h| format_for_excel(record.read_attribute(h)) })
      end
    end
  end
  
  private def self.format_for_excel(value)
    case value
    when Time
      value.to_s("%Y-%m-%d %H:%M:%S")
    when Float64, Float32
      # Prevent scientific notation for large numbers
      "%.2f" % value
    when Int64, Int32
      # Prefix with ' to prevent Excel from converting
      value > 999999999 ? "'#{value}" : value.to_s
    else
      value.to_s
    end
  end
end
```

### XML Export

```crystal
require "xml"

class XmlExporter
  def self.export(records : Array(Grant::Base), root_name : String = "records")
    XML.build(indent: 2) do |xml|
      xml.element(root_name) do
        records.each do |record|
          export_record(xml, record)
        end
      end
    end
  end
  
  private def self.export_record(xml : XML::Builder, record : Grant::Base)
    xml.element(record.class.name.downcase) do
      record.attributes.each do |key, value|
        xml.element(key) { xml.text(value.to_s) }
      end
    end
  end
end
```

## Data Transformation

### ETL Pipeline

```crystal
class EtlPipeline
  alias Transformer = Proc(Hash(String, String), Hash(String, String))
  
  property extractors : Array(DataExtractor) = [] of DataExtractor
  property transformers : Array(Transformer) = [] of Transformer
  property loader : DataLoader?
  property errors : Array(String) = [] of String
  
  def add_extractor(extractor : DataExtractor)
    @extractors << extractor
    self
  end
  
  def add_transformer(&block : Hash(String, String) -> Hash(String, String))
    @transformers << block
    self
  end
  
  def set_loader(loader : DataLoader)
    @loader = loader
    self
  end
  
  def run
    all_data = [] of Hash(String, String)
    
    # Extract
    @extractors.each do |extractor|
      data = extractor.extract
      all_data.concat(data)
    end
    
    # Transform
    transformed_data = all_data.map do |row|
      @transformers.reduce(row) { |data, transformer| transformer.call(data) }
    end
    
    # Load
    if loader = @loader
      loader.load(transformed_data)
    else
      @errors << "No loader configured"
    end
    
    self
  end
end

abstract class DataExtractor
  abstract def extract : Array(Hash(String, String))
end

class CsvExtractor < DataExtractor
  def initialize(@file_path : String, @column_mapping : Hash(Int32, String))
  end
  
  def extract : Array(Hash(String, String))
    data = [] of Hash(String, String)
    
    CSV.each_row(File.open(@file_path)) do |row|
      record = {} of String => String
      @column_mapping.each do |index, column|
        record[column] = row[index]? || ""
      end
      data << record
    end
    
    data
  end
end

abstract class DataLoader
  abstract def load(data : Array(Hash(String, String)))
end

class DatabaseLoader < DataLoader
  def initialize(@model_class : Grant::Base.class)
  end
  
  def load(data : Array(Hash(String, String)))
    data.each do |row|
      record = @model_class.new
      row.each do |column, value|
        record.write_attribute(column, value)
      end
      record.save!
    end
  end
end

# Usage
pipeline = EtlPipeline.new
pipeline.add_extractor(CsvExtractor.new("input.csv", {0 => "name", 1 => "email"}))
pipeline.add_transformer { |row|
  row["email"] = row["email"].downcase
  row["created_at"] = Time.utc.to_s
  row
}
pipeline.set_loader(DatabaseLoader.new(User))
pipeline.run
```

## Progress Tracking

```crystal
class ImportProgress
  property total : Int32 = 0
  property processed : Int32 = 0
  property succeeded : Int32 = 0
  property failed : Int32 = 0
  property start_time : Time
  property end_time : Time?
  
  def initialize(@total)
    @start_time = Time.utc
  end
  
  def increment(success : Bool)
    @processed += 1
    success ? @succeeded += 1 : @failed += 1
    
    if @processed % 100 == 0
      report_progress
    end
  end
  
  def finish
    @end_time = Time.utc
    report_final
  end
  
  def percentage : Float64
    return 0.0 if @total == 0
    (@processed.to_f / @total) * 100
  end
  
  def elapsed_time : Time::Span
    (end_time || Time.utc) - @start_time
  end
  
  def estimated_remaining : Time::Span?
    return nil if @processed == 0
    
    rate = @processed.to_f / elapsed_time.total_seconds
    remaining = @total - @processed
    
    Time::Span.new(seconds: (remaining / rate).to_i)
  end
  
  private def report_progress
    Log.info { "Progress: #{@processed}/#{@total} (#{percentage.round(2)}%)" }
    Log.info { "Succeeded: #{@succeeded}, Failed: #{@failed}" }
    
    if eta = estimated_remaining
      Log.info { "ETA: #{eta.total_minutes.round} minutes" }
    end
  end
  
  private def report_final
    Log.info { "Import completed in #{elapsed_time.total_seconds} seconds" }
    Log.info { "Total: #{@total}, Succeeded: #{@succeeded}, Failed: #{@failed}" }
  end
end
```

## Testing

```crystal
describe CsvImporter do
  it "imports valid CSV data" do
    csv = <<-CSV
    name,email,age
    John Doe,john@example.com,30
    Jane Smith,jane@example.com,25
    CSV
    
    importer = CsvImporter.new
    options = ImportOptions.new(
      column_mapping: {0 => "name", 1 => "email", 2 => "age"}
    )
    
    importer.import_from_string(csv, User, options)
    
    importer.imported_count.should eq(2)
    importer.errors.should be_empty
    
    User.find_by(email: "john@example.com").not_nil!.name.should eq("John Doe")
  end
  
  it "handles import errors gracefully" do
    csv = <<-CSV
    name,email,age
    ,invalid-email,not-a-number
    CSV
    
    importer = CsvImporter.new
    options = ImportOptions.new(
      column_mapping: {0 => "name", 1 => "email", 2 => "age"}
    )
    
    importer.import_from_string(csv, User, options)
    
    importer.skipped_count.should eq(1)
    importer.errors.size.should eq(1)
    importer.errors.first.message.should contain("invalid")
  end
end
```

## Best Practices

### 1. Validate Before Import

```crystal
# Always validate data before importing
def validate_before_import(data : Hash(String, String)) : Array(String)
  errors = [] of String
  
  errors << "Email required" if data["email"]?.try(&.empty?)
  errors << "Invalid email" unless data["email"]?.try(&.matches?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i))
  
  errors
end
```

### 2. Use Transactions

```crystal
# Wrap imports in transactions for atomicity
Grant.transaction do
  import_users(csv_data)
  import_orders(json_data)
end
```

### 3. Handle Large Files

```crystal
# Stream large files instead of loading into memory
CSV.each_row(File.open("large_file.csv")) do |row|
  process_row(row)
end
```

### 4. Provide Feedback

```crystal
# Give users progress updates
progress = ImportProgress.new(total_rows)
data.each do |row|
  success = import_row(row)
  progress.increment(success)
end
progress.finish
```

## Next Steps

- [Normalization](normalization.md)
- [Migrations](migrations.md)
- [Bulk Operations](../../core-features/crud-operations.md#bulk-operations)
- [Performance Optimization](../performance/query-optimization.md)