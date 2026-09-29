require "../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SecureUser < Grant::Base
    connection {{ adapter_literal }}
    table secure_users
    
    include Grant::SignedId
    include Grant::TokenFor
    
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
  before_all do
    SecureUser.migrator.drop_and_create
  end

  before_each do
    Grant::SignedId.configure { |c| c.secret = nil; c.previous_secrets = [] of String }
    ENV["GRANT_SIGNING_SECRET"] = "test_secret_key"
  end

  after_each do
    ENV.delete("GRANT_SIGNING_SECRET")
    Grant::SignedId.configure { |c| c.secret = nil; c.previous_secrets = [] of String }
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

    # A signed id and a token-for token are not interchangeable, even when the
    # purpose names match.
    SecureUser.find_by_token_for(:password_reset, reset_id).should be_nil
    SecureUser.find_signed(password_token, purpose: :password_reset).should be_nil

    # Test token invalidation on data change
    user.password_salt = "new_salt"
    user.save

    invalid_found = SecureUser.find_by_token_for(:password_reset, password_token)
    invalid_found.should be_nil

    # Test regenerating secure tokens
    old_auth_token = user.auth_token
    user.regenerate_auth_token.should be_true

    user.auth_token.should_not eq(old_auth_token)
    SecureUser.find!(user.id).auth_token.should eq(user.auth_token)
  end
end
