require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SignedIdOtherTestModel < Grant::Base
    connection {{ adapter_literal }}
    table signed_id_other_test_models

    include Grant::SignedId

    column id : Int64, primary: true
    column name : String?
  end

  class SignedIdTestModel < Grant::Base
    connection {{ adapter_literal }}
    table signed_id_test_models
    
    include Grant::SignedId
    
    column id : Int64, primary: true
    column name : String?
    timestamps
  end
{% end %}

describe Grant::SignedId do
  before_all do
    SignedIdTestModel.migrator.drop_and_create
    SignedIdOtherTestModel.migrator.drop_and_create
  end

  before_each do
    Grant::SignedId.configure { |c| c.secret = nil; c.previous_secrets = [] of String }
    ENV["GRANT_SIGNING_SECRET"] = "test_secret"
  end

  after_each do
    ENV.delete("GRANT_SIGNING_SECRET")
    Grant::SignedId.configure { |c| c.secret = nil; c.previous_secrets = [] of String }
  end

  describe "signed_id" do
    it "generates signed IDs with purpose" do
      model = SignedIdTestModel.create(name: "Test User")

      signed_id = model.signed_id(purpose: :password_reset)
      signed_id.should_not be_nil
      signed_id.should_not be_empty
    end

    it "generates signed IDs with expiration" do
      model = SignedIdTestModel.create(name: "Test User")

      signed_id = model.signed_id(purpose: :password_reset, expires_in: 1.hour)
      signed_id.should_not be_nil
    end

    it "finds by signed ID with correct purpose" do
      model = SignedIdTestModel.create(name: "Test User")
      model.id.should_not be_nil
      signed_id = model.signed_id(purpose: :password_reset)
      payload = SignedIdTestModel.verify_signed_token(signed_id)
      payload.should_not be_nil
      payload.not_nil!["id"].as_s.should eq(model.id.to_s)
      SignedIdTestModel.find(model.id).should_not be_nil

      found = SignedIdTestModel.find_signed(signed_id, purpose: :password_reset)
      found.should_not be_nil
      found.not_nil!.id.should eq(model.id)
    end

    it "returns nil for wrong purpose" do
      model = SignedIdTestModel.create(name: "Test User")
      signed_id = model.signed_id(purpose: :password_reset)

      found = SignedIdTestModel.find_signed(signed_id, purpose: :email_confirmation)
      found.should be_nil
    end

    it "returns nil for expired tokens" do
      model = SignedIdTestModel.create(name: "Test User")

      # Create an expired token by manipulating the payload
      payload = {
        "id"         => model.id.to_s,
        "purpose"    => "password_reset",
        "expires_at" => (Time.utc - 1.hour).to_unix,
      }

      expired_token = SignedIdTestModel.generate_signed_token(payload)

      found = SignedIdTestModel.find_signed(expired_token, purpose: :password_reset)
      found.should be_nil
    end

    it "returns nil for tampered tokens" do
      model = SignedIdTestModel.create(name: "Test User")
      signed_id = model.signed_id(purpose: :password_reset)

      # Tamper with the token
      tampered = signed_id + "tampered"

      found = SignedIdTestModel.find_signed(tampered, purpose: :password_reset)
      found.should be_nil
    end

    it "defaults the purpose to the table name" do
      model = SignedIdTestModel.create(name: "T")
      token = model.signed_id
      SignedIdTestModel.find_signed(token).try(&.id).should eq(model.id)
      SignedIdTestModel.find_signed(token, purpose: :signed_id_test_models).should_not be_nil
      SignedIdTestModel.find_signed(token, purpose: :other).should be_nil
    end

    it "restores the integer id so the lookup works on the active adapter" do
      model = SignedIdTestModel.create(name: "T")
      SignedIdTestModel.verify_signed_token(model.signed_id).not_nil!["id"].as_s.should eq(model.id.to_s)
      SignedIdTestModel.find_signed(model.signed_id).not_nil!.id.should eq(model.id)
    end

    it "supports absolute expires_at:" do
      model = SignedIdTestModel.create(name: "T")
      fresh = model.signed_id(purpose: :x, expires_at: Time.utc + 1.hour)
      stale = model.signed_id(purpose: :x, expires_at: Time.utc - 1.hour)
      SignedIdTestModel.find_signed(fresh, purpose: :x).should_not be_nil
      SignedIdTestModel.find_signed(stale, purpose: :x).should be_nil
      expect_raises(ArgumentError) { model.signed_id(purpose: :x, expires_in: 1.hour, expires_at: Time.utc) }
    end

    it "find_signed! returns the record or raises Grant::InvalidSignedId" do
      model = SignedIdTestModel.create(name: "T")
      token = model.signed_id(purpose: :reset)
      SignedIdTestModel.find_signed!(token, purpose: :reset).id.should eq(model.id)

      expect_raises(Grant::InvalidSignedId) { SignedIdTestModel.find_signed!(token, purpose: :other) }
      expect_raises(Grant::InvalidSignedId) { SignedIdTestModel.find_signed!(token + "tampered", purpose: :reset) }
      expect_raises(Grant::InvalidSignedId) { SignedIdTestModel.find_signed!("not base64 !!", purpose: :reset) }
      expired = model.signed_id(purpose: :reset, expires_at: Time.utc - 1.minute)
      expect_raises(Grant::InvalidSignedId) { SignedIdTestModel.find_signed!(expired, purpose: :reset) }

      Grant::SignedId.configure { |c| c.secret = "different_secret" }
      expect_raises(Grant::InvalidSignedId) { SignedIdTestModel.find_signed!(token, purpose: :reset) }
      Grant::InvalidSignedId.new.should be_a(Grant::ErrorBase)
    end

    it "find_signed! raises RecordNotFound when the record is gone" do
      model = SignedIdTestModel.create(name: "T")
      token = model.signed_id(purpose: :reset)
      model.destroy
      expect_raises(Grant::RecordNotFound) { SignedIdTestModel.find_signed!(token, purpose: :reset) }
      SignedIdTestModel.find_signed(token, purpose: :reset).should be_nil
    end

    it "uses a configured secret and does not swallow a missing one" do
      model = SignedIdTestModel.create(name: "T")
      token = model.signed_id(purpose: :x)
      ENV.delete("GRANT_SIGNING_SECRET")
      Grant::SignedId.configure { |c| c.secret = nil }
      expect_raises(Grant::MissingSigningSecret) { SignedIdTestModel.find_signed(token, purpose: :x) }
      begin
        Grant::SignedId.configure { |c| c.secret = "configured" }
        configured = model.signed_id(purpose: :x)
        SignedIdTestModel.find_signed(configured, purpose: :x).should_not be_nil
        SignedIdTestModel.find_signed(token, purpose: :x).should be_nil
      ensure
        Grant::SignedId.configure { |c| c.secret = nil }
      end
    end

    it "reads the GRANT_SIGNING_SECRET fallback once, not per token" do
      model = SignedIdTestModel.create(name: "T")
      token = model.signed_id(purpose: :x)
      ENV["GRANT_SIGNING_SECRET"] = "changed_after_first_use"
      SignedIdTestModel.find_signed(token, purpose: :x).should_not be_nil
    end

    it "does not redeem a token minted for another model with the same id and purpose" do
      model = SignedIdTestModel.create(name: "T")
      other = SignedIdOtherTestModel.create(id: model.id, name: "O")
      other.id.should eq(model.id)

      token = model.signed_id(purpose: :password_reset)
      SignedIdOtherTestModel.find_signed(token, purpose: :password_reset).should be_nil
      expect_raises(Grant::InvalidSignedId) { SignedIdOtherTestModel.find_signed!(token, purpose: :password_reset) }
      SignedIdTestModel.find_signed(token, purpose: :password_reset).should_not be_nil
    end

    it "returns nil when signing secret changes" do
      model = SignedIdTestModel.create(name: "Test User")
      signed_id = model.signed_id(purpose: :password_reset)

      # Change the secret
      Grant::SignedId.configure { |c| c.secret = "different_secret" }

      found = SignedIdTestModel.find_signed(signed_id, purpose: :password_reset)
      found.should be_nil
    end
  end
end

# Setup table
adapter = Grant::Connections[CURRENT_ADAPTER]
if adapter.is_a?(Grant::Adapter::Base)
  adapter.exec("DROP TABLE IF EXISTS signed_id_test_models")

  case CURRENT_ADAPTER
  when "sqlite"
    adapter.exec(<<-SQL)
      CREATE TABLE signed_id_test_models (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        created_at TEXT,
        updated_at TEXT
      )
    SQL
  when "pg"
    adapter.exec(<<-SQL)
      CREATE TABLE signed_id_test_models (
        id BIGSERIAL PRIMARY KEY,
        name VARCHAR,
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
  when "mysql"
    adapter.exec(<<-SQL)
      CREATE TABLE signed_id_test_models (
        id BIGINT PRIMARY KEY AUTO_INCREMENT,
        name VARCHAR(255),
        created_at TIMESTAMP,
        updated_at TIMESTAMP
      )
    SQL
  end
end
