require "../../spec_helper"

describe "Granite::Associations::AdditionalOptions" do
  describe "counter_cache with updates" do
    it "updates counter when association changes" do
      blog1 = UpdateBlog.create!(title: "Blog 1", posts_count: 0)
      blog2 = UpdateBlog.create!(title: "Blog 2", posts_count: 0)
      
      post = UpdatePost.create!(title: "Post", update_blog_id: blog1.id)
      
      UpdateBlog.find!(blog1.id.not_nil!).posts_count.should eq(1)
      UpdateBlog.find!(blog2.id.not_nil!).posts_count.should eq(0)
      
      # Change blog association
      post.update_blog_id = blog2.id
      post.save!
      
      UpdateBlog.find!(blog1.id.not_nil!).posts_count.should eq(0)
      UpdateBlog.find!(blog2.id.not_nil!).posts_count.should eq(1)
    end
    
    it "uses custom counter column name" do
      author = CustomAuthor.create!(name: "Jane", total_articles: 0)
      
      article1 = CustomArticle.create!(title: "Article 1", custom_author_id: author.id)
      CustomAuthor.find!(author.id.not_nil!).total_articles.should eq(1)
      
      article2 = CustomArticle.create!(title: "Article 2", custom_author_id: author.id)
      CustomAuthor.find!(author.id.not_nil!).total_articles.should eq(2)
    end
  end
  
  describe "touch with custom column" do
    it "touches custom column on parent" do
      post = TouchPost.create!(title: "Post")
      original_commented_at = post.last_commented_at
      
      sleep 0.001
      
      comment = TouchComment.create!(content: "Great post!", touch_post_id: post.id)
      
      updated_post = TouchPost.find!(post.id.not_nil!)
      updated_post.last_commented_at.should_not eq(original_commented_at)
    end
    
    it "touches on update as well as create" do
      user = TouchUpdateUser.create!(name: "John")
      activity = UserActivity.create!(description: "Joined", touch_update_user_id: user.id)
      
      original_active_at = TouchUpdateUser.find!(user.id.not_nil!).last_active_at
      
      sleep 0.001
      
      activity.description = "Updated profile"
      activity.save!
      
      TouchUpdateUser.find!(user.id.not_nil!).last_active_at.should_not eq(original_active_at)
    end
  end
  
  describe "dependent with has_one" do
    it "destroys has_one association" do
      account = Account.create!(email: "test@example.com")
      preferences = AccountPreferences.create!(theme: "dark", account_id: account.id)
      
      AccountPreferences.exists?(preferences.id).should be_true
      
      account.destroy!
      
      AccountPreferences.exists?(preferences.id).should be_false
    end
    
    it "nullifies has_one association" do
      profile = NullifyProfile.create!(name: "John")
      avatar = ProfileAvatar.create!(url: "avatar.jpg", nullify_profile_id: profile.id)
      
      profile.destroy!
      
      ProfileAvatar.find!(avatar.id.not_nil!).nullify_profile_id.should be_nil
    end
  end
  
  describe "polymorphic with custom columns" do
    it "uses custom foreign key and type columns" do
      document = Document.create!(title: "Report")
      attachment = Attachment.create!(filename: "report.pdf", owner: document)
      
      attachment.owner_id.should eq(document.id)
      attachment.owner_class.should eq("Document")
      
      loaded = Attachment.find!(attachment.id.not_nil!)
      loaded.owner.not_nil!.id.should eq(document.id)
    end
  end
  
  describe "autosave edge cases" do
    it "doesn't save if parent validation fails" do
      invalid_order = FailedOrder.create(order_number: "") # Missing required field
      line_item = FailedLineItem.new(product: "Widget", quantity: 1)
      
      invalid_order.items = [line_item]
      
      expect_raises(Granite::RecordNotSaved) do
        invalid_order.save!
      end
      
      FailedLineItem.count.should eq(0)
    end
    
    it "handles belongs_to autosave" do
      new_vendor = Vendor.new(name: "ACME Supplies")
      product = VendorProduct.new(name: "Widget", vendor: new_vendor)
      
      product.save!
      
      # Vendor should be saved automatically
      new_vendor.persisted?.should be_true
      Vendor.find!(new_vendor.id.not_nil!).name.should eq("ACME Supplies")
    end
  end
