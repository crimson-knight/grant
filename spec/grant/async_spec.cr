require "../spec_helper"

describe "Async features" do
  describe "AsyncResult" do
    it "executes async operations" do
      result = Grant::Async::Result.new { 42 }
      result.wait.should eq(42)
    end
    
    it "handles errors" do
      result = Grant::Async::Result.new { raise "test error" }
      expect_raises(Exception, "test error") do
        result.wait
      end
    end
    
    it "supports error recovery" do
      result = Grant::Async::Result(Int32).new { raise "test error" }
      recovered = result.on_error { |e| -1 }
      recovered.should eq(-1)
    end
    
    it "supports chaining with then" do
      result = Grant::Async::Result.new { 10 }
      chained = result.then { |v| v * 2 }
      chained.wait.should eq(20)
    end
    
    it "supports timeout" do
      result = Grant::Async::Result.new do
        sleep 0.1.seconds
        42
      end
      
      expect_raises(Grant::Async::AsyncTimeoutError) do
        result.wait_with_timeout(0.05.seconds)
      end
    end
  end
  
  describe "AsyncCoordinator" do
    it "waits for multiple operations" do
      coordinator = Grant::Async::ResultCoordinator(Int32).new
      
      3.times do |i|
        result = Grant::Async::Result.new { i * 10 }
        coordinator.add(result)
      end
      
      values = coordinator.wait_all
      values.values.sort.should eq([0, 10, 20])
    end
    
    it "reports errors from failed operations" do
      coordinator = Grant::Async::Coordinator.new
      
      coordinator.add(Grant::Async::Result(Int32).new { 1 })
      coordinator.add(Grant::Async::Result(Int32).new { raise "error 1" })
      coordinator.add(Grant::Async::Result(Int32).new { raise "error 2" })
      
      expect_raises(Grant::Async::AsyncCoordinationError) do
        coordinator.wait_all
      end
    end
  end
  
  describe "Model async methods" do
    it "performs async count" do
      Parent.clear
      Parent.create(name: "Parent 1")
      Parent.create(name: "Parent 2")
      
      result = Parent.async_count
      result.should be_a(Grant::Async::Result(Int64))
      result.wait.should eq(2)
    end
    
    it "performs async find" do
      Parent.clear
      parent = Parent.create(name: "Test Parent")
      
      result = Parent.async_find(parent.id)
      found = result.wait
      found.should_not be_nil
      found.not_nil!.name.should eq("Test Parent")
    end
    
    it "performs async find_by" do
      Parent.clear
      Parent.create(name: "Unique Name")
      
      result = Parent.async_find_by(name: "Unique Name")
      found = result.wait
      found.should_not be_nil
      found.not_nil!.name.should eq("Unique Name")
    end
    
    it "performs async all" do
      Parent.clear
      Parent.create(name: "Parent 1")
      Parent.create(name: "Parent 2")
      
      result = Parent.async_all
      parents = result.wait
      parents.size.should eq(2)
      parents.map(&.name).compact.sort.should eq(["Parent 1", "Parent 2"])
    end
    
    it "performs async aggregations" do
      Enrollment.clear
      e1 = Enrollment.create(student_id: 1, klass_id: 1)
      e2 = Enrollment.create(student_id: 2, klass_id: 1)
      e3 = Enrollment.create(student_id: 3, klass_id: 1)
      
      count_result = Enrollment.async_count
      count_result.wait.should eq(3)
      
      min_result = Enrollment.async_min(:id)
      min_result.wait.should eq(e1.id)
      
      max_result = Enrollment.async_max(:id)
      max_result.wait.should eq(e3.id)
    end
    
    it "performs parallel execution" do
      Parent.clear
      Student.clear
      
      Parent.create(name: "Parent 1")
      3.times { |i| Student.create(name: "Student #{i}") }
      
      # Track results manually for this test
      parent_count_result = Parent.async_count
      student_count_result = Student.async_count
      
      coordinator = Grant::Async::Coordinator.new
      coordinator.add(parent_count_result)
      coordinator.add(student_count_result)
      
      coordinator.wait_all
      
      parent_count_result.wait.should eq(1_i64)  # 1 parent
      student_count_result.wait.should eq(3_i64) # 3 students
    end
  end
  
  describe "Query builder async methods" do
    it "performs async count with conditions" do
      Student.clear
      Student.create(name: "Active")
      Student.create(name: "Inactive")
      
      result = Student.where(name: "Active").async_count
      result.wait.should eq(1)
    end
    
    it "performs async select with conditions" do
      Parent.clear
      Parent.create(name: "Alpha")
      Parent.create(name: "Beta")
      Parent.create(name: "Alpha")
      
      result = Parent.where(name: "Alpha").async_select
      parents = result.wait
      parents.size.should eq(2)
      parents.all? { |p| p.name == "Alpha" }.should be_true
    end
    
    it "performs async aggregations with conditions" do
      Enrollment.clear
      Enrollment.create(student_id: 1, klass_id: 1)
      Enrollment.create(student_id: 2, klass_id: 1)
      Enrollment.create(student_id: 3, klass_id: 2)
      
      result = Enrollment.where(klass_id: 1).async_count
      result.wait.should eq(2)
    end
    
    it "performs async delete" do
      Parent.clear
      Parent.create(name: "To Delete")
      Parent.create(name: "To Keep")
      
      result = Parent.where(name: "To Delete").async_delete
      deleted_result = result.wait
      deleted_result.rows_affected.should eq(1)
      
      Parent.count.should eq(1)
      Parent.first!.name.should eq("To Keep")
    end
    
    it "performs async update" do
      Parent.clear
      Parent.create(name: "Old Name 1")
      Parent.create(name: "Old Name 2")
      
      result = Parent.where(name: "Old Name 1").async_update_all("name = 'New Name'")
      updated_result = result.wait
      updated_result.rows_affected.should eq(1)
      
      Parent.find_by(name: "New Name").should_not be_nil
      Parent.find_by(name: "Old Name 1").should be_nil
    end
  end
  
  describe "Async metrics" do
    it "tracks operation metrics" do
      Grant::Async::Metrics.reset
      
      Parent.async_count.wait
      Student.async_count.wait
      
      metrics = Grant::Async::Metrics.snapshot
      metrics[:total].should eq(2)
      metrics[:failed].should eq(0)
      metrics[:success_rate].should be > 0
    end
  end
end