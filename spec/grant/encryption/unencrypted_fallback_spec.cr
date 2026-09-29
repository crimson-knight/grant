require "../../spec_helper"
require "../../../src/grant/encryption"

class UnencNote < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table unenc_notes

  column id : Int64, primary: true
  encrypts note : String, support_unencrypted_data: true
  encrypts strict : String
  encrypts tag : String, deterministic: true, support_unencrypted_data: true
  encrypts :legacy_note, support_unencrypted_data: true
end

UnencNote.migrator.drop_and_create

def unenc_insert(column : String, value : String) : Int64
  UnencNote.adapter.open do |db|
    db.exec("INSERT INTO unenc_notes (#{column}) VALUES ('#{value}')")
    db.scalar("SELECT MAX(id) FROM unenc_notes").as(Int32 | Int64).to_i64
  end
end

describe "Grant::Encryption support_unencrypted_data" do
  after_all do
    Grant::Encryption::KeyProvider.primary_key = nil
    Grant::Encryption::KeyProvider.deterministic_key = nil
    Grant::Encryption::KeyProvider.key_derivation_salt = Grant::Encryption::KeyProvider::DEFAULT_SALT
  end

  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
      config.deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
      config.key_derivation_salt = "unencrypted-salt"
    end
    UnencNote.migrator.drop_and_create
  end

  after_all { Grant::Encryption::Config.support_unencrypted_data = false }

  before_each do
    Grant::Encryption::Config.support_unencrypted_data = false
    UnencNote.clear
  end

  describe "payload version check" do
    it "tells ciphertext from plaintext without decrypting" do
      cipher = Grant::Encryption::Cipher
      sealed = Base64.decode(UnencNote.note_encrypted_attribute.seal("hello world"))
      cipher.encrypted_payload?(sealed).should be_true
      cipher.encrypted_payload?("hello world".to_slice).should be_false
      cipher.encrypted_payload?(Bytes.empty).should be_false
      # Long enough, wrong version byte.
      broken = sealed.dup
      broken[0] = 0x7F_u8
      cipher.encrypted_payload?(broken).should be_false
    end

    it "does not use exceptions to decide (plaintext that is valid Base64 passes through)" do
      attribute = UnencNote.note_encrypted_attribute
      # "dGVzdA==" decodes to "test": valid Base64, not our payload.
      attribute.open_with_index("dGVzdA==").should eq({"dGVzdA==", -1})
      attribute.open_with_index("not base64 at all!").should eq({"not base64 at all!", -1})
    end
  end

  describe "per-attribute flag" do
    it "reads plaintext rows for attributes that opt in and ciphertext as usual" do
      plain_id = unenc_insert("note", "written before encryption")
      UnencNote.find!(plain_id).note.should eq("written before encryption")

      created = UnencNote.create!(note: "written after")
      UnencNote.find!(created.id.not_nil!).note.should eq("written after")
      raw = UnencNote.adapter.open { |db| db.query_one("SELECT note FROM unenc_notes WHERE id = #{created.id}", &.read(String)) }
      raw.should_not eq("written after")
    end

    it "keeps failing closed for attributes without the flag" do
      plain_id = unenc_insert("strict", "plaintext in a strict column")
      expect_raises(Grant::Encryption::Cipher::DecryptionError) { UnencNote.find!(plain_id) }
    end

    it "still rejects tampered ciphertext when the flag is on" do
      created = UnencNote.create!(note: "sealed")
      bytes = Base64.decode(UnencNote.adapter.open { |db| db.query_one("SELECT note FROM unenc_notes WHERE id = #{created.id}", &.read(String)) })
      bytes[bytes.size - 1] ^= 0x01_u8
      expect_raises(Grant::Encryption::Cipher::DecryptionError) { UnencNote.note_encrypted_attribute.open(Base64.strict_encode(bytes)) }
    end

    it "is honored by the generated getter of the <attr>_encrypted form" do
      plain_id = unenc_insert("legacy_note_encrypted", "legacy plaintext")
      UnencNote.find!(plain_id).legacy_note.should eq("legacy plaintext")
    end
  end

  describe "global flag" do
    it "makes every attribute tolerate plaintext, and switching it off restores strictness" do
      plain_id = unenc_insert("strict", "global plaintext")
      Grant::Encryption::Config.support_unencrypted_data = true
      UnencNote.find!(plain_id).strict.should eq("global plaintext")
      Grant::Encryption::Config.support_unencrypted_data = false
      expect_raises(Grant::Encryption::Cipher::DecryptionError) { UnencNote.find!(plain_id) }
    end
  end

  describe "querying plaintext and ciphertext together" do
    it "matches both forms of a deterministic attribute while the flag is on" do
      plain_id = unenc_insert("tag", "vip")
      sealed = UnencNote.create!(tag: "vip")
      UnencNote.create!(tag: "regular")

      UnencNote.where(tag: "vip").select.map(&.id).compact.sort!.should eq([plain_id, sealed.id.not_nil!].sort)
      UnencNote.where(tag: ["vip", "regular"]).count.should eq(3)
      UnencNote.where(tag: "vip").to_sql.should contain("IN")
    end
  end
end
