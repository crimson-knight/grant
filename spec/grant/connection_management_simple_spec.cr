require "../spec_helper"

# Simple test model
class CMTestModel < Grant::Base
  connection sqlite
  table cm_test_models
  
  column id : Int64, primary: true
  column content : String
end

describe "Grant::ConnectionManagement - Basic Features" do
  describe "database_name" do
    it "stores the database name" do
      CMTestModel.database_name.should eq("sqlite")
    end
  end
  
  describe "mark_write_operation" do
    it "marks write operation" do
      # This should not raise an error
      CMTestModel.mark_write_operation
    end
  end
  
  describe "connected_to" do
    it "temporarily changes database context" do
      original = CMTestModel.database_name
      
      CMTestModel.connected_to(database: "temp_db") do
        CMTestModel.database_name.should eq("temp_db")
      end
      
      CMTestModel.database_name.should eq(original)
    end
  end
  
  describe "preventing writes" do
    it "sets and unsets prevent writes flag" do
      CMTestModel.preventing_writes?.should be_false
      
      CMTestModel.while_preventing_writes do
        CMTestModel.preventing_writes?.should be_true
      end
      
      CMTestModel.preventing_writes?.should be_false
    end
  end
  
  describe "adapter" do
    it "returns an adapter instance" do
      CMTestModel.adapter.should be_a(Grant::Adapter::Base)
    end
  end
end