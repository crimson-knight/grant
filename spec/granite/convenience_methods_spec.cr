require "../spec_helper"

describe "Granite::ConvenienceMethods" do
  # Create table before tests
  before_all do
    ConvenienceUser.migrator.drop_and_create
    # Add unique constraint for upsert tests
    ConvenienceUser.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_convenience_users_email ON convenience_users(email)")
  end
  
  before_each do
    ConvenienceUser.clear
    # Also clear the test database directly to ensure clean state
    ConvenienceUser.adapter.open do |db|
      db.exec("DELETE FROM convenience_users")
    end
  end
  
  describe "#pluck" do
    it "extracts single column values" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      names = ConvenienceUser.order(id: :asc).pluck(:name)
      names.should eq([["John"], ["Jane"]])
    end
    
    it "extracts multiple column values" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      data = ConvenienceUser.order(id: :asc).pluck(:name, :age)
      data.should eq([["John", 25], ["Jane", 30]])
    end
    
    it "respects where conditions" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      ConvenienceUser.create!(name: "Jim", email: "jim@example.com", age: 35)
      
      names = ConvenienceUser.where(age: 30..40).order(age: :asc).pluck(:name)
      names.should eq([["Jane"], ["Jim"]])
    end
    
    it "respects order" do
      ConvenienceUser.create!(name: "Charlie", email: "charlie@example.com", age: 35)
      ConvenienceUser.create!(name: "Alice", email: "alice@example.com", age: 25)
      ConvenienceUser.create!(name: "Bob", email: "bob@example.com", age: 30)
      
      names = ConvenienceUser.order(name: :asc).pluck(:name)
      names.should eq([["Alice"], ["Bob"], ["Charlie"]])
    end
  end
  
  describe "#pick" do
    it "extracts values from the first record" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      data = ConvenienceUser.order(name: :asc).pick(:name, :age)
      data.should eq(["Jane", 30])
    end
    
    it "returns nil when no records exist" do
      data = ConvenienceUser.pick(:name, :age)
      data.should be_nil
    end
    
    it "respects where conditions" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      data = ConvenienceUser.where(age: 30..30).pick(:name, :age)
      data.should eq(["Jane", 30])
    end
  end
  
  describe "#in_batches" do
    it "processes records in batches" do
      10.times do |i|
        ConvenienceUser.create!(name: "User#{i}", email: "user#{i}@example.com", age: 20 + i)
      end
      
      # Verify all records were created
      total_users = ConvenienceUser.count
      total_users.should eq(10)
      
      batch_sizes = [] of Int32
      total_processed = 0
      ConvenienceUser.in_batches(of: 3) do |batch|
        batch_sizes << batch.size
        total_processed += batch.size
      end
      
      total_processed.should eq(10)
      batch_sizes.should eq([3, 3, 3, 1])
    end
    
    it "respects start and finish constraints" do
      10.times do |i|
        ConvenienceUser.create!(name: "User#{i}", email: "user#{i}@example.com", age: 20 + i)
      end
      
      users = ConvenienceUser.order(id: :asc).select
      users.size.should eq(10)
      
      start_id = users[2].id!
      finish_id = users[7].id!
      
      processed_ids = [] of Int64
      ConvenienceUser.in_batches(of: 2, start: start_id, finish: finish_id) do |batch|
        batch.each { |user| processed_ids << user.id! }
      end
      
      processed_ids.size.should eq(6) # IDs 3 through 8
      processed_ids.min.should eq(start_id)
      processed_ids.max.should eq(finish_id)
    end
    
    it "processes batches in descending order" do
      5.times do |i|
        ConvenienceUser.create!(name: "User#{i}", email: "user#{i}@example.com", age: 20 + i)
      end
      
      batch_first_names = [] of String
      ConvenienceUser.in_batches(of: 2, order: :desc) do |batch|
        batch_first_names << batch.first.name
      end
      
      # Should process from highest ID to lowest
      batch_first_names.first.should eq("User4")
    end
  end
  
  describe "#annotate" do
    it "adds comments to queries" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      
      # We can't easily test the SQL comment directly, but we can ensure
      # the method works and returns correct results
      users = ConvenienceUser.where(name: "John").annotate("Dashboard query").select
      users.size.should eq(1)
      users.first.name.should eq("John")
    end
  end
  
  describe ".insert_all" do
    it "bulk inserts records" do
      attributes = [
        {"name" => "John", "email" => "john@example.com", "age" => 25},
        {"name" => "Jane", "email" => "jane@example.com", "age" => 30},
        {"name" => "Jim", "email" => "jim@example.com", "age" => 35}
      ]
      
      ConvenienceUser.insert_all(attributes)
      
      users = ConvenienceUser.order(name: :asc).select
      users.size.should eq(3)
      users.map(&.name).sort.should eq(["Jane", "Jim", "John"])
    end
    
    it "handles empty array" do
      records = ConvenienceUser.insert_all([] of Hash(String, Granite::Columns::Type))
      records.should be_empty
    end
    
    it "adds timestamps automatically" do
      attributes = [
        {"name" => "John", "email" => "john@example.com", "age" => 25}
      ]
      
      ConvenienceUser.insert_all(attributes)
      
      user = ConvenienceUser.first!
      user.created_at.should_not be_nil
      user.updated_at.should_not be_nil
    end
    
    it "respects record_timestamps option" do
      timestamp = Time.utc(2020, 1, 1)
      attributes = [
        {"name" => "John", "email" => "john@example.com", "age" => 25, 
         "created_at" => timestamp, "updated_at" => timestamp}
      ]
      
      ConvenienceUser.insert_all(attributes, record_timestamps: false)
      
      user = ConvenienceUser.first!
      user.created_at.should eq(timestamp)
      user.updated_at.should eq(timestamp)
    end
  end
  
  describe ".upsert_all" do
    it "inserts new records" do
      attributes = [
        {"name" => "John", "email" => "john@example.com", "age" => 25},
        {"name" => "Jane", "email" => "jane@example.com", "age" => 30}
      ]
      
      ConvenienceUser.upsert_all(attributes, unique_by: [:email])
      
      users = ConvenienceUser.all
      users.size.should eq(2)
    end
    
    it "updates existing records" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      
      attributes = [
        {"name" => "John Doe", "email" => "john@example.com", "age" => 26}
      ]
      
      ConvenienceUser.upsert_all(attributes, unique_by: [:email])
      
      users = ConvenienceUser.all
      users.size.should eq(1)
      users.first.name.should eq("John Doe")
      users.first.age.should eq(26)
    end
    
    it "respects update_only option" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      
      attributes = [
        {"name" => "John Doe", "email" => "john@example.com", "age" => 26}
      ]
      
      ConvenienceUser.upsert_all(attributes, unique_by: [:email], update_only: [:age])
      
      user = ConvenienceUser.first!
      user.name.should eq("John") # Name not updated
      user.age.should eq(26)      # Age updated
    end
    
    it "handles mixed insert and update" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      
      attributes = [
        {"name" => "John Updated", "email" => "john@example.com", "age" => 26},
        {"name" => "Jane", "email" => "jane@example.com", "age" => 30}
      ]
      
      ConvenienceUser.upsert_all(attributes, unique_by: [:email])
      
      users = ConvenienceUser.order(name: :asc).select
      users.size.should eq(2)
      users[0].name.should eq("Jane")
      users[1].name.should eq("John Updated")
    end
  end
  
  describe "#sole" do
    it "returns the single record" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      
      user = ConvenienceUser.sole
      user.name.should eq("John")
    end
    
    it "raises NotFound when no records exist" do
      expect_raises(Granite::Querying::NotFound, "No ConvenienceUser found") do
        ConvenienceUser.sole
      end
    end
    
    it "raises NotUnique when multiple records exist" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      expect_raises(Granite::Querying::NotUnique, "Multiple ConvenienceUser records found") do
        ConvenienceUser.sole
      end
    end
    
    it "works with query builder" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      user = ConvenienceUser.where(name: "John").sole
      user.email.should eq("john@example.com")
    end
  end
  
  describe "#find_sole_by" do
    it "returns the single matching record" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      user = ConvenienceUser.find_sole_by(email: "john@example.com")
      user.name.should eq("John")
    end
    
    it "raises NotFound when no matching record" do
      expect_raises(Granite::Querying::NotFound) do
        ConvenienceUser.find_sole_by(email: "nonexistent@example.com")
      end
    end
    
    it "raises NotUnique when multiple records match" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "John", email: "john2@example.com", age: 30)
      
      expect_raises(Granite::Querying::NotUnique) do
        ConvenienceUser.find_sole_by(name: "John")
      end
    end
  end
  
  describe ".destroy_by" do
    it "destroys all matching records" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      ConvenienceUser.create!(name: "John", email: "john2@example.com", age: 35)
      
      count = ConvenienceUser.destroy_by(name: "John")
      count.should eq(2)
      
      remaining = ConvenienceUser.all
      remaining.size.should eq(1)
      remaining.first.name.should eq("Jane")
    end
    
    it "returns 0 when no records match" do
      count = ConvenienceUser.destroy_by(name: "Nonexistent")
      count.should eq(0)
    end
    
    it "works with query builder" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      ConvenienceUser.create!(name: "Jim", email: "jim@example.com", age: 35)
      
      count = ConvenienceUser.where(age: 30..40).destroy_all
      count.should eq(2)
      
      ConvenienceUser.count.should eq(1)
    end
  end
  
  describe ".delete_by" do
    it "deletes all matching records" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      ConvenienceUser.create!(name: "John", email: "john2@example.com", age: 35)
      
      rows_affected = ConvenienceUser.delete_by(name: "John")
      rows_affected.should eq(2)
      
      ConvenienceUser.count.should eq(1)
    end
    
    it "returns 0 when no records match" do
      rows_affected = ConvenienceUser.delete_by(name: "Nonexistent")
      rows_affected.should eq(0)
    end
  end
  
  describe ".touch_all" do
    it "updates updated_at timestamp" do
      user1 = ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      user2 = ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      original_time = user1.updated_at!
      sleep 1.second  # Ensure time difference for SQLite second precision
      
      rows_affected = ConvenienceUser.touch_all
      rows_affected.should eq(2)
      
      user1 = ConvenienceUser.find!(user1.id!)
      user2 = ConvenienceUser.find!(user2.id!)
      
      user1.updated_at!.should be > original_time
      user2.updated_at!.should be > original_time
    end
    
    it "works with query builder" do
      ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      user2 = ConvenienceUser.create!(name: "Jane", email: "jane@example.com", age: 30)
      
      original_time = user2.updated_at!
      sleep 1.second  # Ensure time difference for SQLite second precision
      
      rows_affected = ConvenienceUser.where(name: "Jane").touch_all
      rows_affected.should eq(1)
      
      user2 = ConvenienceUser.find!(user2.id!)
      user2.updated_at!.should be > original_time
    end
  end
  
  describe ".update_counters" do
    it "increments counter columns" do
      user = ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      
      rows_affected = ConvenienceUser.update_counters(user.id!, {:age => 5})
      rows_affected.should eq(1)
      
      user = ConvenienceUser.find!(user.id!)
      user.age.should eq(30)
    end
    
    it "decrements counter columns" do
      user = ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      
      rows_affected = ConvenienceUser.update_counters(user.id!, {:age => -3})
      rows_affected.should eq(1)
      
      user = ConvenienceUser.find!(user.id!)
      user.age.should eq(22)
    end
    
    it "updates multiple counters" do
      # This test would need additional columns to be meaningful
      # For now, just test with age
      user = ConvenienceUser.create!(name: "John", email: "john@example.com", age: 25)
      
      rows_affected = ConvenienceUser.update_counters(user.id!, {:age => 10})
      rows_affected.should eq(1)
      
      user = ConvenienceUser.find!(user.id!)
      user.age.should eq(35)
    end
    
    it "returns 0 for non-existent record" do
      rows_affected = ConvenienceUser.update_counters(999999, {:age => 5})
      rows_affected.should eq(0)
    end
  end
end

# Test model
class ConvenienceUser < Granite::Base
  connection sqlite
  table convenience_users
  
  column id : Int64, primary: true
  column name : String
  column email : String
  column age : Int32
  column created_at : Time?
  column updated_at : Time?
  
  # Add unique index on email for upsert tests
  # In real app this would be in migration
end