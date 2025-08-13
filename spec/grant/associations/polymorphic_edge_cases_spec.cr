require "../../spec_helper"

# Test edge cases and advanced scenarios for polymorphic associations
describe "Grant::Associations::Polymorphic - Edge Cases" do
  describe "error handling" do
    it "handles invalid type names gracefully" do
      proxy = Grant::Polymorphic::PolymorphicProxy.new("InvalidClass", 123_i64)
      proxy.load.should be_nil
    end
    
    it "raises appropriate error with load!" do
      proxy = Grant::Polymorphic::PolymorphicProxy.new("InvalidClass", 123_i64)
      expect_raises(Grant::Querying::NotFound, /No InvalidClass found/) do
        proxy.load!
      end
    end
    
    it "handles nil proxy with load!" do
      proxy = Grant::Polymorphic::PolymorphicProxy.new(nil, nil)
      expect_raises(Grant::Querying::NotFound, /Polymorphic association not set/) do
        proxy.load!
      end
    end
  end
  
  describe "proxy behavior" do
    it "reloads associations" do
      proxy = Grant::Polymorphic::PolymorphicProxy.new("EdgePost", 999_i64)
      # Should return nil since the record doesn't exist
      proxy.reload.should be_nil
    end
    
    it "correctly identifies present associations" do
      # With both type and id
      proxy1 = Grant::Polymorphic::PolymorphicProxy.new("EdgePost", 123_i64)
      proxy1.present?.should be_true
      
      # With only type
      proxy2 = Grant::Polymorphic::PolymorphicProxy.new("EdgePost", nil)
      proxy2.present?.should be_false
      
      # With only id
      proxy3 = Grant::Polymorphic::PolymorphicProxy.new(nil, 123_i64)
      proxy3.present?.should be_false
    end
  end
  
  describe "setter edge cases" do
    it "handles setting association to nil" do
      comment = EdgeComment.new(content: "Test")
      post = EdgePost.new(id: 123_i64, title: "Test Post")
      
      # Set association
      comment.edgeable = post
      comment.edgeable_id.should eq(123_i64)
      comment.edgeable_type.should eq("EdgePost")
      
      # Clear association
      comment.edgeable = nil
      comment.edgeable_id.should be_nil
      comment.edgeable_type.should be_nil
    end
    
    it "handles setting with Int32 primary key" do
      comment = EdgeComment.new(content: "Test")
      # Create a mock object with Int32 id
      article = EdgeArticle.new(id: 42, title: "Test Article")
      
      comment.edgeable = article
      comment.edgeable_id.should eq(42_i64) # Should be converted to Int64
      comment.edgeable_type.should eq("EdgeArticle")
    end
    
    it "raises error for non-numeric primary keys" do
      comment = EdgeComment.new(content: "Test")
      invalid = EdgeInvalidPK.new(id: "abc123", name: "Invalid")
      
      expect_raises(Exception, /require numeric primary keys/) do
        comment.edgeable = invalid
      end
    end
  end
  
  describe "association metadata" do
    it "stores correct metadata for belongs_to polymorphic" do
      meta = EdgeComment._edgeable_association_meta
      meta[:type].should eq(:belongs_to)
      meta[:polymorphic].should be_true
      meta[:foreign_key].should eq("edgeable_id")
      meta[:type_column].should eq("edgeable_type")
      meta[:primary_key].should eq("id")
    end
    
    it "stores correct metadata for has_many polymorphic" do
      meta = EdgePost._edge_comments_association_meta
      meta[:type].should eq(:has_many)
      meta[:polymorphic_as].should eq("edgeable")
      meta[:target_class_name].should eq("EdgeComment")
      meta[:foreign_key].should eq("edgeable_id")
      meta[:type_column].should eq("edgeable_type")
    end
    
    it "stores correct metadata for has_one polymorphic" do
      meta = EdgePost._edge_image_association_meta
      meta[:type].should eq(:has_one)
      meta[:polymorphic_as].should eq("imageable")
      meta[:target_class_name].should eq("EdgeImage")
      meta[:foreign_key].should eq("imageable_id")
      meta[:type_column].should eq("imageable_type")
    end
  end
  
  describe "validation edge cases" do
    it "validates presence when not optional" do
      comment = EdgeStrictComment.new(content: "Test")
      comment.valid?.should be_false
      
      post = EdgePost.new(id: 123_i64, title: "Test")
      comment.strict_edgeable = post
      comment.valid?.should be_true
    end
    
    it "allows nil when optional" do
      comment = EdgeComment.new(content: "Test")
      comment.valid?.should be_true # edgeable is optional
    end
  end
  
  describe "custom column names" do
    it "uses custom foreign key and type columns" do
      item = EdgeCustomItem.new(name: "Custom")
      EdgeCustomItem.fields.includes?("owner_id").should be_true
      EdgeCustomItem.fields.includes?("owner_class").should be_true
      
      # Set owner
      post = EdgePost.new(id: 789_i64, title: "Owner")
      item.owner = post
      item.owner_id.should eq(789_i64)
      item.owner_class.should eq("EdgePost")
    end
  end
  
  describe "dependent options" do
    it "respects dependent destroy on has_many" do
      # Dependent options are implemented via callbacks
      # This is tested in integration tests with actual database operations
      meta = EdgeDestroyPost._edge_comments_association_meta
      meta[:type].should eq(:has_many)
      meta[:polymorphic_as].should eq("edgeable")
    end
    
    it "respects dependent nullify on has_many" do
      # Dependent options are implemented via callbacks
      # This is tested in integration tests with actual database operations
      meta = EdgeNullifyPost._edge_comments_association_meta
      meta[:type].should eq(:has_many)
      meta[:polymorphic_as].should eq("edgeable")
    end
  end
