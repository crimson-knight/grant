require "../../spec_helper"

describe "Grant::Associations::Options" do
  describe "dependent options" do
    describe "dependent: :destroy" do
      it "destroys associated records when parent is destroyed" do
        author = DependentAuthor.create!(name: "Jane Doe")
        post1 = DependentPost.create!(title: "Post 1", dependent_author_id: author.id)
        post2 = DependentPost.create!(title: "Post 2", dependent_author_id: author.id)
        
        DependentPost.where(dependent_author_id: author.id).count.should eq(2)
        
        author.destroy!
        
        DependentPost.where(dependent_author_id: author.id).count.should eq(0)
      end
    end
    
    describe "dependent: :nullify" do
      it "nullifies foreign keys when parent is destroyed" do
        category = NullifyCategory.create!(name: "Tech")
        article1 = NullifyArticle.create!(title: "Article 1", nullify_category_id: category.id)
        article2 = NullifyArticle.create!(title: "Article 2", nullify_category_id: category.id)
        
        category.destroy!
        
        NullifyArticle.find!(article1.id.not_nil!).nullify_category_id.should be_nil
        NullifyArticle.find!(article2.id.not_nil!).nullify_category_id.should be_nil
      end
    end
    
    describe "dependent: :restrict" do
      it "prevents deletion when dependent records exist" do
        team = RestrictTeam.create!(name: "Engineering")
        member = RestrictMember.create!(name: "John", restrict_team_id: team.id)
        
        expect_raises(Grant::RecordNotDestroyed) do
          team.destroy!
        end
        
        RestrictTeam.exists?(team.id).should be_true
      end
    end
  end
  
  describe "optional: true" do
    it "allows nil foreign key with optional: true" do
      item = OptionalItem.create!(name: "Item without category")
      item.optional_category_id.should be_nil
      item.valid?.should be_true
    end
    
    pending "requires foreign key without optional option" do
      item = RequiredItem.new(name: "Item")
      item.valid?.should be_false
      item.errors.size.should be > 0
      item.errors.first.message.should contain("must exist")
    end
  end
  
  describe "counter_cache" do
    it "updates counter cache on create" do
      blog = CounterBlog.create!(title: "My Blog", counter_posts_count: 0)
      
      post1 = CounterPost.create!(content: "Post 1", counter_blog_id: blog.id)
      CounterBlog.find!(blog.id.not_nil!).counter_posts_count.should eq(1)
      
      post2 = CounterPost.create!(content: "Post 2", counter_blog_id: blog.id)
      CounterBlog.find!(blog.id.not_nil!).counter_posts_count.should eq(2)
    end
    
    it "updates counter cache on destroy" do
      blog = CounterBlog.create!(title: "My Blog", counter_posts_count: 2)
      post = CounterPost.create!(content: "Post", counter_blog_id: blog.id)
      
      post.destroy!
      CounterBlog.find!(blog.id.not_nil!).counter_posts_count.should eq(2)
    end
  end
  
  describe "touch: true" do
    it "touches parent record on save" do
      user = TouchUser.create!(name: "John")
      original_updated_at = user.updated_at
      
      sleep 0.001 # Ensure time difference
      
      profile = TouchProfile.create!(bio: "Bio", touch_user_id: user.id)
      
      updated_user = TouchUser.find!(user.id.not_nil!)
      updated_user.updated_at.should_not eq(original_updated_at)
    end
  end
end

# Test models for dependent options
class DependentAuthor < Grant::Base
  connection sqlite
  table dependent_authors
  
  column id : Int64, primary: true
  column name : String
  
  has_many :posts, class_name: DependentPost, foreign_key: :dependent_author_id, dependent: :destroy
end

class DependentPost < Grant::Base
  connection sqlite
  table dependent_posts
  
  column id : Int64, primary: true
  column title : String
  column dependent_author_id : Int64?
end

# Test models for nullify
class NullifyCategory < Grant::Base
  connection sqlite
  table nullify_categories
  
  column id : Int64, primary: true
  column name : String
  
  has_many :articles, class_name: NullifyArticle, foreign_key: :nullify_category_id, dependent: :nullify
end

class NullifyArticle < Grant::Base
  connection sqlite
  table nullify_articles
  
  column id : Int64, primary: true
  column title : String
  column nullify_category_id : Int64?
end

# Test models for restrict
class RestrictTeam < Grant::Base
  connection sqlite
  table restrict_teams
  
  column id : Int64, primary: true
  column name : String
  
  has_many :members, class_name: RestrictMember, foreign_key: :restrict_team_id, dependent: :restrict
end

class RestrictMember < Grant::Base
  connection sqlite
  table restrict_members
  
  column id : Int64, primary: true
  column name : String
  column restrict_team_id : Int64?
end

# Test models for optional
class OptionalCategory < Grant::Base
  connection sqlite
  table optional_categories
  
  column id : Int64, primary: true
  column name : String
end

class OptionalItem < Grant::Base
  connection sqlite
  table optional_items
  
  column id : Int64, primary: true
  column name : String
  
  belongs_to :optional_category, optional: true
end

class RequiredItem < Grant::Base
  connection sqlite
  table required_items
  
  column id : Int64, primary: true
  column name : String
  column required_category_id : Int64?
  
  belongs_to :required_category, class_name: OptionalCategory
end

# Test models for counter cache
class CounterBlog < Grant::Base
  connection sqlite
  table counter_blogs
  
  column id : Int64, primary: true
  column title : String
  column counter_posts_count : Int32
end

class CounterPost < Grant::Base
  connection sqlite
  table counter_posts
  
  column id : Int64, primary: true
  column content : String
  
  belongs_to :counter_blog, counter_cache: true
end

# Test models for touch
class TouchUser < Grant::Base
  connection sqlite
  table touch_users
  
  column id : Int64, primary: true
  column name : String
  timestamps
end

class TouchProfile < Grant::Base
  connection sqlite
  table touch_profiles
  
  column id : Int64, primary: true
  column bio : String
  
  belongs_to :touch_user, touch: true
end