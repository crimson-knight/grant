require "../../spec_helper"

describe "Granite::Validators::BuiltIn" do
  describe "validates_numericality_of" do
    it "validates numeric values" do
      product = NumericProduct.new(price: 10.5, quantity: 5)
      product.valid?.should be_true
      
      product.price = nil
      product.valid?.should be_false
      product.errors.first.message.should contain("is not a number")
    end
    
    it "validates greater_than constraint" do
      product = NumericProduct.new(price: 0.5, quantity: 5)
      product.valid?.should be_false
      product.errors.first.message.should contain("greater than 0")
      
      product.price = 10
      product.valid?.should be_true
    end
    
    it "validates only_integer option" do
      product = NumericProduct.new(price: 10.5, quantity: 5.5)
      product.valid?.should be_false
      product.errors.map(&.message).should contain("must be an integer")
      
      product.quantity = 5
      product.valid?.should be_true
    end
    
    it "validates even/odd options" do
      score = NumericScore.new(even_score: 3, odd_score: 4)
      score.valid?.should be_false
      
      score.even_score = 4
      score.odd_score = 3
      score.valid?.should be_true
    end
    
    it "supports conditional validation" do
      order = ConditionalOrder.new(status: "pending", total: nil)
      order.valid?.should be_true  # total not required when pending
      
      order.status = "completed"
      order.valid?.should be_false  # total required when completed
      order.errors.first.message.should contain("is not a number")
      
      order.total = 100.0
      order.valid?.should be_true
    end
  end
  
  describe "validates_format_of" do
    it "validates with pattern" do
      user = FormatUser.new(username: "john_doe", phone: "123")
      user.valid?.should be_false
      user.errors.first.message.should contain("is invalid")
      
      user.phone = "123-456-7890"
      user.valid?.should be_true
    end
    
    it "validates without pattern" do
      user = FormatUser.new(username: "admin", phone: "123-456-7890")
      user.valid?.should be_false
      user.errors.first.message.should contain("is reserved")
      
      user.username = "john"
      user.valid?.should be_true
    end
    
    it "validates email format" do
      contact = EmailContact.new(email: "invalid")
      contact.valid?.should be_false
      contact.errors.first.message.should contain("is not a valid email")
      
      contact.email = "user@example.com"
      contact.valid?.should be_true
    end
    
    it "validates URL format" do
      link = UrlLink.new(url: "not-a-url")
      link.valid?.should be_false
      link.errors.first.message.should contain("is not a valid URL")
      
      link.url = "https://example.com"
      link.valid?.should be_true
    end
  end
  
  describe "validates_length_of" do
    it "validates minimum length" do
      post = LengthPost.new(title: "Hi", body: "Short")
      post.valid?.should be_false
      post.errors.first.message.should contain("at least 3 characters")
      
      post.title = "Hello"
      post.valid?.should be_true
    end
    
    it "validates maximum length" do
      post = LengthPost.new(title: "A very long title that exceeds maximum", body: "Content")
      post.valid?.should be_false
      post.errors.first.message.should contain("at most 20 characters")
    end
    
    it "validates exact length" do
      code = ExactLengthCode.new(code: "ABC")
      code.valid?.should be_false
      code.errors.first.message.should contain("exactly 4 characters")
      
      code.code = "ABCD"
      code.valid?.should be_true
    end
    
    it "validates length in range" do
      password = RangePassword.new(password: "ab")
      password.valid?.should be_false
      
      password.password = "abcdef"
      password.valid?.should be_true
      
      password.password = "a" * 21
      password.valid?.should be_false
    end
  end
  
  describe "validates_confirmation_of" do
    it "validates field confirmation" do
      account = ConfirmAccount.new(email: "user@example.com")
      account.email_confirmation = "different@example.com"
      account.valid?.should be_false
      account.errors.first.message.should contain("doesn't match confirmation")
      
      account.email_confirmation = "user@example.com"
      account.valid?.should be_true
    end
    
    it "allows nil confirmation" do
      account = ConfirmAccount.new(email: "user@example.com")
      account.email_confirmation = nil
      account.valid?.should be_true
    end
  end
  
  describe "validates_acceptance_of" do
    it "validates acceptance" do
      signup = AcceptanceSignup.new
      signup.valid?.should be_false
      signup.errors.first.message.should contain("must be accepted")
      
      signup.terms_of_service = "1"
      signup.valid?.should be_true
      
      # Also accepts other truthy values
      signup.terms_of_service = "true"
      signup.valid?.should be_true
      
      signup.terms_of_service = "yes"
      signup.valid?.should be_true
    end
    
    it "rejects non-accepted values" do
      signup = AcceptanceSignup.new
      signup.terms_of_service = "0"
      signup.valid?.should be_false
      
      signup.terms_of_service = "false"
      signup.valid?.should be_false
    end
  end
  
  describe "validates_inclusion_of" do
    it "validates value is in list" do
      subscription = InclusionSubscription.new(plan: "basic")
      subscription.valid?.should be_true
      
      subscription.plan = "ultra"
      subscription.valid?.should be_false
      subscription.errors.first.message.should contain("is not included in the list")
    end
  end
  
  describe "validates_exclusion_of" do
    it "validates value is not in list" do
      user = ExclusionUser.new(username: "admin")
      user.valid?.should be_false
      user.errors.first.message.should contain("is reserved")
      
      user.username = "john"
      user.valid?.should be_true
    end
  end
  
  describe "validates_associated" do
    it "validates associated records" do
      order = AssociatedOrder.create!(number: "ORD-001")
      item1 = AssociatedItem.new(name: "", order_id: order.id) # Invalid - empty name
      item2 = AssociatedItem.new(name: "Widget", order_id: order.id) # Valid
      
      order.items = [item1, item2]
      order.valid?.should be_false
      order.errors.first.message.should contain("is invalid")
      
      item1.name = "Gadget"
      order.errors.clear
      order.valid?.should be_true
    end
  end
  
  describe "multiple validators" do
    it "runs all validators and collects all errors" do
      profile = ComplexProfile.new(
        username: "ab",  # Too short
        email: "invalid", # Invalid format
        age: 150,  # Too high
        bio: "a" * 501  # Too long
      )
      
      profile.valid?.should be_false
      profile.errors.size.should eq(4)
      
      error_messages = profile.errors.map(&.message)
      error_messages.should contain("must be at least 3 characters")
      error_messages.should contain("is not a valid email")
      error_messages.should contain("must be less than 120")
      error_messages.should contain("must be at most 500 characters")
    end
  end
