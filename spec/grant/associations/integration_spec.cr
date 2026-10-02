require "../../spec_helper"

describe "Grant::Associations Integration Tests" do
  before_all do
    AuthorNote.migrator.drop_and_create
    PolymorphicAuthor.migrator.drop_and_create
    Reaction.migrator.drop_and_create
    CachedArticle.migrator.drop_and_create
    CachedVideo.migrator.drop_and_create
    ProjectTask.migrator.drop_and_create
    TouchableProject.migrator.drop_and_create
    Forum.migrator.drop_and_create
    ForumPost.migrator.drop_and_create
    ComplexOrder.migrator.drop_and_create
    OrderItem.migrator.drop_and_create
    AutosaveCompany.migrator.drop_and_create
    AutosaveEmployee.migrator.drop_and_create
    UserProfile.migrator.drop_and_create
    ProfileSettings.migrator.drop_and_create
    TreeNode.migrator.drop_and_create
    ProductCategory.migrator.drop_and_create
    ProductManufacturer.migrator.drop_and_create
    ValidatedProduct.migrator.drop_and_create
  end

  before_each do
    AuthorNote.clear
    Reaction.clear
    ProjectTask.clear
    ForumPost.clear
    OrderItem.clear
    AutosaveEmployee.clear
    ProfileSettings.clear
    TreeNode.clear
    ValidatedProduct.clear
    ProductManufacturer.clear
    ProductCategory.clear
    UserProfile.clear
    AutosaveCompany.clear
    ComplexOrder.clear
    Forum.clear
    TouchableProject.clear
    CachedVideo.clear
    CachedArticle.clear
    PolymorphicAuthor.clear
  end

  describe "polymorphic with advanced options" do
    it "works with dependent: :destroy on polymorphic associations" do
      author = PolymorphicAuthor.create!(name: "Jane")
      note1 = AuthorNote.new(content: "Note 1")
      note1.notable = author
      note1.save!
      note2 = AuthorNote.new(content: "Note 2")
      note2.notable = author
      note2.save!

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
      original_updated = Time.utc(2000, 1, 1)
      project.updated_at = original_updated
      project.save!(skip_timestamps: true)

      task = ProjectTask.create!(title: "Task", touchable: project)

      updated_project = TouchableProject.find!(project.id.not_nil!)
      updated_project.updated_at.not_nil!.should be > original_updated
    end
  end

  describe "multiple options combined" do
    it "combines optional, touch, and counter_cache" do
      forum = Forum.create!(name: "Tech Forum", posts_count: 0)

      # Create post with forum
      post1 = ForumPost.create!(title: "Post 1", forum: forum)

      updated_forum = Forum.find!(forum.id.not_nil!)
      updated_forum.posts_count.should eq(1)
      original_updated = Time.utc(2000, 1, 1)
      updated_forum.updated_at = original_updated
      updated_forum.save!(skip_timestamps: true)

      # Create post without forum (optional: true)
      post2 = ForumPost.create!(title: "Post 2")
      post2.forum_id.should be_nil

      # Update post to add forum
      post2.update(forum: forum).should be_true
      post2.forum_id.should eq(forum.id)
      post2.forum.should be(forum)

      final_forum = Forum.find!(forum.id.not_nil!)
      final_forum.posts_count.should eq(2)
      final_forum.updated_at.not_nil!.should be > original_updated
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
      employee1 = AutosaveEmployee.new(name: "John Doe")
      employee2 = AutosaveEmployee.new(name: "Jane Smith")
      company = AutosaveCompany.new(name: "ACME Corp", employees: [employee1, employee2])
      company.save!

      AutosaveEmployee.where(autosave_company_id: company.id).count.should eq(2)
      employee1.persisted?.should be_true
      employee2.persisted?.should be_true
    end

    it "saves changes to existing associated records" do
      profile = UserProfile.create!(username: "johndoe")
      settings = ProfileSettings.new(theme: "light", user_profile: profile)
      settings.save!

      profile.reload
      profile.settings.not_nil!.theme = "dark"
      profile.save!

      ProfileSettings.find!(settings.id.not_nil!).theme.should eq("dark")
    end

    it "mass assigns belongs_to associations through new, create!, and update" do
      first_profile = UserProfile.create!(username: "first")
      second_profile = UserProfile.create!(username: "second")

      new_settings = ProfileSettings.new(theme: "new", user_profile: first_profile)
      new_settings.user_profile_id.should eq(first_profile.id)
      new_settings.user_profile.should be(first_profile)
      new_settings.save!

      created_settings = ProfileSettings.create!(theme: "created", user_profile: first_profile)
      created_settings.user_profile.should be(first_profile)

      created_settings.update(user_profile: second_profile).should be_true
      created_settings.user_profile_id.should eq(second_profile.id)
      created_settings.user_profile.should be(second_profile)
    end

    it "mass assigns has_one associations and saves them with the owner" do
      settings = ProfileSettings.new(theme: "dark")
      profile = UserProfile.new(username: "with-settings", settings: settings)

      profile.save!

      settings.persisted?.should be_true
      settings.user_profile_id.should eq(profile.id)
      profile.settings.should be(settings)
    end

    it "mass assigns has_many associations without an autosave option" do
      first_post = ForumPost.new(title: "First")
      second_post = ForumPost.new(title: "Second")
      forum = Forum.new(name: "with posts", posts_count: 0, posts: [first_post, second_post])

      forum.save!

      ForumPost.where(forum_id: forum.id).count.should eq(2)
      first_post.persisted?.should be_true
      second_post.persisted?.should be_true
      first_post.forum_id.should eq(forum.id)
      second_post.forum_id.should eq(forum.id)
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
class AuthorNote < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table author_notes

  column id : Int64, primary: true
  column content : String

  belongs_to :notable, polymorphic: true
