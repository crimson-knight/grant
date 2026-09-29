require "../../spec_helper"
require "../../../src/grant/encryption"

PREV_ENC_KEY_NEW = Base64.strict_encode("prev_current_key_32_bytes_long!!".to_slice)
PREV_ENC_DET_NEW = Base64.strict_encode("prev_current_det_32_bytes_long!!".to_slice)
PREV_ENC_DET_MID = Base64.strict_encode("prev_middle_det_32_bytes_long!!!".to_slice)
PREV_ENC_DET_OLD = Base64.strict_encode("prev_oldest_det_32_bytes_long!!!".to_slice)
PREV_ENC_KEY_OLD = Base64.strict_encode("prev_old_key_32_bytes_long!!!!!!".to_slice)
PREV_ENC_SALT    = "previous-schemes-salt"

class PrevEncPerson < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table prev_enc_people

  column id : Int64, primary: true
  # Newest previous scheme first.
  encrypts ssn : String, deterministic: true, previous: [
    {deterministic: true, key: PREV_ENC_DET_MID},
    {deterministic: true, key: PREV_ENC_DET_OLD},
  ]
  # Was deterministic once; only the key history is configured globally.
  encrypts diary : String
end

PrevEncPerson.migrator.drop_and_create

describe "Grant::Encryption previous: schemes" do
  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = PREV_ENC_KEY_NEW
      config.deterministic_key = PREV_ENC_DET_NEW
      config.key_derivation_salt = PREV_ENC_SALT
    end
    PrevEncPerson.migrator.drop_and_create
  end

  after_all do
    Grant::Encryption::KeyProvider.previous_primary_keys = [] of Bytes
    Grant::Encryption::KeyProvider.previous_deterministic_keys = [] of Bytes
    Grant::Encryption::KeyProvider.primary_key = nil
    Grant::Encryption::KeyProvider.deterministic_key = nil
    Grant::Encryption::KeyProvider.key_derivation_salt = Grant::Encryption::KeyProvider::DEFAULT_SALT
  end

  before_each { PrevEncPerson.clear }

  it "reads data written under an older scheme and writes new data with the current one" do
    attribute = PrevEncPerson.ssn_encrypted_attribute

    older = Grant::Encryption.with_context(deterministic_key: PREV_ENC_DET_OLD) { PrevEncPerson.create!(ssn: "111-11-1111") }
    middle = Grant::Encryption.with_context(deterministic_key: PREV_ENC_DET_MID) { PrevEncPerson.create!(ssn: "222-22-2222") }
    current = PrevEncPerson.create!(ssn: "333-33-3333")

    PrevEncPerson.find!(older.id.not_nil!).ssn.should eq("111-11-1111")
    PrevEncPerson.find!(middle.id.not_nil!).ssn.should eq("222-22-2222")
    PrevEncPerson.find!(current.id.not_nil!).ssn.should eq("333-33-3333")

    raw = ->(id : Int64?) { PrevEncPerson.adapter.open { |db| db.query_one("SELECT ssn FROM prev_enc_people WHERE id = #{id}", as: String) } }
    attribute.open_with_index(raw.call(current.id)).should eq({"333-33-3333", 0})
    attribute.open_with_index(raw.call(middle.id)).should eq({"222-22-2222", 1})
    attribute.open_with_index(raw.call(older.id)).should eq({"111-11-1111", 2})

    # Rewriting the record moves it to the current keys.
    PrevEncPerson.find!(older.id.not_nil!).encrypt.should be_true
    attribute.open_with_index(raw.call(older.id)).should eq({"111-11-1111", 0})
  end

  it "matches lookups against the current scheme only, until data is rewritten" do
    older = Grant::Encryption.with_context(deterministic_key: PREV_ENC_DET_OLD) { PrevEncPerson.create!(ssn: "444-44-4444") }
    PrevEncPerson.where(ssn: "444-44-4444").count.should eq(0)
    older.encrypt
    PrevEncPerson.where(ssn: "444-44-4444").count.should eq(1)
  end

  it "keeps a history of primary keys with Config.primary_keys" do
    written = Grant::Encryption.with_context(primary_key: PREV_ENC_KEY_OLD) { PrevEncPerson.create!(diary: "dear diary") }
    expect_raises(Grant::Encryption::Cipher::DecryptionError) { PrevEncPerson.find!(written.id.not_nil!) }

    Grant::Encryption::Config.primary_keys = [PREV_ENC_KEY_NEW, PREV_ENC_KEY_OLD]
    begin
      PrevEncPerson.find!(written.id.not_nil!).diary.should eq("dear diary")
      fresh = PrevEncPerson.create!(diary: "new entry")
      Grant::Encryption.with_context(primary_key: PREV_ENC_KEY_NEW) { PrevEncPerson.find!(fresh.id.not_nil!).diary.should eq("new entry") }
    ensure
      Grant::Encryption::KeyProvider.previous_primary_keys = [] of Bytes
    end
  end

  it "raises when no scheme can decrypt the value" do
    stranger = Grant::Encryption.with_context(deterministic_key: Base64.strict_encode("stranger_det_32_bytes_long!!!!!!".to_slice)) { PrevEncPerson.create!(ssn: "555-55-5555") }
    expect_raises(Grant::Encryption::Cipher::DecryptionError) { PrevEncPerson.find!(stranger.id.not_nil!) }
  end
end
