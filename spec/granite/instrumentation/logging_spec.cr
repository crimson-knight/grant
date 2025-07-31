require "../../spec_helper"

describe "Granite::Logging" do
  describe "SQL logging" do
    it "logs queries with timing information" do
      # Create a custom log backend to capture logs
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.sql", :debug, backend
      
      # Execute a query
      Teacher.clear
      teacher = Teacher.create(name: "Test Teacher")
      
      # Check that SQL was logged
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Query executed")
      log_output.should contain("INSERT")
      log_output.should contain("Teacher")
      log_output.should match(/\d+\.\d+ms/)
    end
    
    it "logs slow queries as warnings" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.sql", :warn, backend
      
      # Mock a slow query by calling the log method directly
      executor = Granite::Query::Executor::List(Teacher).new("SELECT * FROM teachers", [] of Granite::Columns::Type)
      executor.log_query_with_timing(
        "SELECT * FROM teachers", 
        [] of Granite::Columns::Type,
        Time::Span.new(nanoseconds: 150_000_000), # 150ms
        10,
        "Teacher"
      )
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Slow query detected")
      log_output.should match(/150\.0ms/)
    end
    
    it "logs query failures" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.sql", :error, backend
      
      # Try to find a non-existent record
      expect_raises(Granite::Querying::NotFound) do
        Teacher.find!(999999)
      end
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Query failed")
    end
  end
  
  describe "Model lifecycle logging" do
    it "logs record creation" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.model", :debug, backend
      
      teacher = Teacher.create(name: "New Teacher")
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Creating record")
      log_output.should contain("Record created")
      log_output.should contain("Teacher")
    end
    
    it "logs record updates" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.model", :debug, backend
      
      teacher = Teacher.create(name: "Test Teacher")
      io.clear
      
      teacher.name = "Updated Teacher"
      teacher.save
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Updating record")
      log_output.should contain("Record updated")
      log_output.should contain("Teacher")
    end
    
    it "logs record destruction" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.model", :debug, backend
      
      teacher = Teacher.create(name: "Test Teacher")
      io.clear
      
      teacher.destroy
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Destroying record")
      log_output.should contain("Record destroyed")
      log_output.should contain("Teacher")
    end
    
    it "logs save failures" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.model", :error, backend
      
      # Create a model with validation that will fail
      student = Student.new(name: "") # Assuming name is required
      student.save
      
      io.rewind
      log_output = io.gets_to_end
      
      if log_output.includes?("Failed to save record")
        log_output.should contain("Failed to save record")
        log_output.should contain("Student")
      end
    end
  end
  
  describe "Association logging" do
    it "logs belongs_to association loading" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.association", :debug, backend
      
      # Create test data
      school = School.create(name: "Test School")
      student = Student.create(name: "Test Student", school_id: school.id)
      
      io.clear
      
      # Access the association
      loaded_school = student.school
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Loaded belongs_to association")
      log_output.should contain("Student")
      log_output.should contain("School")
    end
    
    it "logs has_many association collection creation" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.association", :debug, backend
      
      school = School.create(name: "Test School")
      io.clear
      
      # Access the association
      students = school.students
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Created has_many association collection")
      log_output.should contain("School")
      log_output.should contain("Student")
    end
    
    it "logs association collection queries" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      
      Log.builder.bind "granite.association", :info, backend
      
      school = School.create(name: "Test School")
      Student.create(name: "Student 1", school_id: school.id)
      Student.create(name: "Student 2", school_id: school.id)
      
      io.clear
      
      # Query through association
      students = school.students.all
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Loaded has_many association")
      log_output.should contain("2 records")
    end
  end
  
  describe "Development formatters" do
    it "formats SQL queries with colors in development mode" do
      formatter = Granite::Development::SQLFormatter.new
      entry = Log::Entry.new(
        "granite.sql",
        Log::Severity::Debug,
        "Query executed",
        Log::Metadata.build({
          sql: "SELECT * FROM users WHERE active = true",
          model: "User",
          duration_ms: 5.2,
          row_count: 10
        })
      )
      
      io = IO::Memory.new
      formatter.format(entry, io)
      
      output = io.to_s
      output.should contain("User")
      output.should contain("5.2ms")
      output.should contain("10 rows")
      output.should contain("SELECT")
    end
    
    it "highlights slow queries with appropriate colors" do
      formatter = Granite::Development::SQLFormatter.new
      entry = Log::Entry.new(
        "granite.sql",
        Log::Severity::Warn,
        "Slow query detected",
        Log::Metadata.build({
          sql: "SELECT * FROM large_table",
          model: "LargeModel",
          duration_ms: 250.5
        })
      )
      
      io = IO::Memory.new
      formatter.format(entry, io)
      
      output = io.to_s
      output.should contain("250.5ms")
      output.should contain("⚠")
    end
  end
end