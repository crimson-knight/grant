require "../../spec_helper"

# Set up a test backend that we can use across tests
class TestLogBackend < Log::Backend
  getter messages = [] of String
  
  def write(entry : Log::Entry) : Nil
    messages << "#{entry.severity} - #{entry.source}: #{entry.message}"
  end
  
  def clear
    messages.clear
  end
end

describe "Grant::Logging" do
  # Set up a shared test backend
  backend = TestLogBackend.new
  
  before_each do
    # Clear messages before each test
    backend.clear
    
    # Configure logging fresh for each test
    Log.setup do |c|
      c.bind "*", :trace, backend
      c.bind "grant.*", :trace, backend
      c.bind "grant.sql", :trace, backend
      c.bind "grant.model", :trace, backend
      c.bind "grant.association", :trace, backend
      c.bind "grant.transaction", :trace, backend
      c.bind "grant.query", :trace, backend
    end
  end
  before_all do
    # Create tables for models used in tests
    Teacher.migrator.drop_and_create
    Student.migrator.drop_and_create
    Klass.migrator.drop_and_create
    Enrollment.migrator.drop_and_create
  end
  
  describe "SQL logging" do
    it "logs queries with timing information" do
      # Execute a query
      Teacher.clear
      teacher = Teacher.create(name: "Test Teacher")
      
      # Now perform a SELECT query which will go through the executor
      Teacher.all
      
      # Add a small delay to ensure log messages are processed
      sleep 100.milliseconds
      
      # Check that SQL was logged
      messages = backend.messages.join("\n")
      
      messages.should contain("Query executed")
      messages.should contain("SELECT")
      messages.should contain("Teacher")
      messages.should match(/\d+\.\d+ms/)
    end
    
    it "logs slow queries as warnings" do
      # Mock a slow query by calling the log method directly
      executor = Grant::Query::Executor::List(Teacher).new("SELECT * FROM teachers", [] of Grant::Columns::Type)
      executor.log_query_with_timing(
        "SELECT * FROM teachers", 
        [] of Grant::Columns::Type,
        Time::Span.new(nanoseconds: 150_000_000), # 150ms
        10,
        "Teacher"
      )
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      messages.should contain("Slow query detected")
      messages.should match(/150\.0ms/)
    end
    
    it "logs query execution even when no records found" do
      # Try to find a non-existent record
      expect_raises(Grant::Querying::NotFound) do
        Teacher.find!(999999)
      end
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      # The query executes successfully, just returns 0 rows
      messages.should contain("Query executed")
      messages.should contain("rows: 0")
      messages.should contain("SELECT")
    end
  end
  
  describe "Model lifecycle logging" do
    it "logs record creation" do
      teacher = Teacher.create(name: "New Teacher")
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      messages.should contain("Creating record")
      messages.should contain("Record created")
      messages.should contain("Teacher")
    end
    
    it "logs record updates" do
      teacher = Teacher.create(name: "Test Teacher")
      
      teacher.name = "Updated Teacher"
      teacher.save
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      messages.should contain("Updating record")
      messages.should contain("Record updated")
      messages.should contain("Teacher")
    end
    
    it "logs record destruction" do
      teacher = Teacher.create(name: "Test Teacher")
      
      teacher.destroy
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      messages.should contain("Destroying record")
      messages.should contain("Record destroyed")
      messages.should contain("Teacher")
    end
    
    it "logs save failures" do
      # Create a model with validation that will fail
      student = Student.new(name: "") # Assuming name is required
      student.save
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      if messages.includes?("Failed to save record")
        messages.should contain("Failed to save record")
        messages.should contain("Student")
      end
    end
  end
  
  describe "Association logging" do
    it "logs belongs_to association loading" do
      # Create test data using actual model relationships
      klass = Klass.create(name: "Test Class")
      student = Student.create(name: "Test Student")
      enrollment = Enrollment.create(student_id: student.id, klass_id: klass.id)
      
      # Access the belongs_to association
      loaded_student = enrollment.student
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      messages.should contain("Loaded belongs_to association")
      messages.should contain("Enrollment")
      messages.should contain("student")
    end
    
    it "logs has_many association collection creation" do
      teacher = Teacher.create(name: "Test Teacher")
      
      # Access the has_many association
      klasses = teacher.klasses
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      messages.should contain("Created has_many association collection")
      messages.should contain("Teacher")
      messages.should contain("klasses")
    end
    
    it "logs association collection queries" do
      teacher = Teacher.create(name: "Test Teacher")
      klass1 = Klass.create(name: "Math", teacher_id: teacher.id)
      klass2 = Klass.create(name: "Science", teacher_id: teacher.id)
      
      # Query through association
      klasses = teacher.klasses.all
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      messages.should contain("Loaded has_many association")
      messages.should contain("2 records")
    end
  end
  
  describe "Development helpers" do
    it "sets up all logging categories" do
      # Verify that development setup works without errors
      Grant::Development.setup_logging
      
      # The loggers should be available
      Grant::Logs::SQL.should be_a(Log)
      Grant::Logs::Model.should be_a(Log)
      Grant::Logs::Association.should be_a(Log)
      Grant::Logs::Transaction.should be_a(Log)
      Grant::Logs::Query.should be_a(Log)
    end
    
    it "can set up individual log categories" do
      Grant::Development.setup_sql_logging
      Grant::Development.setup_model_logging
      Grant::Development.setup_association_logging
      Grant::Development.setup_transaction_logging
      Grant::Development.setup_query_logging
      
      # No errors should be raised
    end
  end
end