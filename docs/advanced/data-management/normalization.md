---
title: "Database Normalization"
category: "advanced"
subcategory: "data-management"
tags: ["normalization", "database-design", "relationships", "denormalization", "performance", "data-integrity"]
complexity: "advanced"
version: "1.0.0"
prerequisites: ["../../core-features/relationships.md", "../../core-features/models-and-columns.md", "migrations.md"]
related_docs: ["migrations.md", "imports-exports.md", "../performance/query-optimization.md"]
last_updated: "2025-01-13"
estimated_read_time: "18 minutes"
use_cases: ["database-design", "schema-optimization", "data-integrity", "performance-tuning", "refactoring"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Database Normalization

Comprehensive guide to implementing proper database normalization in Grant applications, including normal forms, denormalization strategies, and balancing data integrity with performance.

## Overview

Database normalization is the process of organizing data to minimize redundancy and improve data integrity. This guide covers:

- Understanding normal forms (1NF through 5NF)
- Implementing normalized schemas in Grant
- Strategic denormalization for performance
- Balancing normalization with query efficiency
- Migration strategies for schema refactoring

## Normal Forms

### First Normal Form (1NF)

```crystal
# Violation: Repeating groups and multi-valued attributes
class BadProduct < Grant::Base
  # Multiple values in single column
  column id : Int64, primary: true
  column name : String
  column colors : String  # "red, blue, green"
  column sizes : String   # "S, M, L, XL"
  column price : Float64
end

# 1NF: Atomic values, no repeating groups
class Product < Grant::Base
  column id : Int64, primary: true
  column name : String
  column price : Float64
  
  has_many :product_colors
  has_many :product_sizes
end

class ProductColor < Grant::Base
  column id : Int64, primary: true
  column product_id : Int64
  column color : String
  
  belongs_to :product
  
  # Ensure uniqueness
  validates_uniqueness_of :color, scope: :product_id
end

class ProductSize < Grant::Base
  column id : Int64, primary: true
  column product_id : Int64
  column size : String
  column stock_quantity : Int32 = 0
  
  belongs_to :product
  
  validates_uniqueness_of :size, scope: :product_id
end
```

### Second Normal Form (2NF)

```crystal
# Violation: Partial dependencies on composite key
class BadOrderItem < Grant::Base
  column order_id : Int64
  column product_id : Int64
  column quantity : Int32
  column product_name : String  # Depends only on product_id
  column product_price : Float64  # Depends only on product_id
  column order_date : Time  # Depends only on order_id
  
  # Composite primary key
  primary_key [:order_id, :product_id]
end

# 2NF: Remove partial dependencies
class Order < Grant::Base
  column id : Int64, primary: true
  column order_date : Time
  column customer_id : Int64
  column total : Float64
  
  has_many :order_items
  belongs_to :customer
end

class OrderItem < Grant::Base
  column id : Int64, primary: true
  column order_id : Int64
  column product_id : Int64
  column quantity : Int32
  column unit_price : Float64  # Snapshot at time of order
  column subtotal : Float64
  
  belongs_to :order
  belongs_to :product
  
  before_save :calculate_subtotal
  
  private def calculate_subtotal
    self.subtotal = quantity * unit_price
  end
end

class Product < Grant::Base
  column id : Int64, primary: true
  column name : String
  column current_price : Float64
  column description : String
  
  has_many :order_items
end
```

### Third Normal Form (3NF)

```crystal
# Violation: Transitive dependencies
class BadEmployee < Grant::Base
  column id : Int64, primary: true
  column name : String
  column department_id : Int64
  column department_name : String  # Depends on department_id
  column department_location : String  # Depends on department_id
  column manager_name : String  # Depends on department_id
end

# 3NF: Remove transitive dependencies
class Employee < Grant::Base
  column id : Int64, primary: true
  column name : String
  column email : String
  column department_id : Int64
  column hire_date : Time
  
  belongs_to :department
  
  # Access department info through relationship
  delegate department_name, department_location, to: :department
end

class Department < Grant::Base
  column id : Int64, primary: true
  column name : String
  column location : String
  column manager_id : Int64?
  
  has_many :employees
  belongs_to :manager, class_name: "Employee", foreign_key: :manager_id
  
  # Prevent circular dependencies
  validate :manager_must_be_in_department
  
  private def manager_must_be_in_department
    if manager_id && manager
      unless manager.department_id == id
        errors.add(:manager_id, "must be an employee in this department")
      end
    end
  end
end
```

### Boyce-Codd Normal Form (BCNF)

```crystal
# Violation: Non-trivial functional dependencies
class BadCourseSchedule < Grant::Base
  column student_id : Int64
  column course_id : Int64
  column instructor_id : Int64
  column room_number : String
  column time_slot : String
  
  # Problem: instructor -> course (each instructor teaches only one course)
  # But student_id, course_id is the candidate key
end

# BCNF: Decompose to remove anomalies
class CourseOffering < Grant::Base
  column id : Int64, primary: true
  column course_id : Int64
  column instructor_id : Int64
  column room_number : String
  column time_slot : String
  column semester : String
  column year : Int32
  
  belongs_to :course
  belongs_to :instructor
  has_many :enrollments
  
  validates_uniqueness_of :room_number, scope: [:time_slot, :semester, :year]
  validates_uniqueness_of :instructor_id, scope: [:time_slot, :semester, :year]
end

class Enrollment < Grant::Base
  column id : Int64, primary: true
  column student_id : Int64
  column course_offering_id : Int64
  column grade : String?
  column enrollment_date : Time = Time.utc
  
  belongs_to :student
  belongs_to :course_offering
  
  validates_uniqueness_of :student_id, scope: :course_offering_id
end

class Course < Grant::Base
  column id : Int64, primary: true
  column code : String
  column title : String
  column credits : Int32
  column department_id : Int64
  
  has_many :course_offerings
  belongs_to :department
end

class Instructor < Grant::Base
  column id : Int64, primary: true
  column name : String
  column email : String
  column department_id : Int64
  
  has_many :course_offerings
  belongs_to :department
end
```

### Fourth Normal Form (4NF)

```crystal
# Violation: Multi-valued dependencies
class BadPersonInfo < Grant::Base
  column person_id : Int64
  column skill : String
  column language : String
  
  # Problem: skills and languages are independent
  # Leads to redundancy: (John, Python, English), (John, Python, Spanish)
end

# 4NF: Separate independent multi-valued attributes
class Person < Grant::Base
  column id : Int64, primary: true
  column name : String
  column email : String
  
  has_many :person_skills
  has_many :person_languages
  has_many :skills, through: :person_skills
  has_many :languages, through: :person_languages
end

class Skill < Grant::Base
  column id : Int64, primary: true
  column name : String
  column category : String
  
  has_many :person_skills
  has_many :people, through: :person_skills
end

class PersonSkill < Grant::Base
  column id : Int64, primary: true
  column person_id : Int64
  column skill_id : Int64
  column proficiency_level : String  # "beginner", "intermediate", "expert"
  column years_experience : Int32
  
  belongs_to :person
  belongs_to :skill
  
  validates_uniqueness_of :skill_id, scope: :person_id
end

class Language < Grant::Base
  column id : Int64, primary: true
  column name : String
  column iso_code : String
end

class PersonLanguage < Grant::Base
  column id : Int64, primary: true
  column person_id : Int64
  column language_id : Int64
  column proficiency : String  # "native", "fluent", "intermediate", "basic"
  column is_primary : Bool = false
  
  belongs_to :person
  belongs_to :language
  
  validates_uniqueness_of :language_id, scope: :person_id
end
```

## Denormalization Strategies

### Calculated Fields for Performance

```crystal
class Order < Grant::Base
  column id : Int64, primary: true
  column customer_id : Int64
  
  # Denormalized for performance
  column items_count : Int32 = 0
  column total_amount : Float64 = 0.0
  column status : String = "pending"
  
  has_many :order_items
  
  # Keep denormalized fields in sync
  def recalculate_totals!
    self.items_count = order_items.count
    self.total_amount = order_items.sum(&.subtotal)
    save!
  end
end

class OrderItem < Grant::Base
  column id : Int64, primary: true
  column order_id : Int64
  column product_id : Int64
  column quantity : Int32
  column unit_price : Float64
  column subtotal : Float64
  
  belongs_to :order
  belongs_to :product
  
  # Update parent totals
  after_save :update_order_totals
  after_destroy :update_order_totals
  
  private def update_order_totals
    order.recalculate_totals!
  end
end
```

### Materialized Views

```crystal
class ProductSalesView < Grant::Base
  # Materialized view for complex aggregations
  table "product_sales_summary"
  
  column product_id : Int64, primary: true
  column product_name : String
  column total_quantity_sold : Int64
  column total_revenue : Float64
  column average_price : Float64
  column last_sale_date : Time?
  column customer_count : Int32
  
  belongs_to :product
  
  # Refresh materialized view
  def self.refresh!
    Grant.connection.exec("REFRESH MATERIALIZED VIEW CONCURRENTLY product_sales_summary")
  end
  
  # Schedule periodic refresh
  def self.schedule_refresh(interval : Time::Span = 1.hour)
    spawn do
      loop do
        sleep interval
        refresh!
      rescue ex
        Log.error { "Failed to refresh materialized view: #{ex.message}" }
      end
    end
  end
end

# Migration to create materialized view
class CreateProductSalesView < Grant::Migration
  def up
    execute <<-SQL
      CREATE MATERIALIZED VIEW product_sales_summary AS
      SELECT 
        p.id as product_id,
        p.name as product_name,
        COALESCE(SUM(oi.quantity), 0) as total_quantity_sold,
        COALESCE(SUM(oi.subtotal), 0) as total_revenue,
        COALESCE(AVG(oi.unit_price), 0) as average_price,
        MAX(o.created_at) as last_sale_date,
        COUNT(DISTINCT o.customer_id) as customer_count
      FROM products p
      LEFT JOIN order_items oi ON p.id = oi.product_id
      LEFT JOIN orders o ON oi.order_id = o.id
      GROUP BY p.id, p.name;
      
      CREATE UNIQUE INDEX ON product_sales_summary (product_id);
    SQL
  end
  
  def down
    execute "DROP MATERIALIZED VIEW IF EXISTS product_sales_summary"
  end
end
```

### Strategic Duplication

```crystal
class User < Grant::Base
  column id : Int64, primary: true
  column email : String
  column name : String
  
  # Denormalized for frequent access
  column full_address : String?
  column primary_phone : String?
  
  has_one :address, -> { where(is_primary: true) }
  has_many :addresses
  has_many :phone_numbers
  
  after_save :update_denormalized_fields
  
  private def update_denormalized_fields
    if primary_addr = address
      self.full_address = primary_addr.full_address
    end
    
    if primary_phone = phone_numbers.find(&.is_primary)
      self.primary_phone = primary_phone.formatted_number
    end
    
    save! if changed?
  end
end

class Address < Grant::Base
  column id : Int64, primary: true
  column user_id : Int64
  column street : String
  column city : String
  column state : String
  column postal_code : String
  column country : String
  column is_primary : Bool = false
  
  belongs_to :user
  
  after_save :update_user_denormalized_fields
  
  def full_address : String
    "#{street}, #{city}, #{state} #{postal_code}, #{country}"
  end
  
  private def update_user_denormalized_fields
    user.update_denormalized_fields if is_primary
  end
end
```

## Hybrid Approaches

### JSON for Sparse Data

```crystal
class Product < Grant::Base
  column id : Int64, primary: true
  column name : String
  column category_id : Int64
  column price : Float64
  
  # Normalized core attributes
  belongs_to :category
  
  # Denormalized sparse attributes in JSON
  column attributes : JSON::Any = JSON.parse("{}"),
    converter: Grant::Converters::Json(JSON::Any)
  
  # Hybrid access pattern
  def get_attribute(key : String) : JSON::Any?
    attributes[key]?
  end
  
  def set_attribute(key : String, value : JSON::Any::Type)
    attrs = attributes.as_h
    attrs[key] = JSON::Any.new(value)
    self.attributes = JSON::Any.new(attrs)
  end
  
  # Query JSON attributes (PostgreSQL)
  scope :with_attribute, ->(key : String, value : String) {
    where("attributes @> ?", {key => value}.to_json)
  }
end
```

### Temporal Denormalization

```crystal
class OrderSnapshot < Grant::Base
  # Point-in-time denormalization for historical data
  column id : Int64, primary: true
  column order_id : Int64
  column snapshot_date : Time = Time.utc
  
  # Denormalized data at time of snapshot
  column customer_name : String
  column customer_email : String
  column shipping_address : String
  column items_json : JSON::Any,
    converter: Grant::Converters::Json(JSON::Any)
  column total_amount : Float64
  
  belongs_to :order
  
  def self.create_for_order(order : Order) : OrderSnapshot
    create!(
      order_id: order.id,
      customer_name: order.customer.name,
      customer_email: order.customer.email,
      shipping_address: order.shipping_address.full_address,
      items_json: JSON.parse(order.order_items.map { |item|
        {
          product_name: item.product.name,
          quantity: item.quantity,
          unit_price: item.unit_price,
          subtotal: item.subtotal
        }
      }.to_json),
      total_amount: order.total_amount
    )
  end
end
```

## Migration Strategies

### Gradual Normalization

```crystal
class NormalizationMigration < Grant::Migration
  def up
    # Step 1: Add new normalized tables
    create_table :categories do |t|
      t.string :name, null: false
      t.string :description
      t.timestamps
    end
    
    # Step 2: Populate from denormalized data
    execute <<-SQL
      INSERT INTO categories (name, description, created_at, updated_at)
      SELECT DISTINCT category_name, category_description, NOW(), NOW()
      FROM products
      WHERE category_name IS NOT NULL;
    SQL
    
    # Step 3: Add foreign key column
    add_column :products, :category_id, :integer
    
    # Step 4: Populate foreign keys
    execute <<-SQL
      UPDATE products p
      SET category_id = (
        SELECT c.id FROM categories c
        WHERE c.name = p.category_name
      );
    SQL
    
    # Step 5: Add constraints
    add_foreign_key :products, :categories
    
    # Step 6: Remove denormalized columns (after verification)
    # remove_column :products, :category_name
    # remove_column :products, :category_description
  end
  
  def down
    # Reverse the normalization
    execute <<-SQL
      UPDATE products p
      SET category_name = c.name,
          category_description = c.description
      FROM categories c
      WHERE p.category_id = c.id;
    SQL
    
    remove_column :products, :category_id
    drop_table :categories
  end
end
```

### Data Integrity During Migration

```crystal
class SafeNormalizationHelper
  def self.normalize_with_validation(source_table : String, target_table : String, mappings : Hash(String, String))
    # Begin transaction for atomicity
    Grant.transaction do
      # Create temporary validation table
      Grant.connection.exec(<<-SQL)
        CREATE TEMP TABLE validation_errors (
          source_id INTEGER,
          error_message TEXT
        );
      SQL
      
      # Validate data before migration
      validate_data(source_table, mappings)
      
      # Check for validation errors
      error_count = Grant.connection.scalar("SELECT COUNT(*) FROM validation_errors").as(Int64)
      
      if error_count > 0
        # Log errors and rollback
        Log.error { "Found #{error_count} validation errors" }
        raise "Validation failed - rolling back"
      end
      
      # Proceed with normalization
      perform_normalization(source_table, target_table, mappings)
    end
  end
  
  private def self.validate_data(source_table : String, mappings : Hash(String, String))
    # Check for nulls in required fields
    mappings.each do |source_col, target_col|
      Grant.connection.exec(<<-SQL)
        INSERT INTO validation_errors (source_id, error_message)
        SELECT id, 'NULL value in #{source_col}'
        FROM #{source_table}
        WHERE #{source_col} IS NULL;
      SQL
    end
    
    # Check for duplicates that would violate uniqueness
    # Add more validation as needed
  end
  
  private def self.perform_normalization(source_table : String, target_table : String, mappings : Hash(String, String))
    columns = mappings.keys.join(", ")
    values = mappings.values.join(", ")
    
    Grant.connection.exec(<<-SQL)
      INSERT INTO #{target_table} (#{values})
      SELECT DISTINCT #{columns}
      FROM #{source_table};
    SQL
  end
end
```

## Performance Considerations

### Query Performance Analysis

```crystal
class NormalizationAnalyzer
  def self.analyze_join_performance(query : String)
    # Explain analyze for PostgreSQL
    result = Grant.connection.exec("EXPLAIN ANALYZE #{query}")
    
    # Parse execution time
    execution_time = extract_execution_time(result)
    
    # Check for performance issues
    if execution_time > 100.0  # ms
      Log.warn { "Slow query detected: #{execution_time}ms" }
      suggest_optimizations(result)
    end
    
    result
  end
  
  def self.compare_normalized_vs_denormalized
    # Normalized query
    normalized_time = benchmark_query(<<-SQL)
      SELECT o.*, c.name, c.email, a.full_address
      FROM orders o
      JOIN customers c ON o.customer_id = c.id
      JOIN addresses a ON c.id = a.customer_id AND a.is_primary = true
      WHERE o.created_at > NOW() - INTERVAL '30 days'
    SQL
    
    # Denormalized query
    denormalized_time = benchmark_query(<<-SQL)
      SELECT *
      FROM orders_denormalized
      WHERE created_at > NOW() - INTERVAL '30 days'
    SQL
    
    {
      normalized: normalized_time,
      denormalized: denormalized_time,
      ratio: normalized_time / denormalized_time
    }
  end
  
  private def self.benchmark_query(query : String) : Float64
    start = Time.monotonic
    Grant.connection.exec(query)
    (Time.monotonic - start).total_milliseconds
  end
end
```

### Indexing for Normalized Tables

```crystal
class OptimizedIndexing < Grant::Migration
  def up
    # Foreign key indexes
    add_index :order_items, :order_id
    add_index :order_items, :product_id
    
    # Composite indexes for common joins
    add_index :order_items, [:order_id, :product_id], unique: true
    
    # Covering indexes for frequent queries
    execute <<-SQL
      CREATE INDEX idx_orders_customer_date 
      ON orders(customer_id, created_at DESC)
      INCLUDE (total_amount, status);
    SQL
    
    # Partial indexes for filtered queries
    execute <<-SQL
      CREATE INDEX idx_orders_pending
      ON orders(created_at)
      WHERE status = 'pending';
    SQL
  end
end
```

## Testing Normalization

```crystal
describe "Database Normalization" do
  describe "1NF compliance" do
    it "stores atomic values" do
      product = Product.create!(name: "Shirt", price: 29.99)
      
      # Colors stored separately
      product.product_colors.create!(color: "red")
      product.product_colors.create!(color: "blue")
      
      product.product_colors.pluck(:color).should eq(["red", "blue"])
    end
  end
  
  describe "referential integrity" do
    it "maintains foreign key constraints" do
      expect_raises(Grant::ForeignKeyViolation) do
        OrderItem.create!(
          order_id: 999999,  # Non-existent
          product_id: 1,
          quantity: 1
        )
      end
    end
  end
  
  describe "denormalization sync" do
    it "keeps denormalized fields updated" do
      order = Order.create!(customer_id: 1)
      
      order.order_items.create!(
        product_id: 1,
        quantity: 2,
        unit_price: 10.0
      )
      
      order.reload
      order.items_count.should eq(1)
      order.total_amount.should eq(20.0)
    end
  end
end
```

## Best Practices

### 1. Start with 3NF

```crystal
# Default to 3NF for new applications
# Only denormalize when performance demands it
class InitialSchema < Grant::Migration
  def up
    # Start with normalized structure
    create_table :users
    create_table :profiles
    create_table :addresses
    
    # Add foreign keys for integrity
    add_foreign_key :profiles, :users
    add_foreign_key :addresses, :users
  end
end
```

### 2. Document Denormalization

```crystal
class Order < Grant::Base
  # DENORMALIZED: customer_name is duplicated from customers table
  # Reason: Avoid join in high-frequency order listing queries
  # Sync: Updated via after_save callback on Customer model
  column customer_name : String
  
  # DENORMALIZED: total_amount calculated from order_items
  # Reason: Avoid aggregation in order lists
  # Sync: Updated via OrderItem callbacks
  column total_amount : Float64
end
```

### 3. Monitor and Measure

```crystal
class PerformanceMonitor
  def self.track_denormalization_impact
    # Track query performance
    metrics = {
      before_denormalization: benchmark_queries,
      apply_denormalization: apply_changes,
      after_denormalization: benchmark_queries
    }
    
    # Log improvements
    improvement = calculate_improvement(metrics)
    Log.info { "Performance improvement: #{improvement}%" }
  end
end
```

### 4. Use Database Features

```crystal
# PostgreSQL computed columns
execute <<-SQL
  ALTER TABLE orders
  ADD COLUMN total_with_tax DECIMAL(10,2)
  GENERATED ALWAYS AS (total_amount * 1.1) STORED;
SQL

# MySQL generated columns
execute <<-SQL
  ALTER TABLE products
  ADD COLUMN search_text VARCHAR(500)
  GENERATED ALWAYS AS (CONCAT(name, ' ', IFNULL(description, ''))) STORED;
SQL
```

## Next Steps

- [Migrations](migrations.md)
- [Imports and Exports](imports-exports.md)
- [Query Optimization](../performance/query-optimization.md)
- [Relationships](../../core-features/relationships.md)