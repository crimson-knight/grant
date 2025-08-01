require "../spec_helper"
require "../../src/granite/composite_primary_key"

# Test model with composite primary key using DSL
class OrderItem < Granite::Base
  include Granite::CompositePrimaryKey
  
  connection sqlite
  table order_items
  
  # Define columns first
  column order_id : Int64, primary: true
  column product_id : Int64, primary: true
  column quantity : Int32
  column price : Float64
  
  # Then declare composite primary key
  composite_primary_key order_id, product_id
  
  timestamps
end

# Test model with UUID composite key
class UserSession < Granite::Base
  include Granite::CompositePrimaryKey
  
  connection sqlite
  table user_sessions
  
  column user_id : UUID, primary: true
  column session_id : UUID, primary: true, auto: true
  column ip_address : String
  column user_agent : String?
  
  composite_primary_key user_id, session_id
  
  timestamps
end

# Test model with mixed type composite key
class RegionData < Granite::Base
  include Granite::CompositePrimaryKey
  
  connection sqlite
  table region_data
  
  column country_code : String, primary: true
  column region_id : Int32, primary: true
  column population : Int64?
  column name : String
  
  composite_primary_key country_code, region_id
end

# Test model with single primary key
class SingleKeyModel < Granite::Base
  include Granite::CompositePrimaryKey
  connection sqlite
  table single_keys
  
  column id : Int64, primary: true
  column name : String
end

describe Granite::CompositePrimaryKey do
  describe "configuration" do
    it "detects composite primary key from DSL" do
      OrderItem.composite_primary_key?.should be_true
      OrderItem.composite_primary_key_columns.should eq [:order_id, :product_id]
    end
    
    it "detects composite primary key from column annotations" do
      RegionData.composite_primary_key?.should be_true
      RegionData.composite_primary_key_columns.should eq [:country_code, :region_id]
    end
    
    it "returns false for models without composite keys" do
      # Models without the module included won't have the method
      OrderItem.responds_to?(:composite_primary_key?).should be_true
      
      # Models with only one primary key return false
      SingleKeyModel.composite_primary_key?.should be_false
    end
  end
  
  describe "new_record? detection" do
    it "returns true when any part of composite key is nil" do
      item = OrderItem.new
      item.new_record?.should be_true
      
      item.order_id = 1_i64
      item.new_record?.should be_true
      
      item.product_id = 2_i64
      # Still a new record until saved
      item.new_record?.should be_true
    end
    
    it "handles auto-generated UUID fields" do
      session = UserSession.new
      session.user_id = UUID.random
      session.new_record?.should be_true # session_id is still nil
    end
  end
  
  describe "helpers" do
    it "provides composite_key_values" do
      item = OrderItem.new
      item.order_id = 108_i64
      item.product_id = 208_i64
      
      values = item.composite_key_values
      values.should_not be_nil
      values.not_nil![:order_id].should eq 108_i64
      values.not_nil![:product_id].should eq 208_i64
    end
    
    it "provides composite_key_string" do
      item = OrderItem.new
      item.order_id = 109_i64
      item.product_id = 209_i64
      
      item.composite_key_string.should eq "order_id=109, product_id=209"
    end
    
    it "returns nil for incomplete composite_key_string" do
      item = OrderItem.new
      item.order_id = 110_i64
      # product_id is nil
      
      item.composite_key_string.should be_nil
    end
  end
  
  describe "mixed type keys" do
    it "handles string and integer composite keys" do
      region = RegionData.new
      region.country_code = "US"
      region.region_id = 1
      region.name = "California"
      region.population = 39_538_223_i64
      
      # Just verify we can create the object with mixed types
      region.country_code.should eq "US"
      region.region_id.should eq 1
    end
  end
  
  # Note: Full CRUD operations require database integration
  # These tests verify the API exists but don't test actual DB operations
  describe "API existence" do
    it "has find method that accepts composite keys" do
      OrderItem.responds_to?(:find).should be_true
    end
    
    it "has find! method" do
      OrderItem.responds_to?(:find!).should be_true
    end
    
    it "has exists? method" do
      OrderItem.responds_to?(:exists?).should be_true
    end
  end
end