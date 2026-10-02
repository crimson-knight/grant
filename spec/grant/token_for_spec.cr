require "../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

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
  before_all do
    TokenForTestModel.migrator.drop_and_create
  end

  before_each do
    Grant::TokenFor.configure { |c| c.secret = nil; c.previous_secrets = [] of String }
    ENV["GRANT_SIGNING_SECRET"] = "test_secret"
  end

  after_each do
    ENV.delete("GRANT_SIGNING_SECRET")
    Grant::TokenFor.configure { |c| c.secret = nil; c.previous_secrets = [] of String }
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
      TokenForTestModel.token_for_definitions[:password_reset]
      unique_data = "salt123"

      payload = {
        "id"         => model.id.to_s,
        "purpose"    => "password_reset",
        "data"       => unique_data,
        "expires_at" => (Time.utc - 1.hour).to_unix,
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

    it "find_by_token_for! returns the record for a valid token" do
      model = TokenForTestModel.create(name: "T", email: "a@b.c", password_salt: "s1")
      token = model.generate_token_for(:password_reset)
      TokenForTestModel.find_by_token_for!(:password_reset, token).id.should eq(model.id)
    end

    it "find_by_token_for! raises Grant::InvalidToken for tampered, wrong purpose, expired and stale tokens" do
      model = TokenForTestModel.create(name: "T", email: "a@b.c", password_salt: "s1")
      token = model.generate_token_for(:password_reset)

      expect_raises(Grant::InvalidToken) { TokenForTestModel.find_by_token_for!(:password_reset, token + "x") }
      expect_raises(Grant::InvalidToken) { TokenForTestModel.find_by_token_for!(:password_reset, "garbage") }
      expect_raises(Grant::InvalidToken) { TokenForTestModel.find_by_token_for!(:email_confirmation, token) }

      expired = TokenForTestModel.generate_token_for_payload({
        "id" => model.id.to_s, "purpose" => "password_reset", "data" => "s1",
        "expires_at" => (Time.utc - 1.hour).to_unix,
      })
      expect_raises(Grant::InvalidToken) { TokenForTestModel.find_by_token_for!(:password_reset, expired) }

      model.update!(password_salt: "s2")
      expect_raises(Grant::InvalidToken) { TokenForTestModel.find_by_token_for!(:password_reset, token) }
      Grant::InvalidToken.new.should be_a(Grant::ErrorBase)
    end

    it "find_by_token_for! raises RecordNotFound when the record is gone" do
      model = TokenForTestModel.create(name: "T", email: "a@b.c", password_salt: "s1")
      token = model.generate_token_for(:password_reset)
      model.destroy
      expect_raises(Grant::RecordNotFound) { TokenForTestModel.find_by_token_for!(:password_reset, token) }
      TokenForTestModel.find_by_token_for(:password_reset, token).should be_nil
    end

    it "uses the secret from Grant::TokenFor.configure, ignoring ENV" do
      ENV.delete("GRANT_SIGNING_SECRET")
      begin
        Grant::TokenFor.configure(&.secret=("configured"))
        model = TokenForTestModel.create(name: "T", email: "a@b.c", password_salt: "s1")
        token = model.generate_token_for(:password_reset)
        TokenForTestModel.find_by_token_for(:password_reset, token).should_not be_nil

        Grant::TokenFor.configure(&.secret=("other"))
        TokenForTestModel.find_by_token_for(:password_reset, token).should be_nil
      ensure
        Grant::TokenFor.configure { |c| c.secret = nil; c.previous_secrets = [] of String }
      end
    end

    it "accepts tokens signed with a previous secret after rotation" do
      Grant::TokenFor.configure(&.secret=("old"))
      model = TokenForTestModel.create(name: "T", email: "a@b.c", password_salt: "s1")
      token = model.generate_token_for(:password_reset)

      Grant::TokenFor.configure { |c| c.secret = "new"; c.previous_secrets = ["old"] }
      TokenForTestModel.find_by_token_for(:password_reset, token).should_not be_nil
      TokenForTestModel.find_by_token_for(:password_reset, model.generate_token_for(:password_reset)).should_not be_nil

      Grant::TokenFor.configure(&.previous_secrets=([] of String))
      TokenForTestModel.find_by_token_for(:password_reset, token).should be_nil
    ensure
      Grant::TokenFor.configure { |c| c.secret = nil; c.previous_secrets = [] of String }
    end

    it "raises MissingSigningSecret instead of swallowing it" do
      ENV.delete("GRANT_SIGNING_SECRET")
      model = TokenForTestModel.create(name: "T", email: "a@b.c", password_salt: "s1")
      expect_raises(Grant::MissingSigningSecret) { model.generate_token_for(:password_reset) }
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
token_for_adapter = Grant::Connections[CURRENT_ADAPTER]
if token_for_adapter.is_a?(Grant::Adapter::Base)
  token_for_adapter.open(&.exec("DROP TABLE IF EXISTS token_for_test_models"))

  case CURRENT_ADAPTER
  when "sqlite"
    token_for_adapter.open(&.exec(<<-SQL))
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
    token_for_adapter.open(&.exec(<<-SQL))
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
    token_for_adapter.open(&.exec(<<-SQL))
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
