require "../src/grant"
require "../src/adapter/sqlite"

# Configure Grant to use SQLite
Grant::Connections << Grant::Adapter::Sqlite.new(name: "sqlite", url: "sqlite3://./example.db")

# Example model with optimistic locking
class Product < Grant::Base
  connection sqlite
  table products
  
  # Include optimistic locking - adds lock_version column
  include Grant::Locking::Optimistic
  
  column id : Int64, primary: true, auto: true
  column name : String
  column price : Float64
  column stock : Int32
end

# Create the table
Product.migrator.drop_and_create

# Example 1: Basic Transaction
puts "=== Example 1: Basic Transaction ==="
Product.transaction do
  product1 = Product.create!(name: "Laptop", price: 999.99, stock: 10)
  product2 = Product.create!(name: "Mouse", price: 29.99, stock: 50)
  puts "Created #{Product.count} products in transaction"
end

# Example 2: Transaction Rollback
puts "\n=== Example 2: Transaction Rollback ==="
begin
  Product.transaction do
    Product.create!(name: "Keyboard", price: 79.99, stock: 30)
    puts "Products before rollback: #{Product.count}"
    raise "Simulated error!"
  end
rescue
  puts "Transaction rolled back. Products after: #{Product.count}"
end

# Example 3: Nested Transactions with Savepoints
puts "\n=== Example 3: Nested Transactions ==="
Product.transaction do
  Product.create!(name: "Monitor", price: 299.99, stock: 15)
  
  # This nested transaction will be rolled back
  Product.transaction do
    Product.create!(name: "Temporary Product", price: 1.99, stock: 1)
    raise Grant::Transaction::Rollback.new
  end
  
  puts "Products after nested rollback: #{Product.count}"
end

# Example 4: Pessimistic Locking
puts "\n=== Example 4: Pessimistic Locking ==="
laptop = Product.find_by!(name: "Laptop")

Product.transaction do
  # Lock the record for update
  locked_laptop = Product.where(id: laptop.id).lock.first!
  puts "Locked laptop: #{locked_laptop.name} (stock: #{locked_laptop.stock})"
  
  # Update with confidence that no one else can modify it
  locked_laptop.stock -= 1
  locked_laptop.save!
  puts "Updated stock to: #{locked_laptop.stock}"
end

# Example 5: Block-based Pessimistic Locking
puts "\n=== Example 5: Block-based Locking ==="
Product.with_lock(laptop.id) do |product|
  product.price *= 0.9  # 10% discount
  product.save!
  puts "Applied discount. New price: $#{product.price}"
end

# Example 6: Optimistic Locking
puts "\n=== Example 6: Optimistic Locking ==="
# Simulate concurrent access
user1_product = Product.find!(laptop.id)
user2_product = Product.find!(laptop.id)

# User 1 updates
user1_product.stock -= 1
user1_product.save!
puts "User 1 updated stock to: #{user1_product.stock} (version: #{user1_product.lock_version})"

# User 2 tries to update with stale data
begin
  user2_product.stock -= 2
  user2_product.save!
rescue ex : Grant::Locking::Optimistic::StaleObjectError
  puts "User 2 failed: #{ex.message}"
  puts "Conflict detected! Need to reload and retry."
end

# Example 7: Optimistic Locking with Retry
puts "\n=== Example 7: Optimistic Locking with Retry ==="
mouse = Product.find_by!(name: "Mouse")
retry_count = 0

mouse.with_optimistic_retry(max_retries: 3) do
  retry_count += 1
  
  # Simulate another update happening
  if retry_count == 1
    other = Product.find!(mouse.id)
    other.stock += 10
    other.save!
  end
  
  mouse.stock -= 5
  mouse.save!
end

puts "Updated mouse stock after #{retry_count} attempts"

# Example 8: Transaction Isolation Levels
puts "\n=== Example 8: Transaction Isolation Levels ==="
{% for level in %w[read_uncommitted read_committed repeatable_read serializable] %}
  Product.transaction(isolation: :{{level.id}}) do
    puts "Running with {{level.id}} isolation level"
    # Perform operations with specific isolation guarantees
  end
{% end %}

# Example 9: Different Lock Modes
puts "\n=== Example 9: Different Lock Modes ==="
Product.transaction do
  # Exclusive lock (FOR UPDATE)
  Product.where(name: "Laptop").lock(Grant::Locking::LockMode::Update).first
  puts "Acquired exclusive lock"
  
  # Shared lock (FOR SHARE) - only in PostgreSQL/MySQL
  if Product.adapter.supports_lock_mode?(Grant::Locking::LockMode::Share)
    Product.where(name: "Mouse").lock(Grant::Locking::LockMode::Share).first
    puts "Acquired shared lock"
  end
end

# Example 10: Checking Transaction State
puts "\n=== Example 10: Transaction State ==="
puts "Outside transaction: #{Product.transaction_open?}"

Product.transaction do
  puts "Inside transaction: #{Product.transaction_open?}"
  
  Product.transaction do
    puts "Inside nested transaction: #{Product.transaction_open?}"
  end
end

puts "\nAll examples completed!"
puts "Final product count: #{Product.count}"

# Cleanup
File.delete("./example.db") if File.exists?("./example.db")