end

class PolymorphicAuthor < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table polymorphic_authors

  column id : Int64, primary: true
  column name : String

  has_many :notes, class_name: AuthorNote, as: :notable, dependent: :destroy
end

# Polymorphic with counter_cache
class Reaction < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table reactions

  column id : Int64, primary: true
  column emoji : String

  belongs_to :reactable, polymorphic: true, counter_cache: :reactions_count
end

class CachedArticle < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table cached_articles

  column id : Int64, primary: true
  column title : String
  column reactions_count : Int32

  has_many :reactions, as: :reactable
end

class CachedVideo < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table cached_videos

  column id : Int64, primary: true
  column title : String
  column reactions_count : Int32

  has_many :reactions, as: :reactable
end

# Polymorphic with touch
class ProjectTask < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table project_tasks

  column id : Int64, primary: true
  column title : String

  belongs_to :touchable, polymorphic: true, touch: true
end

class TouchableProject < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table touchable_projects

  column id : Int64, primary: true
  column name : String
  timestamps

  has_many :tasks, class_name: ProjectTask, as: :touchable
end

# Multiple options combined
class Forum < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table forums

  column id : Int64, primary: true
  column name : String
  column posts_count : Int32
  timestamps

  has_many :posts, class_name: ForumPost
end

class ForumPost < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table forum_posts

  column id : Int64, primary: true
  column title : String

  belongs_to :forum, optional: true, counter_cache: :posts_count, touch: true
end

# Autosave with dependent
class ComplexOrder < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table complex_orders

  column id : Int64, primary: true
  column number : String

  has_many :items, class_name: OrderItem, dependent: :destroy, autosave: true
end

class OrderItem < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table order_items

  column id : Int64, primary: true
  column product : String
  column quantity : Int32
  column complex_order_id : Int64?
end

# Has many autosave
class AutosaveCompany < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table autosave_companies

  column id : Int64, primary: true
  column name : String

  has_many :employees, class_name: AutosaveEmployee, autosave: true
end

class AutosaveEmployee < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table autosave_employees

  column id : Int64, primary: true
  column name : String
  column autosave_company_id : Int64?
end

# Has one autosave
class UserProfile < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table user_profiles

  column id : Int64, primary: true
  column username : String

  has_one :settings, class_name: ProfileSettings, autosave: true
end

class ProfileSettings < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table profile_settings

  column id : Int64, primary: true
  column theme : String
  column user_profile_id : Int64?

  belongs_to :user_profile
end

# Self-referential
class TreeNode < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table tree_nodes

  column id : Int64, primary: true
  column name : String
  column parent_id : Int64?

  belongs_to :parent, class_name: TreeNode, foreign_key: :parent_id, optional: true
  has_many :children, class_name: TreeNode, foreign_key: :parent_id
end

# Validation order
class ProductCategory < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table product_categories

  column id : Int64, primary: true
  column name : String
end

class ProductManufacturer < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table product_manufacturers

  column id : Int64, primary: true
  column name : String
end

class ValidatedProduct < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table validated_products

  column id : Int64, primary: true
  column name : String

  belongs_to :category, class_name: ProductCategory
  belongs_to :manufacturer, class_name: ProductManufacturer, optional: true
end