end

# Counter cache update test models
class UpdateBlog < Granite::Base
  connection sqlite
  table update_blogs
  
  column id : Int64, primary: true
  column title : String
  column posts_count : Int32
end

class UpdatePost < Granite::Base
  connection sqlite
  table update_posts
  
  column id : Int64, primary: true
  column title : String
  
  belongs_to :update_blog, counter_cache: :posts_count
end

# Custom counter column
class CustomAuthor < Granite::Base
  connection sqlite
  table custom_authors
  
  column id : Int64, primary: true
  column name : String
  column total_articles : Int32
end

class CustomArticle < Granite::Base
  connection sqlite
  table custom_articles
  
  column id : Int64, primary: true
  column title : String
  
  belongs_to :custom_author, counter_cache: :total_articles
end

# Touch with custom column
class TouchPost < Granite::Base
  connection sqlite
  table touch_posts
  
  column id : Int64, primary: true
  column title : String
  column last_commented_at : Time?
  timestamps
end

class TouchComment < Granite::Base
  connection sqlite
  table touch_comments
  
  column id : Int64, primary: true
  column content : String
  
  belongs_to :touch_post, touch: :last_commented_at
end

# Touch on update
class TouchUpdateUser < Granite::Base
  connection sqlite
  table touch_update_users
  
  column id : Int64, primary: true
  column name : String
  column last_active_at : Time?
  timestamps
end

class UserActivity < Granite::Base
  connection sqlite
  table user_activities
  
  column id : Int64, primary: true
  column description : String
  
  belongs_to :touch_update_user, touch: :last_active_at
end

# Has one with dependent
class Account < Granite::Base
  connection sqlite
  table accounts
  
  column id : Int64, primary: true
  column email : String
  
  has_one :preferences, class_name: AccountPreferences, dependent: :destroy
end

class AccountPreferences < Granite::Base
  connection sqlite
  table account_preferences
  
  column id : Int64, primary: true
  column theme : String
  column account_id : Int64?
end

# Has one nullify
class NullifyProfile < Granite::Base
  connection sqlite
  table nullify_profiles
  
  column id : Int64, primary: true
  column name : String
  
  has_one :avatar, class_name: ProfileAvatar, foreign_key: :nullify_profile_id, dependent: :nullify
end

class ProfileAvatar < Granite::Base
  connection sqlite
  table profile_avatars
  
  column id : Int64, primary: true
  column url : String
  column nullify_profile_id : Int64?
end

# Polymorphic custom columns
class Attachment < Granite::Base
  connection sqlite
  table attachments
  
  column id : Int64, primary: true
  column filename : String
  
  belongs_to :owner, polymorphic: true, foreign_key: :owner_id, type_column: :owner_class
end

class Document < Granite::Base
  connection sqlite
  table documents
  
  column id : Int64, primary: true
  column title : String
  
  has_many :attachments, as: :owner
end

# Autosave validation failure
class FailedOrder < Granite::Base
  connection sqlite
  table failed_orders
  
  column id : Int64, primary: true
  column order_number : String
  
  has_many :items, class_name: FailedLineItem, autosave: true
  
  validate :order_number, "can't be blank" do |order|
    !order.order_number.to_s.blank?
  end
end

class FailedLineItem < Granite::Base
  connection sqlite
  table failed_line_items
  
  column id : Int64, primary: true
  column product : String
  column quantity : Int32
  column failed_order_id : Int64?
end

# Belongs to autosave
class Vendor < Granite::Base
  connection sqlite
  table vendors
  
  column id : Int64, primary: true
  column name : String
end

class VendorProduct < Granite::Base
  connection sqlite
  table vendor_products
  
  column id : Int64, primary: true
  column name : String
  
  belongs_to :vendor, autosave: true
end