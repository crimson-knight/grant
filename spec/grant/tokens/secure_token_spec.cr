require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SecureTokenTestModel < Grant::Base
    connection {{ adapter_literal }}
    table secure_token_test_models
    
    
    has_secure_token :auth_token
    has_secure_token :api_key, length: 36, alphabet: :hex
    has_secure_token :invite_code, length: 10, on: :initialize
    
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

    it "regenerate_<name> persists the new token" do
      model = SecureTokenTestModel.create(name: "Test")
      original = model.auth_token

      model.regenerate_auth_token.should be_true

      model.auth_token.should_not eq(original)
      SecureTokenTestModel.find!(model.id).auth_token.should eq(model.auth_token)
    end

    it "regenerate_<name>! persists and returns true" do
      model = SecureTokenTestModel.create(name: "Test")
      original = model.api_key

      model.regenerate_api_key!.should be_true

      reloaded = SecureTokenTestModel.find!(model.id)
      reloaded.api_key.should eq(model.api_key)
      reloaded.api_key.should_not eq(original)
      reloaded.api_key.not_nil!.size.should eq(36)
    end

    it "assign_new_<name> changes the value in memory only" do
      model = SecureTokenTestModel.create(name: "Test")
      stored = model.auth_token

      fresh = model.assign_new_auth_token

      model.auth_token.should eq(fresh)
      fresh.should_not eq(stored)
      SecureTokenTestModel.find!(model.id).auth_token.should eq(stored)
    end

    it "on: :initialize fills the token as soon as the record is built" do
      model = SecureTokenTestModel.new(name: "Test")
      code = model.invite_code
      code.should_not be_nil
      code.not_nil!.size.should eq(10)

      model.save
      model.invite_code.should eq(code)
      SecureTokenTestModel.find!(model.id).invite_code.should eq(code)
    end

    it "on: :initialize keeps an assigned value and does not touch loaded records" do
      model = SecureTokenTestModel.create(name: "Test")
      code = model.invite_code
      SecureTokenTestModel.find!(model.id).invite_code.should eq(code)

      SecureTokenTestModel.create(name: "Kept", invite_code: "mine").invite_code.should eq("mine")
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
