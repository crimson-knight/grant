require "../spec_helper"

{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}

  class TokenForTestModel < Grant::Base
    connection {{ adapter_literal }}
    table token_for_test_models
    
    include Grant::TokenFor
    
    generates_token_for :password_reset, expires_in: 15.minutes do
      password_salt
    end
    
    generates_token_for :email_confirmation, expires_in: 24.hours do
      email
    end
    
    column id : Int64, primary: true
    column name : String?
    column email : String?
    column password_salt : String?
    timestamps
  end
{% end %}

describe Grant::TokenFor do
  before_each do
    ENV["GRANT_SIGNING_SECRET"] = "test_secret"
  end
  
  after_each do
    ENV.delete("GRANT_SIGNING_SECRET")
  end
  
  describe "generates_token_for" do
    it "generates tokens with dynamic data" do
      model = TokenForTestModel.create(
        name: "Test User",
        email: "test@example.com",
        password_salt: "salt123"
      )
      
      token = model.generate_token_for(:password_reset)
      token.should_not be_nil
      token.should_not be_empty
    end
    
    it "finds by token when data matches" do
      model = TokenForTestModel.create(
        name: "Test User",
        email: "test@example.com",
        password_salt: "salt123"
      )
      
      token = model.generate_token_for(:password_reset)
      
      found = TokenForTestModel.find_by_token_for(:password_reset, token)
      found.should_not be_nil
      found.not_nil!.id.should eq(model.id)
    end
    
    it "returns nil when data changes" do
      model = TokenForTestModel.create(
        name: "Test User",
        email: "test@example.com",
        password_salt: "salt123"
      )
      
      token = model.generate_token_for(:password_reset)
      
      # Change the password salt
      model.password_salt = "new_salt"
      model.save
      
      found = TokenForTestModel.find_by_token_for(:password_reset, token)
      found.should be_nil
    end
    
    it "returns nil for expired tokens" do
      model = TokenForTestModel.create(
        name: "Test User",
        email: "test@example.com",
        password_salt: "salt123"
      )
      
      # Create an expired token
      definition = TokenForTestModel.token_for_definitions[:password_reset]
      unique_data = "salt123"
      
      payload = {
        "id" => model.id.to_s,
        "purpose" => "password_reset",
        "data" => unique_data,
        "expires_at" => (Time.utc - 1.hour).to_unix
      }
      
      expired_token = TokenForTestModel.generate_token_for_payload(payload)
      
      found = TokenForTestModel.find_by_token_for(:password_reset, expired_token)
      found.should be_nil
    end
    
    it "handles email confirmation tokens" do
      model = TokenForTestModel.create(
        name: "Test User",
        email: "test@example.com",
        password_salt: "salt123"
      )
      
      token = model.generate_token_for(:email_confirmation)
      
      # Should find when email hasn't changed
      found = TokenForTestModel.find_by_token_for(:email_confirmation, token)
      found.should_not be_nil
      
      # Should not find when email changes
      model.email = "new@example.com"
      model.save
      
      found = TokenForTestModel.find_by_token_for(:email_confirmation, token)
      found.should be_nil
    end
    
    it "raises error for undefined token purpose" do
      model = TokenForTestModel.create(
        name: "Test User",
        email: "test@example.com",
        password_salt: "salt123"
      )
      
      expect_raises(Exception, "No token_for definition for purpose: undefined_purpose") do
        model.generate_token_for(:undefined_purpose)
      end
    end
  end
end

# Setup table
adapter = Grant::Connections[CURRENT_ADAPTER]
if adapter.is_a?(Grant::Adapter::Base)
  adapter.exec("DROP TABLE IF EXISTS token_for_test_models")
  
  case CURRENT_ADAPTER
  when "sqlite"
    adapter.exec(<<-SQL)
      CREATE TABLE token_for_test_models (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        email TEXT,
        password_salt TEXT,
        created_at TEXT,
        updated_at TEXT
      )
    SQL
  when "pg"
    adapter.exec(<<-SQL)
      CREATE TABLE token_for_test_models (
        id BIGSERIAL PRIMARY KEY,
        name VARCHAR,
        email VARCHAR,
        password_salt VARCHAR,
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
  when "mysql"
    adapter.exec(<<-SQL)
      CREATE TABLE token_for_test_models (
        id BIGINT PRIMARY KEY AUTO_INCREMENT,
        name VARCHAR(255),
        email VARCHAR(255),
        password_salt VARCHAR(255),
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
  end
end