require "../../spec_helper"

describe "Granite::Dirty" do
  describe "tracking changes" do
    it "tracks when an attribute changes" do
      parent = Parent.new(name: "Original")
      parent.save
      
      parent.name = "Updated"
      parent.name_changed?.should be_true
      parent.changed?.should be_true
      parent.changed_attributes.should eq(["name"])
    end
    
    it "returns false when attribute hasn't changed" do
      parent = Parent.new(name: "Original")
      parent.save
      
      parent.name_changed?.should be_false
      parent.changed?.should be_false
    end
    
    it "tracks the original value" do
      parent = Parent.new(name: "Original")
      parent.save
      
      parent.name = "Updated"
      parent.name_was.should eq("Original")
    end
    
    it "tracks the change tuple" do
      parent = Parent.new(name: "Original")
      parent.save
      
      parent.name = "Updated"
      change = parent.name_change
      change.should_not be_nil
      change.not_nil![0].should eq("Original")
      change.not_nil![1].should eq("Updated")
    end
    
    it "tracks multiple attribute changes" do
      parent = Parent.new(name: "John")
      parent.save
      
      parent.name = "Jane"
      parent.created_at = Time.utc(2023, 1, 1)
      
      parent.changed?.should be_true
      parent.changed_attributes.should contain("name")
      parent.changed_attributes.should contain("created_at")
      
      changes = parent.changes
      changes["name"].should eq({"John", "Jane"})
      # Note: created_at comparison would be complex due to Time equality
    end
  end
  
  describe "restoring attributes" do
    it "can restore a single attribute" do
      parent = Parent.new(name: "Original")
      parent.save
      
      parent.name = "Updated"
      parent.restore_attributes(["name"])
      
      parent.name.should eq("Original")
      parent.name_changed?.should be_false
    end
    
    it "can restore all changed attributes" do
      parent = Parent.new(name: "John")
      parent.save
      
      original_created_at = parent.created_at
      parent.name = "Jane"
      parent.created_at = Time.utc(2023, 1, 1)
      
      parent.restore_attributes
      
      parent.name.should eq("John")
      parent.created_at.should eq(original_created_at)
      parent.changed?.should be_false
    end
  end
  
  describe "after save" do
    it "clears dirty state after successful save" do
      parent = Parent.new(name: "Original")
      parent.save
      
      parent.name = "Updated"
      parent.changed?.should be_true
      
      parent.save
      
      parent.changed?.should be_false
      parent.name_changed?.should be_false
    end
    
    it "tracks previous changes after save" do
      parent = Parent.new(name: "Original")
      parent.save
      
      parent.name = "Updated"
      parent.save
      
      parent.previous_changes["name"].should eq({"Original", "Updated"})
      parent.saved_changes["name"].should eq({"Original", "Updated"})
      parent.saved_change_to_attribute?("name").should be_true
      parent.name_before_last_save.should eq("Original")
    end
  end
  
  describe "with new records" do
    it "doesn't mark new records as changed on initialization" do
      parent = Parent.new(name: "New")
      parent.changed?.should be_false
      parent.name_changed?.should be_false
    end
    
    it "tracks changes after initial save" do
      parent = Parent.new(name: "New")
      parent.save
      
      parent.name = "Updated"
      parent.name_changed?.should be_true
      parent.name_was.should eq("New")
    end
  end
  
  describe "edge cases" do
    it "doesn't mark as changed when setting same value" do
      parent = Parent.new(name: "Same")
      parent.save
      
      parent.name = "Same"
      parent.name_changed?.should be_false
      parent.changed?.should be_false
    end
    
    it "removes from changed when reverting to original value" do
      parent = Parent.new(name: "Original")
      parent.save
      
      parent.name = "Updated"
      parent.name_changed?.should be_true
      
      parent.name = "Original"
      parent.name_changed?.should be_false
      parent.changed?.should be_false
    end
  end
end