end

# Edge case test models
{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}
  
  # Basic polymorphic comment
  class EdgeComment < Grant::Base
    connection {{ adapter_literal }}
    table edge_comments
    
    column id : Int64, primary: true
    column content : String
    
    belongs_to :edgeable, polymorphic: true, optional: true
  end
  
  # Strict validation comment
  class EdgeStrictComment < Grant::Base
    connection {{ adapter_literal }}
    table edge_strict_comments
    
    column id : Int64, primary: true
    column content : String
    
    # Not optional - requires validation
    belongs_to :strict_edgeable, polymorphic: true
  end
  
  # Custom column names
  class EdgeCustomItem < Grant::Base
    connection {{ adapter_literal }}
    table edge_custom_items
    
    column id : Int64, primary: true
    column name : String
    
    belongs_to :owner, polymorphic: true, optional: true,
      foreign_key: :owner_id, type_column: :owner_class
  end
  
  # Models that can have comments
  class EdgePost < Grant::Base
    connection {{ adapter_literal }}
    table edge_posts
    
    column id : Int64, primary: true
    column title : String
    
    has_many :edge_comments, as: :edgeable
    has_one :edge_image, as: :imageable
  end
  
  # Model with Int32 primary key
  class EdgeArticle < Grant::Base
    connection {{ adapter_literal }}
    table edge_articles
    
    column id : Int32, primary: true
    column title : String
  end
  
  # Model with string primary key (invalid for polymorphic)
  class EdgeInvalidPK < Grant::Base
    connection {{ adapter_literal }}
    table edge_invalid_pks
    
    column id : String, primary: true
    column name : String
  end
  
  # Image model for has_one testing
  class EdgeImage < Grant::Base
    connection {{ adapter_literal }}
    table edge_images
    
    column id : Int64, primary: true
    column url : String
    
    belongs_to :imageable, polymorphic: true, optional: true
  end
  
  # Models with dependent options
  class EdgeDestroyPost < Grant::Base
    connection {{ adapter_literal }}
    table edge_destroy_posts
    
    column id : Int64, primary: true
    column title : String
    
    has_many :edge_comments, as: :edgeable, dependent: :destroy
  end
  
  class EdgeNullifyPost < Grant::Base
    connection {{ adapter_literal }}
    table edge_nullify_posts
    
    column id : Int64, primary: true
    column title : String
    
    has_many :edge_comments, as: :edgeable, dependent: :nullify
  end
{% end %}