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

describe "Granite::QueryAnalysis" do
  # Set up a shared test backend
  backend = TestLogBackend.new
  
  before_each do
    # Clear messages before each test
    backend.clear
    
    # Configure logging fresh for each test
    Log.setup do |c|
      c.bind "*", :trace, backend
      c.bind "granite.*", :trace, backend
      c.bind "granite.query", :trace, backend
    end
  end
  describe "N+1 Detection" do
    it "detects N+1 queries" do
      # Create test data
      Teacher.clear
      Klass.clear
      Student.clear
      Enrollment.clear
      
      teachers = [] of Teacher
      3.times do |i|
        teacher = Teacher.create(name: "Teacher #{i + 1}")
        teachers << teacher
        
        # Create klasses for each teacher
        2.times do |j|
          Klass.create(name: "Klass #{j + 1}", teacher_id: teacher.id)
        end
      end
      
      # Run N+1 detection
      analysis = Granite::QueryAnalysis::N1Detector.detect do
        # This should trigger N+1 queries
        teachers.each do |teacher|
          # Each access to klasses triggers a new query
          teacher.klasses.all
        end
      end
      
      analysis.should_not be_nil
      if analysis
        analysis.has_issues?.should be_true
      analysis.potential_n1_issues.size.should be > 0
      
      # Find the Klass select issue
      klass_issue = analysis.potential_n1_issues.find { |issue| issue.model == "Klass" && issue.operation == "select" }
      klass_issue.should_not be_nil
      
        if issue = klass_issue
          issue.query_count.should eq(3) # One query per teacher
        end
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
      
      analysis.should_not be_nil
      analysis.has_issues?.should be_false
    end
    
    it "tracks query duration in analysis" do
      Teacher.clear
      Teacher.create(name: "Test Teacher")
      
      analysis = Granite::QueryAnalysis::N1Detector.detect do
        Teacher.all
        Teacher.first
      end
      
      analysis.should_not be_nil
      analysis.total_duration_ms.should be > 0
      analysis.total_queries.should eq(2)
    end
    
    it "provides useful analysis output" do
      Teacher.clear
      Klass.clear
      
      teacher = Teacher.create(name: "Test Teacher")
      Klass.create(name: "Klass 1", teacher_id: teacher.id)
      Klass.create(name: "Klass 2", teacher_id: teacher.id)
      
      analysis = Granite::QueryAnalysis::N1Detector.detect do
        teachers = Teacher.all
        teachers.each do |t|
          t.klasses.all
        end
      end
      
      analysis.should_not be_nil
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
      stats.disable!
      stats.clear
      
      # Record some stats manually for testing
      stats.enable!
      stats.record("Teacher", "select", 5.2)
      stats.record("Teacher", "select", 3.8)
      stats.record("Teacher", "insert", 2.5)
      
      # Manually access stats through reflection since @stats is private
      # Check stats were recorded - the query should have stats
      # Since we can't access @stats directly, let's test through report output
      
      stats.report
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      # Verify the stats were recorded correctly
      messages.should contain("Query Stats - Teacher#select: 2 queries")
      messages.should contain("avg: 4.5ms")
      messages.should contain("min: 3.8ms")
      messages.should contain("max: 5.2ms")
      
      stats.disable!
    end
    
    it "generates statistics report" do
      stats = Granite::QueryAnalysis::QueryStats.instance
      stats.enable!
      stats.clear
      
      # Record some stats
      stats.record("User", "select", 10.5)
      stats.record("User", "insert", 5.2)
      stats.record("User", "select", 8.3)
      
      stats.report
      
      sleep 100.milliseconds
      messages = backend.messages.join("\n")
      
      messages.should contain("Query Statistics Summary")
      messages.should contain("User")
      messages.should contain("select")
      
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