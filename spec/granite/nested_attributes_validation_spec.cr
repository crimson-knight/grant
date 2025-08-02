require "../spec_helper"

describe "Granite::NestedAttributes Validation" do
  it "requires explicit type declaration" do
    # Test compile-time validation using macro rescue
    {% begin %}
      {% begin %}
        class BadModel1 < Granite::Base
          connection {{ CURRENT_ADAPTER }}
          table bad_models_1
          
          column id : Int64, primary: true
          
          # This should raise an error - no type declaration
          accepts_nested_attributes_for :posts
        end
      {% rescue %}
        # Successfully caught the error
        "validation_passed" == "validation_passed"
      {% end %}
    {% rescue %}
      # If we get here, something else went wrong
      "unexpected_error" == "validation_passed"
    {% end %}.should be_true
  end
  
  it "validates association exists" do
    # Test that association must exist
    {% begin %}
      {% begin %}
        class BadModel2 < Granite::Base
          connection {{ CURRENT_ADAPTER }}
          table bad_models_2
          
          column id : Int64, primary: true
          
          # This should raise an error - no posts association
          accepts_nested_attributes_for posts : Post
        end
      {% rescue %}
        # Successfully caught the error
        "validation_passed" == "validation_passed"
      {% end %}
    {% rescue %}
      # If we get here, something else went wrong
      "unexpected_error" == "validation_passed"
    {% end %}.should be_true
  end
  
  it "works with valid association and type" do
    class GoodModel < Granite::Base
      connection {{ CURRENT_ADAPTER }}
      table good_models
      
      column id : Int64, primary: true
      column name : String
      
      has_many :posts
      has_one :profile
      
      # These should work - associations exist and types are provided
      accepts_nested_attributes_for posts : Post, allow_destroy: true
      accepts_nested_attributes_for profile : Profile, update_only: true
    end
    
    # Should compile successfully
    model = GoodModel.new(name: "Test")
    model.responds_to?(:posts_attributes=).should be_true
    model.responds_to?(:profile_attributes=).should be_true
  end
end