require "../../spec_helper"

describe "Granite::EagerLoading" do
  describe "#includes" do
    it "returns a query builder with includes" do
      query = Parent.includes(:children)
      query.should be_a(Granite::Query::Builder(Parent))
      query.includes_associations.should contain(:children)
    end
    
    it "supports multiple associations" do
      query = Parent.includes(:children, :school)
      query.includes_associations.should contain(:children)
      query.includes_associations.should contain(:school)
    end
    
    it "supports nested associations" do
      query = Parent.includes(children: :school)
      query.includes_associations.size.should eq(1)
      nested = query.includes_associations.first
      nested.should be_a(Hash(Symbol, Array(Symbol)))
    end
  end
  
  describe "#preload" do
    it "returns a query builder with preload" do
      query = Parent.preload(:children)
      query.should be_a(Granite::Query::Builder(Parent))
      query.preload_associations.should contain(:children)
    end
  end
  
  describe "#eager_load" do
    it "returns a query builder with eager_load" do
      query = Parent.eager_load(:children)
      query.should be_a(Granite::Query::Builder(Parent))
      query.eager_load_associations.should contain(:children)
    end
  end
  
  describe "association loading" do
    it "loads belongs_to associations" do
      student = Student.new(name: "Test Student")
      student.save
      
      school = School.new(name: "Test School")
      school.save
      
      student.school_id = school.id
      student.save
      
      # Load with includes
      loaded_student = Student.includes(:school).find!(student.id)
      loaded_student.association_loaded?(:school).should be_true
    end
    
    it "loads has_many associations" do
      school = School.new(name: "Test School")
      school.save
      
      student1 = Student.new(name: "Student 1", school_id: school.id)
      student1.save
      
      student2 = Student.new(name: "Student 2", school_id: school.id)
      student2.save
      
      # Load with includes
      loaded_school = School.includes(:students).find!(school.id)
      loaded_school.association_loaded?(:students).should be_true
    end
    
    it "prevents N+1 queries" do
      # This is a placeholder test - would need query counting in real implementation
      schools = School.includes(:students).all
      
      # Accessing students should not trigger additional queries
      schools.each do |school|
        school.students.size # Should use loaded data
      end
    end
  end
end