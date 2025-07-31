require "../../spec_helper"

describe "Granite::Associations Integration Tests" do
  describe "polymorphic with advanced options" do
    it "works with dependent: :destroy on polymorphic associations" do
      author = PolymorphicAuthor.create!(name: "Jane")
      note1 = AuthorNote.create!(content: "Note 1", notable: author)
      note2 = AuthorNote.create!(content: "Note 2", notable: author)
      
      AuthorNote.where(notable_type: "PolymorphicAuthor", notable_id: author.id).count.should eq(2)
      
      author.destroy!
      
      AuthorNote.where(notable_type: "PolymorphicAuthor", notable_id: author.id).count.should eq(0)
    end
    
    it "works with counter_cache on polymorphic associations" do
      article = CachedArticle.create!(title: "Test Article", reactions_count: 0)
      video = CachedVideo.create!(title: "Test Video", reactions_count: 0)
      
      reaction1 = Reaction.create!(emoji: "👍", reactable: article)
      CachedArticle.find!(article.id.not_nil!).reactions_count.should eq(1)
      
      reaction2 = Reaction.create!(emoji: "❤️", reactable: article)
      CachedArticle.find!(article.id.not_nil!).reactions_count.should eq(2)
      
      reaction3 = Reaction.create!(emoji: "🎉", reactable: video)
      CachedVideo.find!(video.id.not_nil!).reactions_count.should eq(1)
      
      reaction1.destroy!
      CachedArticle.find!(article.id.not_nil!).reactions_count.should eq(1)
    end
    
    it "works with touch on polymorphic associations" do
      project = TouchableProject.create!(name: "Project")
      original_updated = project.updated_at
      
      sleep 0.001
      
      task = ProjectTask.create!(title: "Task", touchable: project)
      
      updated_project = TouchableProject.find!(project.id.not_nil!)
      updated_project.updated_at.should_not eq(original_updated)
    end
  end
  
  describe "multiple options combined" do
    it "combines optional, touch, and counter_cache" do
      forum = Forum.create!(name: "Tech Forum", posts_count: 0)
      
      # Create post with forum
      post1 = ForumPost.create!(title: "Post 1", forum: forum)
      
      updated_forum = Forum.find!(forum.id.not_nil!)
      updated_forum.posts_count.should eq(1)
      original_updated = updated_forum.updated_at
      
      sleep 0.001
      
      # Create post without forum (optional: true)
      post2 = ForumPost.create!(title: "Post 2")
      post2.forum_id.should be_nil
      
      # Update post to add forum
      post2.forum = forum
      post2.save!
      
      final_forum = Forum.find!(forum.id.not_nil!)
      final_forum.posts_count.should eq(2)
      final_forum.updated_at.should_not eq(original_updated)
    end
    
    it "combines dependent and autosave" do
      order = ComplexOrder.create!(number: "ORD-001")
      item1 = OrderItem.new(product: "Widget", quantity: 2)
      item2 = OrderItem.new(product: "Gadget", quantity: 1)
      
      order.items = [item1, item2]
      order.save!
      
      # Items should be saved automatically
      OrderItem.where(complex_order_id: order.id).count.should eq(2)
      
      # Destroying order should destroy items
      order.destroy!
      OrderItem.count.should eq(0)
    end
  end
  
  describe "autosave option" do
    it "saves new associated records on parent save" do
      company = AutosaveCompany.create!(name: "ACME Corp")
      
      employee1 = AutosaveEmployee.new(name: "John Doe")
      employee2 = AutosaveEmployee.new(name: "Jane Smith")
      
      company.employees = [employee1, employee2]
      company.save!
      
      AutosaveEmployee.where(autosave_company_id: company.id).count.should eq(2)
      employee1.persisted?.should be_true
      employee2.persisted?.should be_true
    end
    
    it "saves changes to existing associated records" do
      profile = UserProfile.create!(username: "johndoe")
      settings = ProfileSettings.create!(theme: "light", user_profile: profile)
      
      profile.reload
      profile.settings.not_nil!.theme = "dark"
      profile.save!
      
      ProfileSettings.find!(settings.id.not_nil!).theme.should eq("dark")
    end
  end
  
  describe "edge cases and error scenarios" do
    it "handles circular references gracefully" do
      parent = TreeNode.create!(name: "Parent")
      child = TreeNode.create!(name: "Child", parent: parent)
      
      # This should not cause infinite loop
      parent.children.to_a.size.should eq(1)
      child.parent.not_nil!.name.should eq("Parent")
    end
    
    it "validates required associations before optional ones" do
      # Product requires category but manufacturer is optional
      product = ValidatedProduct.new(name: "Widget")
      product.valid?.should be_false
      product.errors.map(&.message).should contain("category must exist")
      
      category = ProductCategory.create!(name: "Electronics")
      product.category = category
      product.valid?.should be_true
    end
  end
