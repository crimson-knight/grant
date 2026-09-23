require "../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SecureTokenTestModel < Grant::Base
    connection {{ adapter_literal }}
    table secure_token_test_models
    
    
    has_secure_token :auth_token
    has_secure_token :api_key, length: 36, alphabet: :hex
    
    column id : Int64, primary: true
    column name : String?
    timestamps
  end
{% end %}

describe Grant::SecureToken do
  before_all do
    SecureTokenTestModel.migrator.drop_and_create
  end

  describe "has_secure_token" do
    it "generates tokens automatically on create" do
      model = SecureTokenTestModel.new
      model.name = "Test User"

      model.auth_token.should be_nil
      model.api_key.should be_nil

      model.save

      model.auth_token.should_not be_nil
      model.auth_token.not_nil!.size.should eq(24)
      model.api_key.should_not be_nil
      model.api_key.not_nil!.size.should eq(36)
    end

    it "generates tokens with different alphabets" do
      model = SecureTokenTestModel.create(name: "Test")

      # Base58 token
      model.auth_token.not_nil!.should match(/^[123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]+$/)

      # Hex token
      model.api_key.not_nil!.should match(/^[0-9a-f]+$/)
    end

    it "regenerates tokens" do
      model = SecureTokenTestModel.create(name: "Test")

      original_token = model.auth_token
      original_api_key = model.api_key

      model.regenerate_auth_token
      model.regenerate_api_key

      model.auth_token.should_not eq(original_token)
      model.api_key.should_not eq(original_api_key)
    end

    it "doesn't regenerate existing tokens on create" do
      model = SecureTokenTestModel.new
      model.name = "Test"
      model.auth_token = "existing_token"

      model.save

      model.auth_token.should eq("existing_token")
    end
  end
end
