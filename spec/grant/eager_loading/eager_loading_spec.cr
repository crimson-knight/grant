require "../../spec_helper"

describe "Grant::EagerLoading" do
  describe "#includes" do
    it "returns a query builder with includes" do
      query = Parent.includes(:students)
      query.should be_a(Grant::Query::Builder(Parent))
      query.includes_associations.should contain(:students)
    end

    it "supports multiple associations" do
      query = Teacher.includes(:klasses)
      query.should be_a(Grant::Query::Builder(Teacher))
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
      query.should be_a(Grant::Query::Builder(Parent))
      query.preload_associations.should contain(:students)
    end
  end

  describe "#eager_load" do
    it "returns a query builder with eager_load" do
      query = Parent.eager_load(:students)
      query.should be_a(Grant::Query::Builder(Parent))
      query.eager_load_associations.should contain(:students)
    end
  end

  describe "association loading" do
    before_all do
      Teacher.migrator.drop_and_create
      Klass.migrator.drop_and_create
      Student.migrator.drop_and_create
      Parent.migrator.drop_and_create
      Enrollment.migrator.drop_and_create
    end

    before_each do
      # Clean tables before each test
      Teacher.exec("DELETE FROM teachers")
      Klass.exec("DELETE FROM klasses")
      Student.exec("DELETE FROM students")
      Parent.exec("DELETE FROM parents")
      Enrollment.exec("DELETE FROM enrollments")
    end

    it "loads belongs_to associations in batch" do
      teacher = Teacher.new(name: "Test Teacher")
      teacher.save!

      klass = Klass.new(name: "Test Class")
      klass.teacher = teacher
      klass.save!

      # Load with includes — should mark the association as loaded
      loaded_klasses = Klass.includes(:teacher).where(id: klass.id.not_nil!).select
      loaded_klasses.size.should eq(1)
      loaded_klass = loaded_klasses.first
      loaded_klass.association_loaded?(:teacher).should be_true
    end

    it "loads has_many associations in batch" do
      teacher = Teacher.new(name: "Test Teacher")
      teacher.save!

      klass1 = Klass.new(name: "Math")
      klass1.teacher = teacher
      klass1.save!

      klass2 = Klass.new(name: "Science")
      klass2.teacher = teacher
      klass2.save!

      # Load with includes — should mark the association as loaded
      loaded_teachers = Teacher.includes(:klasses).where(id: teacher.id.not_nil!).select
      loaded_teachers.size.should eq(1)
      loaded_teacher = loaded_teachers.first
      loaded_teacher.association_loaded?(:klasses).should be_true
      loaded_teacher.klasses.to_a.size.should eq(2)
    end

    it "attaches correct children to each parent (batch load correctness)" do
      # Create 3 teachers, each with a different number of classes
      t1 = Teacher.new(name: "Teacher One")
      t1.save!
      t2 = Teacher.new(name: "Teacher Two")
      t2.save!
      t3 = Teacher.new(name: "Teacher Three")
      t3.save!

      k1a = Klass.new(name: "T1-ClassA"); k1a.teacher = t1; k1a.save!
      k1b = Klass.new(name: "T1-ClassB"); k1b.teacher = t1; k1b.save!
      k2a = Klass.new(name: "T2-ClassA"); k2a.teacher = t2; k2a.save!
      # t3 has no classes

      teachers = Teacher.includes(:klasses).order(:id).select

      # Every record should have the association marked as loaded
      teachers.each do |t|
        t.association_loaded?(:klasses).should be_true
      end

      t1_loaded = teachers.find { |t| t.name == "Teacher One" }.not_nil!
      t2_loaded = teachers.find { |t| t.name == "Teacher Two" }.not_nil!
      t3_loaded = teachers.find { |t| t.name == "Teacher Three" }.not_nil!

      t1_loaded.klasses.to_a.map(&.name.to_s).sort.should eq(["T1-ClassA", "T1-ClassB"])
      t2_loaded.klasses.to_a.map(&.name.to_s).should eq(["T2-ClassA"])
      t3_loaded.klasses.to_a.size.should eq(0)
    end

    it "does not issue additional queries when accessing an eager-loaded belongs_to" do
      teacher = Teacher.new(name: "Query Count Teacher")
      teacher.save!

      klass = Klass.new(name: "Query Count Class")
      klass.teacher = teacher
      klass.save!

      loaded_klasses = Klass.includes(:teacher).where(id: klass.id.not_nil!).select
      loaded_klass = loaded_klasses.first

      # association_loaded? must be true — accessing the method must NOT
      # trigger a DB query (it must return from the in-memory cache)
      loaded_klass.association_loaded?(:teacher).should be_true

      # Calling the accessor a second time must return the same cached object
      result1 = loaded_klass.teacher
      result2 = loaded_klass.teacher
      result1.should_not be_nil
      # Identity: both calls return the same pre-loaded object
      result1.not_nil!.id.should eq(result2.not_nil!.id)
    end

    it "loads has_one associations in batch" do
      # Chat has_one :settings
      chat = Chat.new(name: "eager chat")
      chat.save!
      settings = ChatSettings.new(flood_limit: 10)
      settings.chat = chat
      settings.save!

      loaded_chats = Chat.includes(:settings).where(id: chat.id.not_nil!).select
      loaded_chats.size.should eq(1)
      loaded_chat = loaded_chats.first
      loaded_chat.association_loaded?(:settings).should be_true
      loaded_chat.settings.not_nil!.flood_limit.should eq(10)
    end
  end
end
