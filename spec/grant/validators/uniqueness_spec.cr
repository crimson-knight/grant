require "../../spec_helper"

describe "Grant::Validators::BuiltIn::Uniqueness" do
  before_all do
    UniqueUser.migrator.drop_and_create
    ScopedUnique.migrator.drop_and_create
  end

  describe "validates_uniqueness_of" do
    it "passes when no duplicate exists" do
      UniqueUser.clear
      user = UniqueUser.new
      user.email = "unique@example.com"
      user.username = "uniqueuser"
      user.valid?.should be_true
    end

    it "fails when a duplicate exists" do
      UniqueUser.clear
      existing = UniqueUser.new
      existing.email = "taken@example.com"
      existing.username = "taken"
      existing.save!

      duplicate = UniqueUser.new
      duplicate.email = "taken@example.com"
      duplicate.username = "different"
      duplicate.valid?.should be_false
      duplicate.errors.first.field.should eq("email")
      duplicate.errors.first.message.not_nil!.should eq("has already been taken")
    end

    it "allows updating the same record (excludes self)" do
      UniqueUser.clear
      user = UniqueUser.new
      user.email = "self@example.com"
      user.username = "selfuser"
      user.save!

      # Simulate updating by re-fetching
      found = UniqueUser.find!(user.id)
      found.username = "updatedname"
      found.valid?.should be_true
    end

    it "allows nil values by default" do
      UniqueUser.clear
      user = UniqueUser.new
      user.email = nil
      user.username = "niluser"
      user.valid?.should be_true
    end

    it "supports custom error message" do
      UniqueUser.clear
      existing = UniqueUser.new
      existing.email = "first@example.com"
      existing.username = "firstuser"
      existing.save!

      duplicate = UniqueUser.new
      duplicate.email = "second@example.com"
      duplicate.username = "firstuser"
      duplicate.valid?.should be_false
      duplicate.errors.first.message.not_nil!.should eq("is already taken")
    end
  end

  describe "case_sensitive option" do
    it "is case-sensitive by default" do
      UniqueUser.clear
      existing = UniqueUser.new
      existing.email = "CaseSensitive@example.com"
      existing.username = "caseuser"
      existing.save!

      different_case = UniqueUser.new
      different_case.email = "casesensitive@example.com"
      different_case.username = "caseuser2"
      # Default is case-sensitive, so different case is a different value
      different_case.valid?.should be_true
    end

    it "detects duplicates case-insensitively when case_sensitive: false" do
      UniqueUser.clear
      existing = UniqueUser.new
      existing.email = "first@example.com"
      existing.username = "CaseUser"
      existing.save!

      duplicate = UniqueUser.new
      duplicate.email = "second@example.com"
      duplicate.username = "caseuser" # different case
      # username uses case_sensitive: false
      duplicate.valid?.should be_false
      duplicate.errors.first.field.should eq("username")
    end
  end

  describe "scope option" do
    it "validates uniqueness within scope" do
      ScopedUnique.clear
      existing = ScopedUnique.new
      existing.name = "Widget"
      existing.category = "Electronics"
      existing.region = "US"
      existing.save!

      # Same name but different category — should pass
      different_scope = ScopedUnique.new
      different_scope.name = "Widget"
      different_scope.category = "Toys"
      different_scope.region = "US"
      different_scope.valid?.should be_true

      # Same name and same category — should fail
      duplicate = ScopedUnique.new
      duplicate.name = "Widget"
      duplicate.category = "Electronics"
      duplicate.region = "EU"
      duplicate.valid?.should be_false
      duplicate.errors.first.field.should eq("name")
    end

    it "validates uniqueness with multi-field scope" do
      ScopedUnique.clear
      existing = ScopedUnique.new
      existing.name = "Widget"
      existing.category = "Electronics"
      existing.region = "US"
      existing.code = "EL-US-001"
      existing.save!

      # Same code, different scope (category+region) — should pass
      different_scope = ScopedUnique.new
      different_scope.name = "Other"
      different_scope.category = "Toys"
      different_scope.region = "US"
      different_scope.code = "EL-US-001"
      different_scope.valid?.should be_true

      # Same code, same scope (category+region) — should fail
      duplicate = ScopedUnique.new
      duplicate.name = "Another"
      duplicate.category = "Electronics"
      duplicate.region = "US"
      duplicate.code = "EL-US-001"
      duplicate.valid?.should be_false
      duplicate.errors.map(&.field).should contain("code")
    end

    it "allows updating the scoped record itself" do
      ScopedUnique.clear
      record = ScopedUnique.new
      record.name = "Gadget"
      record.category = "Tech"
      record.region = "EU"
      record.save!

      found = ScopedUnique.find!(record.id)
      found.region = "UK"
      found.valid?.should be_true
    end
  end
end

# Test models for uniqueness validation
class UniqueUser < Grant::Base
  connection sqlite
  table unique_users

  column id : Int64, primary: true
  column email : String?
  column username : String?

  validates_uniqueness_of :email
  validates_uniqueness_of :username, case_sensitive: false, message: "is already taken"
end

class ScopedUnique < Grant::Base
  connection sqlite
  table scoped_uniques

  column id : Int64, primary: true
  column name : String?
  column category : String?
  column region : String?
  column code : String?

  validates_uniqueness_of :name, scope: [:category]
  validates_uniqueness_of :code, scope: [:category, :region]
end
