require "../../spec_helper"

# Test model with optimistic locking
class OptimisticModel < Granite::Base
  connection sqlite
  table optimistic_models
  
  include Granite::Locking::Optimistic
  
  column id : Int64, primary: true, auto: true
  column name : String
  column value : Int32?
end

OptimisticModel.migrator.drop_and_create

describe Granite::Locking::Optimistic do
  describe "lock_version column" do
    it "is automatically added and defaults to 0" do
      model = OptimisticModel.new(name: "Test")
      model.lock_version.should eq(0)
    end
    
    it "increments on update" do
      model = OptimisticModel.create!(name: "Test")
      model.lock_version.should eq(0)
      
      model.name = "Updated"
      model.save!
      model.lock_version.should eq(1)
      
      model.name = "Updated Again"
      model.save!
      model.lock_version.should eq(2)
    end
    
    it "does not increment on create" do
      model = OptimisticModel.new(name: "Test")
      model.save!
      model.lock_version.should eq(0)
    end
  end
  
  describe "concurrent update detection" do
    it "raises StaleObjectError when lock version conflicts" do
      model = OptimisticModel.create!(name: "Original", value: 100)
      
      # Simulate concurrent update by loading the same record twice
      user1 = OptimisticModel.find!(model.id)
      user2 = OptimisticModel.find!(model.id)
      
      # User 1 updates
      user1.value = 200
      user1.save!
      
      # User 2 tries to update with stale lock_version
      user2.value = 300
      expect_raises(Granite::Locking::Optimistic::StaleObjectError, /Attempted to update a stale OptimisticModel/) do
        user2.save!
      end
      
      # Verify user1's update persisted
      fresh = OptimisticModel.find!(model.id)
      fresh.value.should eq(200)
      fresh.lock_version.should eq(1)
    end
    
    it "allows update when lock version matches" do
      model = OptimisticModel.create!(name: "Test")
      model.lock_version.should eq(0)
      
      # Load and update
      loaded = OptimisticModel.find!(model.id)
      loaded.name = "Updated"
      loaded.save!
      
      loaded.lock_version.should eq(1)
      loaded.name.should eq("Updated")
    end
  end
  
  describe "#with_optimistic_retry" do
    it "retries on stale object error" do
      model = OptimisticModel.create!(name: "Original", value: 100)
      retry_count = 0
      
      # Simulate concurrent update
      concurrent = OptimisticModel.find!(model.id)
      concurrent.value = 200
      concurrent.save!
      
      model.with_optimistic_retry(max_retries: 2) do
        retry_count += 1
        model.value = (model.value || 0) + 50
        model.save!
      end
      
      retry_count.should eq(2) # First attempt fails, second succeeds
      
      fresh = OptimisticModel.find!(model.id)
      fresh.value.should eq(250) # 200 + 50
      fresh.lock_version.should eq(2)
    end
    
    it "gives up after max retries" do
      model = OptimisticModel.create!(name: "Test")
      
      expect_raises(Granite::Locking::Optimistic::StaleObjectError) do
        model.with_optimistic_retry(max_retries: 1) do
          # Simulate another update happening each time
          other = OptimisticModel.find!(model.id)
          other.name = "Concurrent #{other.lock_version}"
          other.save!
          
          # This will always fail
          model.name = "Never succeeds"
          model.save!
        end
      end
    end
    
    it "uses class-level max retries by default" do
      OptimisticModel.lock_conflict_max_retries = 3
      model = OptimisticModel.create!(name: "Test")
      attempts = 0
      
      begin
        model.with_optimistic_retry do
          attempts += 1
          # Always fail
          other = OptimisticModel.find!(model.id)
          other.save!
          model.save!
        end
      rescue Granite::Locking::Optimistic::StaleObjectError
        # Expected
      end
      
      attempts.should eq(4) # Initial + 3 retries
    ensure
      OptimisticModel.lock_conflict_max_retries = 0
    end
  end
  
  describe "#reload" do
    it "updates lock_version_was" do
      model = OptimisticModel.create!(name: "Test")
      
      # Another process updates
      other = OptimisticModel.find!(model.id)
      other.name = "Updated by other"
      other.save!
      
      # Reload should update lock_version_was
      model.reload
      model.lock_version.should eq(1)
      model.lock_version_was.should eq(1)
      
      # Now update should succeed
      model.name = "Updated after reload"
      model.save!
      model.lock_version.should eq(2)
    end
  end
  
  describe "StaleObjectError" do
    it "includes helpful information" do
      model = OptimisticModel.create!(name: "Test")
      
      begin
        # Force stale error
        other = OptimisticModel.find!(model.id)
        other.save!
        model.save!
      rescue ex : Granite::Locking::Optimistic::StaleObjectError
        ex.record_class.should eq("OptimisticModel")
        ex.record_id.should eq(model.id.to_s)
        ex.message.should match(/OptimisticModel.*id: #{model.id}/)
      end
    end
  end
end