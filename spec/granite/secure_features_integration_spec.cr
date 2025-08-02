require "../spec_helper"

{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}

  class SecureUser < Granite::Base
    connection {{ adapter_literal }}
    table secure_users
    
    extend Granite::SecureToken
    include Granite::SignedId
    include Granite::TokenFor
    
    # Define secure tokens
    has_secure_token :auth_token
    has_secure_token :password_reset_token, length: 36
    has_secure_token :api_key, alphabet: :hex, length: 32
    
    # Define token_for generators
    generates_token_for :password_reset, expires_in: 15.minutes do
      password_salt
    end
    
    generates_token_for :email_confirmation, expires_in: 24.hours do
      email
    end
    
    column id : Int64, primary: true
    column name : String?
    column email : String?
    column password_digest : String?
    column password_salt : String?
    timestamps
  end
{% end %}

describe "Secure Features Integration" do
  before_each do
    ENV["GRANITE_SIGNING_SECRET"] = "test_secret_key"
  end
  
  after_each do
    ENV.delete("GRANITE_SIGNING_SECRET")
  end
  
  it "works with all security features together" do
    # Create a user with automatic token generation
    user = SecureUser.create(
      name: "John Doe",
      email: "john@example.com",
      password_digest: "hashed_password",
      password_salt: "random_salt"
    )
    
    # Verify secure tokens were generated
    user.auth_token.should_not be_nil
    user.auth_token.not_nil!.size.should eq(24)
    user.password_reset_token.should_not be_nil
    user.password_reset_token.not_nil!.size.should eq(36)
    user.api_key.should_not be_nil
    user.api_key.not_nil!.size.should eq(32)
    
    # Test signed IDs
    login_id = user.signed_id(purpose: :login)
    found_by_signed = SecureUser.find_signed(login_id, purpose: :login)
    found_by_signed.should_not be_nil
    found_by_signed.not_nil!.id.should eq(user.id)
    
    # Test signed ID with expiration
    reset_id = user.signed_id(purpose: :password_reset, expires_in: 15.minutes)
    found_for_reset = SecureUser.find_signed(reset_id, purpose: :password_reset)
    found_for_reset.should_not be_nil
    
    # Test token_for
    password_token = user.generate_token_for(:password_reset)
    found_by_token = SecureUser.find_by_token_for(:password_reset, password_token)
    found_by_token.should_not be_nil
    found_by_token.not_nil!.id.should eq(user.id)
    
    # Test token invalidation on data change
    user.password_salt = "new_salt"
    user.save
    
    invalid_found = SecureUser.find_by_token_for(:password_reset, password_token)
    invalid_found.should be_nil
    
    # Test regenerating secure tokens
    old_auth_token = user.auth_token
    user.regenerate_auth_token
    user.save
    
    user.auth_token.should_not eq(old_auth_token)
  end
end

# Setup table
adapter = Granite::Connections[CURRENT_ADAPTER]
if adapter.is_a?(Granite::Adapter::Base)
  adapter.exec("DROP TABLE IF EXISTS secure_users")
  
  case CURRENT_ADAPTER
  when "sqlite"
    adapter.exec(<<-SQL)
      CREATE TABLE secure_users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        email TEXT,
        password_digest TEXT,
        password_salt TEXT,
        auth_token TEXT,
        password_reset_token TEXT,
        api_key TEXT,
        created_at TEXT,
        updated_at TEXT
      )
    SQL
  when "pg"
    adapter.exec(<<-SQL)
      CREATE TABLE secure_users (
        id BIGSERIAL PRIMARY KEY,
        name VARCHAR,
        email VARCHAR,
        password_digest VARCHAR,
        password_salt VARCHAR,
        auth_token VARCHAR,
        password_reset_token VARCHAR,
        api_key VARCHAR,
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
  when "mysql"
    adapter.exec(<<-SQL)
      CREATE TABLE secure_users (
        id BIGINT PRIMARY KEY AUTO_INCREMENT,
        name VARCHAR(255),
        email VARCHAR(255),
        password_digest VARCHAR(255),
        password_salt VARCHAR(255),
        auth_token VARCHAR(255),
        password_reset_token VARCHAR(255),
        api_key VARCHAR(255),
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
  end
end