end

# Test models
class NumericProduct < Granite::Base
  connection sqlite
  table numeric_products
  
  column id : Int64, primary: true
  column price : Float64?
  column quantity : Int32?
  
  validates_numericality_of :price, greater_than: 0
  validates_numericality_of :quantity, only_integer: true
end

class NumericScore < Granite::Base
  connection sqlite
  table numeric_scores
  
  column id : Int64, primary: true
  column even_score : Int32
  column odd_score : Int32
  
  validates_numericality_of :even_score, even: true
  validates_numericality_of :odd_score, odd: true
end

class ConditionalOrder < Granite::Base
  connection sqlite
  table conditional_orders
  
  column id : Int64, primary: true
  column status : String
  column total : Float64?
  
  validates_numericality_of :total, greater_than: 0, if: :completed?
  
  def completed?
    status == "completed"
  end
end

class FormatUser < Granite::Base
  connection sqlite
  table format_users
  
  column id : Int64, primary: true
  column username : String
  column phone : String
  
  validates_format_of :phone, with: /\A\d{3}-\d{3}-\d{4}\z/
  validates_format_of :username, without: /\A(admin|root|superuser)\z/, message: "is reserved"
end

class EmailContact < Granite::Base
  connection sqlite
  table email_contacts
  
  column id : Int64, primary: true
  column email : String
  
  validates_email :email
end

class UrlLink < Granite::Base
  connection sqlite
  table url_links
  
  column id : Int64, primary: true
  column url : String
  
  validates_url :url
end

class LengthPost < Granite::Base
  connection sqlite
  table length_posts
  
  column id : Int64, primary: true
  column title : String
  column body : String
  
  validates_length_of :title, minimum: 3, maximum: 20
  validates_length_of :body, minimum: 10, allow_blank: true
end

class ExactLengthCode < Granite::Base
  connection sqlite
  table exact_length_codes
  
  column id : Int64, primary: true
  column code : String
  
  validates_length_of :code, is: 4
end

class RangePassword < Granite::Base
  connection sqlite
  table range_passwords
  
  column id : Int64, primary: true
  column password : String
  
  validates_length_of :password, in: 6..20
end

class ConfirmAccount < Granite::Base
  connection sqlite
  table confirm_accounts
  
  column id : Int64, primary: true
  column email : String
  
  validates_confirmation_of :email
end

class AcceptanceSignup < Granite::Base
  connection sqlite
  table acceptance_signups
  
  column id : Int64, primary: true
  
  validates_acceptance_of :terms_of_service
end

class InclusionSubscription < Granite::Base
  connection sqlite
  table inclusion_subscriptions
  
  column id : Int64, primary: true
  column plan : String
  
  validates_inclusion_of :plan, in: ["basic", "premium", "enterprise"]
end

class ExclusionUser < Granite::Base
  connection sqlite
  table exclusion_users
  
  column id : Int64, primary: true
  column username : String
  
  validates_exclusion_of :username, in: ["admin", "root", "superuser"]
end

class AssociatedOrder < Granite::Base
  connection sqlite
  table associated_orders
  
  column id : Int64, primary: true
  column number : String
  
  has_many :items, class_name: AssociatedItem, foreign_key: :order_id
  
  validates_associated :items
end

class AssociatedItem < Granite::Base
  connection sqlite
  table associated_items
  
  column id : Int64, primary: true
  column name : String
  column order_id : Int64?
  
  validate :name, "can't be blank" do |item|
    !item.name.to_s.blank?
  end
end

class ComplexProfile < Granite::Base
  connection sqlite
  table complex_profiles
  
  column id : Int64, primary: true
  column username : String
  column email : String
  column age : Int32
  column bio : String
  
  validates_length_of :username, minimum: 3
  validates_email :email
  validates_numericality_of :age, less_than: 120
  validates_length_of :bio, maximum: 500
end