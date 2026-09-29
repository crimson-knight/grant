require "../../spec_helper"
require "../../../src/grant/encryption"

class FilterEncAccount < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table filter_enc_accounts

  column id : Int64, primary: true
  column name : String?
  column api_token : String?
  encrypts email : String, deterministic: true
  encrypts :legacy_email
end

FilterEncAccount.migrator.drop_and_create

def filter_enc_capture(& : ->) : String
  backend = Log::MemoryBackend.new
  ::Log.builder.bind("grant.sql", Log::Severity::Debug, backend)
  begin
    yield
  ensure
    ::Log.builder.bind("grant.sql", Log::Severity::None, backend)
  end
  backend.entries.map(&.message).join("\n")
end

describe "Grant::Encryption SQL log and inspect filtering" do
  after_all do
    Grant::Encryption::KeyProvider.primary_key = nil
    Grant::Encryption::KeyProvider.deterministic_key = nil
    Grant::Encryption::KeyProvider.key_derivation_salt = Grant::Encryption::KeyProvider::DEFAULT_SALT
  end

  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
      config.deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
      config.key_derivation_salt = "filter-salt"
    end
    FilterEncAccount.migrator.drop_and_create
  end

  before_each do
    FilterEncAccount.clear
    Grant.settings.filter_attributes = [] of String | Regex
    Grant::Encryption::LogFilter.track(FilterEncAccount)
  end

  after_all { Grant.settings.filter_attributes = [] of String | Regex }

  it "redacts bound values of encrypted columns in inserts, selects and updates" do
    log = filter_enc_capture do
      Grant::Encryption.without_encryption do
        account = FilterEncAccount.create!(name: "Visible Name", email: "plain-secret@example.com", legacy_email: "legacy-secret")
        FilterEncAccount.where(email: "plain-secret@example.com").select
        account.update!(email: "changed-secret@example.com")
      end
    end

    log.should contain("[FILTERED]")
    log.should_not contain("plain-secret")
    log.should_not contain("changed-secret")
    log.should_not contain("legacy-secret")
    log.should contain("Visible Name")
  end

  it "redacts ciphertext binds of where(email:) too and leaves other columns readable" do
    FilterEncAccount.create!(name: "Ada", email: "ada@example.com")
    ciphertext = FilterEncAccount.email_encrypted_attribute.seal("ada@example.com")

    log = filter_enc_capture do
      FilterEncAccount.where(name: "Ada", email: "ada@example.com").select
      FilterEncAccount.where(email: ["ada@example.com", "bob@example.com"]).select
    end

    log.should_not contain(ciphertext)
    log.should contain("Ada")
    log.should contain("[FILTERED]")
  end

  it "redacts columns matched by Grant.settings.filter_attributes and model filters" do
    Grant.settings.filter_attributes = ["token"] of String | Regex
    log = filter_enc_capture do
      FilterEncAccount.create!(name: "Grace", api_token: "tok-123456")
      FilterEncAccount.where(api_token: "tok-123456").select
    end
    log.should_not contain("tok-123456")
    log.should contain("Grace")
  end

  it "precomputes the filtered column set instead of matching per bind" do
    Grant::Encryption::LogFilter.filtered_column?("email").should be_true
    Grant::Encryption::LogFilter.filtered_column?("legacy_email_encrypted").should be_true
    Grant::Encryption::LogFilter.filtered_column?("name").should be_false
  end

  it "keeps inspect masked for both storage forms" do
    account = FilterEncAccount.new(name: "Ada", email: "ada@example.com", legacy_email: "old@example.com")
    text = account.inspect
    text.should contain("name: \"Ada\"")
    text.should_not contain("ada@example.com")
    text.should_not contain("old@example.com")
    text.should contain("email: [FILTERED]")
    text.should contain("legacy_email_encrypted: [FILTERED]")
  end
end
