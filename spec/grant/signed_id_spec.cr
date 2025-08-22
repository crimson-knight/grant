require "../spec_helper"

{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}

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
  before_each do
    ENV["GRANT_SIGNING_SECRET"] = "test_secret"
  end
  
  after_each do
    ENV.delete("GRANT_SIGNING_SECRET")
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
      signed_id = model.signed_id(purpose: :password_reset)
      
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
        "id" => model.id.to_s,
        "purpose" => "password_reset",
        "expires_at" => (Time.utc - 1.hour).to_unix
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
    
    it "returns nil when signing secret changes" do
      model = SignedIdTestModel.create(name: "Test User")
      signed_id = model.signed_id(purpose: :password_reset)
      
      # Change the secret
      ENV["GRANT_SIGNING_SECRET"] = "different_secret"
      
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