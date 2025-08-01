require "../../spec_helper"

describe "Granite::EagerLoading" do
  describe "#includes" do
    it "returns a query builder with includes" do
      query = Parent.includes(:students)
      query.should be_a(Granite::Query::Builder(Parent))
      query.includes_associations.should contain(:students)
    end
    
    it "supports multiple associations" do
      query = Teacher.includes(:klasses)
      query.should be_a(Granite::Query::Builder(Teacher))
      query.includes_associations.should contain(:klasses)
    end
    
    it "supports nested associations" do
      query = Klass.includes(students: :enrollments)
      query.includes_associations.size.should eq(1)
      nested = query.includes_associations.first
      nested.should be_a(Hash(Symbol, Array(Symbol)))
    end
  end
  
  describe "#preload" do
    it "returns a query builder with preload" do
      query = Parent.preload(:students)
      query.should be_a(Granite::Query::Builder(Parent))
      query.preload_associations.should contain(:students)
    end
  end
  
  describe "#eager_load" do
    it "returns a query builder with eager_load" do
      query = Parent.eager_load(:students)
      query.should be_a(Granite::Query::Builder(Parent))
      query.eager_load_associations.should contain(:students)
    end
  end
  
  # TODO: Enable when AssociationLoader is fully implemented
  pending "association loading" do
    before_all do
      Teacher.migrator.drop_and_create
      Klass.migrator.drop_and_create
      Student.migrator.drop_and_create
      Parent.migrator.drop_and_create
      Enrollment.migrator.drop_and_create
    end
    
    it "loads belongs_to associations" do
      teacher = Teacher.new(name: "Test Teacher")
      teacher.save!
      
      klass = Klass.new(name: "Test Class")
      klass.teacher = teacher
      klass.save!
      
      # Load with includes
      query = Klass.includes(:teacher).where(id: klass.id.not_nil!)
      loaded_klasses = query.select
      loaded_klasses.size.should eq(1)
      loaded_klass = loaded_klasses.first
      loaded_klass.association_loaded?(:teacher).should be_true
    end
    
    it "loads has_many associations" do
      teacher = Teacher.new(name: "Test Teacher")
      teacher.save!
      
      klass1 = Klass.new(name: "Math")
      klass1.teacher = teacher
      klass1.save!
      
      klass2 = Klass.new(name: "Science")
      klass2.teacher = teacher
      klass2.save!
      
      # Load with includes
      query = Teacher.includes(:klasses).where(id: teacher.id.not_nil!)
      loaded_teachers = query.select
      loaded_teachers.size.should eq(1)
      loaded_teacher = loaded_teachers.first
      loaded_teacher.association_loaded?(:klasses).should be_true
      # Accessing the association should work without additional queries
      loaded_teacher.klasses.to_a.size.should eq(2)
    end
    
    it "prevents N+1 queries" do
      # Create test data
      teacher = Teacher.new(name: "Teacher")
      teacher.save!
      
      3.times do |i|
        klass = Klass.new(name: "Class #{i}")
        klass.teacher = teacher
        klass.save!
      end
      
      # This is a placeholder test - would need query counting in real implementation
      teachers = Teacher.includes(:klasses).select
      
      # Accessing klasses should not trigger additional queries
      teachers.each do |t|
        t.klasses.size # Should use loaded data
      end
    end
  end
end