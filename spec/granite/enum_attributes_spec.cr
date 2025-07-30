require "../spec_helper"

describe "Granite::EnumAttributes" do
  describe "basic enum functionality" do
    it "creates enum column with converter" do
      article = EnumArticle.new(title: "Test Article")
      article.status.should eq(EnumArticle::Status::Draft)
    end
    
    it "persists and retrieves enum values" do
      article = EnumArticle.create!(title: "Test", status: :published)
      
      loaded = EnumArticle.find!(article.id.not_nil!)
      loaded.status.should eq(EnumArticle::Status::Published)
    end
    
    it "handles nil enum values when allowed" do
      item = OptionalEnumItem.create!(name: "Item")
      item.priority.should be_nil
      
      loaded = OptionalEnumItem.find!(item.id.not_nil!)
      loaded.priority.should be_nil
    end
  end
  
  describe "predicate methods" do
    it "generates predicate methods for each enum value" do
      article = EnumArticle.new
      
      article.draft?.should be_true
      article.published?.should be_false
      article.archived?.should be_false
    end
    
    it "predicate methods update with value changes" do
      article = EnumArticle.new
      article.status = EnumArticle::Status::Published
      
      article.draft?.should be_false
      article.published?.should be_true
    end
  end
  
  describe "bang methods" do
    it "generates bang methods to set enum values" do
      article = EnumArticle.new
      
      article.published!
      article.status.should eq(EnumArticle::Status::Published)
      article.published?.should be_true
      
      article.archived!
      article.status.should eq(EnumArticle::Status::Archived)
      article.archived?.should be_true
    end
  end
  
  describe "scopes" do
    before_all do
      EnumArticle.clear
      EnumArticle.create!(title: "Draft 1", status: :draft)
      EnumArticle.create!(title: "Draft 2", status: :draft)
      EnumArticle.create!(title: "Published 1", status: :published)
      EnumArticle.create!(title: "Archived 1", status: :archived)
    end
    
    it "generates scopes for each enum value" do
      EnumArticle.draft.count.should eq(2)
      EnumArticle.published.count.should eq(1)
      EnumArticle.archived.count.should eq(1)
    end
    
    it "scopes can be chained" do
      articles = EnumArticle.published.where(title: "Published 1")
      articles.count.should eq(1)
      articles.first.title.should eq("Published 1")
    end
  end
  
  describe "class methods" do
    it "provides access to all enum values" do
      statuses = EnumArticle.statuses
      statuses.should contain(EnumArticle::Status::Draft)
      statuses.should contain(EnumArticle::Status::Published)
      statuses.should contain(EnumArticle::Status::Archived)
    end
    
    it "provides enum mapping" do
      mapping = EnumArticle.status_mapping
      mapping["draft"].should eq(EnumArticle::Status::Draft)
      mapping["published"].should eq(EnumArticle::Status::Published)
      mapping["archived"].should eq(EnumArticle::Status::Archived)
    end
  end
  
  describe "default values" do
    it "sets default enum value" do
      article = EnumArticle.new
      article.status.should eq(EnumArticle::Status::Draft)
    end
    
    it "respects explicitly set values over defaults" do
      article = EnumArticle.new(status: :published)
      article.status.should eq(EnumArticle::Status::Published)
    end
    
    it "doesn't override existing record values" do
      article = EnumArticle.create!(title: "Test", status: :published)
      loaded = EnumArticle.find!(article.id.not_nil!)
      loaded.status.should eq(EnumArticle::Status::Published)
    end
  end
  
  describe "multiple enums" do
    it "supports multiple enum attributes" do
      task = MultiEnumTask.new(title: "Task")
      
      task.status.should eq(MultiEnumTask::Status::Pending)
      task.priority.should eq(MultiEnumTask::Priority::Medium)
      
      task.pending?.should be_true
      task.medium?.should be_true
      
      task.completed!
      task.high!
      
      task.status.should eq(MultiEnumTask::Status::Completed)
      task.priority.should eq(MultiEnumTask::Priority::High)
    end
  end
  
  describe "custom column types" do
    it "supports integer column storage" do
      user = IntegerEnumUser.create!(name: "John", role: :admin)
      
      # Verify it's stored as integer
      raw_value = IntegerEnumUser.adapter.open do |db|
        db.scalar("SELECT role FROM integer_enum_users WHERE id = ?", user.id).as(Int64)
      end
      raw_value.should eq(2) # Admin = 2
      
      loaded = IntegerEnumUser.find!(user.id.not_nil!)
      loaded.role.should eq(IntegerEnumUser::Role::Admin)
    end
  end
end

# Test models
class EnumArticle < Granite::Base
  connection sqlite
  table enum_articles
  
  column id : Int64, primary: true
  column title : String
  
  enum Status
    Draft
    Published
    Archived
  end
  
  enum_attribute status : Status = :draft
end

class OptionalEnumItem < Granite::Base
  connection sqlite
  table optional_enum_items
  
  column id : Int64, primary: true
  column name : String
  
  enum Priority
    Low
    Medium
    High
  end
  
  enum_attribute priority : Priority?, column_type: String
end

class MultiEnumTask < Granite::Base
  connection sqlite
  table multi_enum_tasks
  
  column id : Int64, primary: true
  column title : String
  
  enum Status
    Pending
    InProgress
    Completed
  end
  
  enum Priority
    Low
    Medium 
    High
  end
  
  enum_attributes status: {type: Status, default: :pending},
                  priority: {type: Priority, default: :medium}
end

class IntegerEnumUser < Granite::Base
  connection sqlite
  table integer_enum_users
  
  column id : Int64, primary: true
  column name : String
  
  enum Role
    Guest = 0
    Member = 1
    Admin = 2
  end
  
  enum_attribute role : Role = :member, column_type: Int32
end