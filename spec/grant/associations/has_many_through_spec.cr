require "../../spec_helper"

describe "has_many, through:" do
  before_all do
    ThroughStudent.migrator.drop_and_create
    ThroughKlass.migrator.drop_and_create
    ThroughEnrollment.migrator.drop_and_create
  end

  before_each do
    ThroughEnrollment.clear
    ThroughKlass.clear
    ThroughStudent.clear
  end

  it "provides a method to retrieve associated objects through another table" do
    student = ThroughStudent.new
    student.name = "test student"
    student.save.should be_true

    unrelated_student = ThroughStudent.new
    unrelated_student.name = "other student"
    unrelated_student.save.should be_true

    klass1 = ThroughKlass.new
    klass1.name = "Test class"
    klass1.save.should be_true

    klass2 = ThroughKlass.new
    klass2.name = "Test class"
    klass2.save.should be_true

    klass3 = ThroughKlass.new
    klass3.name = "Test class"
    klass3.save.should be_true

    enrollment1 = ThroughEnrollment.new
    enrollment1.through_student_id = student.id
    enrollment1.through_klass_id = klass1.id
    enrollment1.save.should be_true

    enrollment2 = ThroughEnrollment.new
    enrollment2.through_student_id = student.id
    enrollment2.through_klass_id = klass2.id
    enrollment2.save.should be_true

    enrollment3 = ThroughEnrollment.new
    enrollment3.through_klass_id = klass2.id
    enrollment3.through_student_id = unrelated_student.id
    enrollment3.save.should be_true

    student.through_klasses.compact_map(&.id).sort!.should eq [klass1.id, klass2.id].compact.sort!

    klass2.through_students.compact_map(&.id).sort!.should eq [student.id, unrelated_student.id].compact.sort!
  end

  context "querying association" do
    it "#all" do
      student = ThroughStudent.new
      student.name = "test student"
      student.save.should be_true

      klass1 = ThroughKlass.new
      klass1.name = "Test class X"
      klass1.save.should be_true

      klass2 = ThroughKlass.new
      klass2.name = "Test class X"
      klass2.save.should be_true

      klass3 = ThroughKlass.new
      klass3.name = "Test class with different name"
      klass3.save.should be_true

      enrollment1 = ThroughEnrollment.new
      enrollment1.through_student_id = student.id
      enrollment1.through_klass_id = klass1.id
      enrollment1.save.should be_true

      enrollment2 = ThroughEnrollment.new
      enrollment2.through_student_id = student.id
      enrollment2.through_klass_id = klass2.id
      enrollment2.save.should be_true

      enrollment3 = ThroughEnrollment.new
      enrollment3.through_klass_id = klass3.id
      enrollment3.through_student_id = student.id
      enrollment3.save.should be_true

      klasses = student.through_klasses.all("AND through_klasses.name = ? ORDER BY through_klasses.id DESC", ["Test class X"])
      klasses.map(&.id).should eq [klass2.id, klass1.id]
    end

    it "#find_by" do
      student = ThroughStudent.new
      student.name = "test student"
      student.save.should be_true

      klass1 = ThroughKlass.new
      klass1.name = "Test class X"
      klass1.save.should be_true

      klass2 = ThroughKlass.new
      klass2.name = "Test class X"
      klass2.save.should be_true

      klass3 = ThroughKlass.new
      klass3.name = "Test class with different name"
      klass3.save.should be_true

      enrollment1 = ThroughEnrollment.new
      enrollment1.through_student_id = student.id
      enrollment1.through_klass_id = klass1.id
      enrollment1.save.should be_true

      enrollment2 = ThroughEnrollment.new
      enrollment2.through_student_id = student.id
      enrollment2.through_klass_id = klass2.id
      enrollment2.save.should be_true

      enrollment3 = ThroughEnrollment.new
      enrollment3.through_klass_id = klass3.id
      enrollment3.through_student_id = student.id
      enrollment3.save.should be_true

      klass = student.through_klasses.find_by(name: "Test class with different name")
      if klass
        klass.id.should eq klass3.id
        klass.name.should eq "Test class with different name"
      else
        klass.should_not be_nil
      end
    end

    it "#find_by!" do
      student = ThroughStudent.new
      student.name = "test student"
      student.save.should be_true

      klass1 = ThroughKlass.new
      klass1.name = "Test class X"
      klass1.save.should be_true

      klass2 = ThroughKlass.new
      klass2.name = "Test class X"
      klass2.save.should be_true

      klass3 = ThroughKlass.new
      klass3.name = "Test class with different name"
      klass3.save.should be_true

      enrollment1 = ThroughEnrollment.new
      enrollment1.through_student_id = student.id
      enrollment1.through_klass_id = klass1.id
      enrollment1.save.should be_true

      enrollment2 = ThroughEnrollment.new
      enrollment2.through_student_id = student.id
      enrollment2.through_klass_id = klass2.id
      enrollment2.save.should be_true

      enrollment3 = ThroughEnrollment.new
      enrollment3.through_klass_id = klass3.id
      enrollment3.through_student_id = student.id
      enrollment3.save.should be_true

      klass = student.through_klasses.find_by!(name: "Test class with different name")
      klass.id.should eq klass3.id
      klass.name.should eq "Test class with different name"

      expect_raises(
        Grant::Querying::NotFound,
        "No #{ThroughKlass.name} found where name = not_found"
      ) do
        klass = student.through_klasses.find_by!(name: "not_found")
      end
    end

    it "#find" do
      student = ThroughStudent.new
      student.name = "test student"
      student.save.should be_true

      klass1 = ThroughKlass.new
      klass1.name = "Test class X"
      klass1.save.should be_true

      klass2 = ThroughKlass.new
      klass2.name = "Test class X"
      klass2.save.should be_true

      klass3 = ThroughKlass.new
      klass3.name = "Test class with different name"
      klass3.save.should be_true

      enrollment1 = ThroughEnrollment.new
      enrollment1.through_student_id = student.id
      enrollment1.through_klass_id = klass1.id
      enrollment1.save.should be_true

      enrollment2 = ThroughEnrollment.new
      enrollment2.through_student_id = student.id
      enrollment2.through_klass_id = klass2.id
      enrollment2.save.should be_true

      enrollment3 = ThroughEnrollment.new
      enrollment3.through_klass_id = klass3.id
      enrollment3.through_student_id = student.id
      enrollment3.save.should be_true

      klass = student.through_klasses.find(klass1.id)
      if klass
        klass.id.should eq klass1.id
        klass.name.should eq "Test class X"
      else
        klass.should_not be_nil
      end
    end

    it "#find!" do
      student = ThroughStudent.new
      student.name = "test student"
      student.save.should be_true

      klass1 = ThroughKlass.new
      klass1.name = "Test class X"
      klass1.save.should be_true

      klass2 = ThroughKlass.new
      klass2.name = "Test class X"
      klass2.save.should be_true

      klass3 = ThroughKlass.new
      klass3.name = "Test class with different name"
      klass3.save.should be_true

      enrollment1 = ThroughEnrollment.new
      enrollment1.through_student_id = student.id
      enrollment1.through_klass_id = klass1.id
      enrollment1.save.should be_true

      enrollment2 = ThroughEnrollment.new
      enrollment2.through_student_id = student.id
      enrollment2.through_klass_id = klass2.id
      enrollment2.save.should be_true

      enrollment3 = ThroughEnrollment.new
      enrollment3.through_klass_id = klass3.id
      enrollment3.through_student_id = student.id
      enrollment3.save.should be_true

      klass = student.through_klasses.find!(klass1.id)
      klass.id.should eq klass1.id
      klass.name.should eq "Test class X"

      id = klass3.id.as(Int64) + 42

      expect_raises(
        Grant::Querying::NotFound,
        "No #{ThroughKlass.name} found where id = #{id}"
      ) do
        student.through_klasses.find!(id)
      end
    end
  end
end

# Standalone test models for has_many :through (avoids dependency on shared models
# that may have required belongs_to validations)
class ThroughStudent < Grant::Base
  connection sqlite
  table through_students

  column id : Int64, primary: true
  column name : String?

  has_many :through_enrollments, class_name: ThroughEnrollment, foreign_key: :through_student_id
  has_many :through_klasses, class_name: ThroughKlass, through: :through_enrollments, foreign_key: :through_student_id
end

class ThroughKlass < Grant::Base
  connection sqlite
  table through_klasses

  column id : Int64, primary: true
  column name : String?

  has_many :through_enrollments, class_name: ThroughEnrollment, foreign_key: :through_klass_id
  has_many :through_students, class_name: ThroughStudent, through: :through_enrollments, foreign_key: :through_klass_id
end

class ThroughEnrollment < Grant::Base
  connection sqlite
  table through_enrollments

  column id : Int64, primary: true
  column through_student_id : Int64?
  column through_klass_id : Int64?

  belongs_to :through_student, optional: true
  belongs_to :through_klass, optional: true
end
