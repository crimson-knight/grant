require "../spec_helper"

describe Grant::Transaction do
  describe ".transaction" do
    it "executes a basic transaction" do
      Parent.clear
      
      Parent.transaction do
        parent = Parent.create!(name: "Test Parent")
        parent.persisted?.should be_true
      end
      
      Parent.count.should eq(1)
    end
    
    it "rolls back on exception" do
      Parent.clear
      
      expect_raises(Exception, "Test error") do
        Parent.transaction do
          Parent.create!(name: "Should be rolled back")
          raise "Test error"
        end
      end
      
      Parent.count.should eq(0)
    end
    
    it "rolls back on Grant::Transaction::Rollback" do
      Parent.clear
      
      Parent.transaction do
        Parent.create!(name: "Should be rolled back")
        raise Grant::Transaction::Rollback.new
      end
      
      Parent.count.should eq(0)
    end
    
    it "supports nested transactions with savepoints" do
      Parent.clear
      
      Parent.transaction do
        parent1 = Parent.create!(name: "Parent 1")
        
        Parent.transaction do
          parent2 = Parent.create!(name: "Parent 2")
          raise Grant::Transaction::Rollback.new
        end
        
        Parent.count.should eq(1)
      end
      
      Parent.count.should eq(1)
      Parent.first!.name.should eq("Parent 1")
    end
    
    it "supports requires_new option" do
      Parent.clear
      
      expect_raises(Exception, "Outer transaction error") do
        Parent.transaction do
          Parent.create!(name: "Outer")
          
          Parent.transaction(requires_new: true) do
            Parent.create!(name: "Inner")
          end
          
          raise "Outer transaction error"
        end
      end
      
      # Inner transaction should have committed independently
      Parent.count.should eq(1)
      Parent.first!.name.should eq("Inner")
    end
    
    it "detects if transaction is open" do
      Parent.transaction_open?.should be_false
      
      Parent.transaction do
        Parent.transaction_open?.should be_true
      end
      
      Parent.transaction_open?.should be_false
    end
  end
  
  describe "isolation levels" do
    # Note: Actual isolation behavior depends on database support
    # These tests verify the API works
    
    {% for level in %w[read_uncommitted read_committed repeatable_read serializable] %}
      it "accepts {{level.id}} isolation level" do
        Parent.transaction(isolation: :{{level.id}}) do
          Parent.create!(name: "Test with {{level.id}}")
        end
      end
    {% end %}
  end
  
  describe "readonly transactions" do
    it "accepts readonly option" do
      Parent.clear
      Parent.create!(name: "Existing")
      
      Parent.transaction(readonly: true) do
        Parent.count.should eq(1)
      end
    end
  end
end