end

# Polymorphic with dependent
class AuthorNote < Granite::Base
  connection sqlite
  table author_notes
  
  column id : Int64, primary: true
  column content : String
  
  belongs_to :notable, polymorphic: true
end

class PolymorphicAuthor < Granite::Base
  connection sqlite
  table polymorphic_authors
  
  column id : Int64, primary: true
  column name : String
  
  has_many :notes, class_name: AuthorNote, as: :notable, dependent: :destroy
end

# Polymorphic with counter_cache
class Reaction < Granite::Base
  connection sqlite
  table reactions
  
  column id : Int64, primary: true
  column emoji : String
  
  belongs_to :reactable, polymorphic: true, counter_cache: :reactions_count
end

class CachedArticle < Granite::Base
  connection sqlite
  table cached_articles
  
  column id : Int64, primary: true
  column title : String
  column reactions_count : Int32
  
  has_many :reactions, as: :reactable
end

class CachedVideo < Granite::Base
  connection sqlite
  table cached_videos
  
  column id : Int64, primary: true
  column title : String
  column reactions_count : Int32
  
  has_many :reactions, as: :reactable
end

# Polymorphic with touch
class ProjectTask < Granite::Base
  connection sqlite
  table project_tasks
  
  column id : Int64, primary: true
  column title : String
  
  belongs_to :touchable, polymorphic: true, touch: true
end

class TouchableProject < Granite::Base
  connection sqlite
  table touchable_projects
  
  column id : Int64, primary: true
  column name : String
  timestamps
  
  has_many :tasks, class_name: ProjectTask, as: :touchable
end

# Multiple options combined
class Forum < Granite::Base
  connection sqlite
  table forums
  
  column id : Int64, primary: true
  column name : String
  column posts_count : Int32
  timestamps
  
  has_many :posts, class_name: ForumPost
end

class ForumPost < Granite::Base
  connection sqlite
  table forum_posts
  
  column id : Int64, primary: true
  column title : String
  
  belongs_to :forum, optional: true, counter_cache: :posts_count, touch: true
end

# Autosave with dependent
class ComplexOrder < Granite::Base
  connection sqlite
  table complex_orders
  
  column id : Int64, primary: true
  column number : String
  
  has_many :items, class_name: OrderItem, dependent: :destroy, autosave: true
end

class OrderItem < Granite::Base
  connection sqlite
  table order_items
  
  column id : Int64, primary: true
  column product : String
  column quantity : Int32
  column complex_order_id : Int64?
end

# Has many autosave
class AutosaveCompany < Granite::Base
  connection sqlite
  table autosave_companies
  
  column id : Int64, primary: true
  column name : String
  
  has_many :employees, class_name: AutosaveEmployee, autosave: true
end

class AutosaveEmployee < Granite::Base
  connection sqlite
  table autosave_employees
  
  column id : Int64, primary: true
  column name : String
  column autosave_company_id : Int64?
end

# Has one autosave
class UserProfile < Granite::Base
  connection sqlite
  table user_profiles
  
  column id : Int64, primary: true
  column username : String
  
  has_one :settings, class_name: ProfileSettings, autosave: true
end

class ProfileSettings < Granite::Base
  connection sqlite
  table profile_settings
  
  column id : Int64, primary: true
  column theme : String
  column user_profile_id : Int64?
  
  belongs_to :user_profile
end

# Self-referential
class TreeNode < Granite::Base
  connection sqlite
  table tree_nodes
  
  column id : Int64, primary: true
  column name : String
  column parent_id : Int64?
  
  belongs_to :parent, class_name: TreeNode, foreign_key: :parent_id, optional: true
  has_many :children, class_name: TreeNode, foreign_key: :parent_id
end

# Validation order
class ProductCategory < Granite::Base
  connection sqlite
  table product_categories
  
  column id : Int64, primary: true
  column name : String
end

class ProductManufacturer < Granite::Base
  connection sqlite
  table product_manufacturers
  
  column id : Int64, primary: true
  column name : String
end

class ValidatedProduct < Granite::Base
  connection sqlite
  table validated_products
  
  column id : Int64, primary: true
  column name : String
  
  belongs_to :category, class_name: ProductCategory
  belongs_to :manufacturer, class_name: ProductManufacturer, optional: true
end