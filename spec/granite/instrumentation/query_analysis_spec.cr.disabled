require "../../spec_helper"

describe "Granite::QueryAnalysis" do
  describe "N+1 Detection" do
    it "detects N+1 queries" do
      # Create test data
      School.clear
      Student.clear
      
      schools = [] of School
      3.times do |i|
        school = School.create(name: "School #{i + 1}")
        schools << school
        
        # Create students for each school
        2.times do |j|
          Student.create(name: "Student #{j + 1}", school_id: school.id)
        end
      end
      
      # Run N+1 detection
      analysis = Granite::QueryAnalysis::N1Detector.detect do
        # This should trigger N+1 queries
        schools.each do |school|
          # Each access to students triggers a new query
          school.students.all
        end
      end
      
      analysis.has_issues?.should be_true
      analysis.potential_n1_issues.size.should be > 0
      
      # Find the Student select issue
      student_issue = analysis.potential_n1_issues.find { |issue| issue.model == "Student" && issue.operation == "select" }
      student_issue.should_not be_nil
      
      if issue = student_issue
        issue.query_count.should eq(3) # One query per school
      end
    end
    
    it "doesn't flag non-N+1 queries" do
      Teacher.clear
      
      # Create test data
      3.times do |i|
        Teacher.create(name: "Teacher #{i + 1}")
      end
      
      analysis = Granite::QueryAnalysis::N1Detector.detect do
        # This is a single query, not N+1
        teachers = Teacher.all
        teachers.size.should eq(3)
      end
      
      analysis.has_issues?.should be_false
    end
    
    it "tracks query duration in analysis" do
      Teacher.clear
      Teacher.create(name: "Test Teacher")
      
      analysis = Granite::QueryAnalysis::N1Detector.detect do
        Teacher.all
        Teacher.first
      end
      
      analysis.total_duration_ms.should be > 0
      analysis.total_queries.should eq(2)
    end
    
    it "provides useful analysis output" do
      School.clear
      Student.clear
      
      school = School.create(name: "Test School")
      Student.create(name: "Student 1", school_id: school.id)
      Student.create(name: "Student 2", school_id: school.id)
      
      analysis = Granite::QueryAnalysis::N1Detector.detect do
        schools = School.all
        schools.each do |s|
          s.students.all
        end
      end
      
      output = analysis.to_s
      output.should contain("Query Analysis:")
      output.should contain("Total queries:")
      
      if analysis.has_issues?
        output.should contain("Potential N+1 issues found:")
      end
    end
    
    it "clears data after analysis" do
      detector = Granite::QueryAnalysis::N1Detector.instance
      
      detector.enable!
      Teacher.all
      detector.disable!
      
      # Clear should remove all recorded queries
      detector.clear
      analysis = detector.analyze
      
      analysis.total_queries.should eq(0)
    end
  end
  
  describe "Query Statistics" do
    it "collects query statistics" do
      stats = Granite::QueryAnalysis::QueryStats.instance
      stats.enable!
      stats.clear
      
      Teacher.clear
      
      # Execute various queries
      Teacher.create(name: "Teacher 1")
      Teacher.create(name: "Teacher 2")
      Teacher.all
      Teacher.first
      
      # Record some stats manually for testing
      stats.record("Teacher", "select", 5.2)
      stats.record("Teacher", "select", 3.8)
      stats.record("Teacher", "insert", 2.5)
      
      # Check stats were recorded
      stats.@stats.size.should be > 0
      
      # Test stat aggregation
      select_stat = stats.@stats["Teacher#select"]?
      select_stat.should_not be_nil
      
      if stat = select_stat
        stat.count.should eq(2)
        stat.avg_duration_ms.should eq(4.5)
        stat.min_duration_ms.should eq(3.8)
        stat.max_duration_ms.should eq(5.2)
      end
      
      stats.disable!
    end
    
    it "generates statistics report" do
      io = IO::Memory.new
      backend = Log::IOBackend.new(io)
      Log.builder.bind "granite.query", :info, backend
      
      stats = Granite::QueryAnalysis::QueryStats.instance
      stats.enable!
      stats.clear
      
      # Record some stats
      stats.record("User", "select", 10.5)
      stats.record("User", "insert", 5.2)
      stats.record("User", "select", 8.3)
      
      stats.report
      
      io.rewind
      log_output = io.gets_to_end
      
      log_output.should contain("Query Statistics Summary")
      log_output.should contain("User")
      log_output.should contain("select")
      
      stats.disable!
    end
  end
  
  describe "Integration with query execution" do
    it "automatically records queries when enabled" do
      detector = Granite::QueryAnalysis::N1Detector.instance
      detector.enable!
      detector.clear
      
      Teacher.clear
      Teacher.create(name: "Test Teacher")
      Teacher.all
      
      analysis = detector.analyze
      analysis.total_queries.should be > 0
      
      detector.disable!
    end
  end
end