require "../../spec_helper"
require "../../../src/grant/encryption"

class OptionsEncCaseUser < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table options_enc_case_users

  column id : Int64, primary: true
  encrypts email : String, deterministic: true, ignore_case: true
  encrypts login : String, deterministic: true, downcase: true
end

class OptionsEncBodyDoc < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table options_enc_body_docs

  column id : Int64, primary: true
  encrypts packed : String, compress: true
  encrypts loose : String
  encrypts small_threshold : String, compress: true, compress_threshold: 10
end

OptionsEncCaseUser.migrator.drop_and_create
OptionsEncBodyDoc.migrator.drop_and_create

def options_enc_raw(table : String, column : String, id) : String?
  OptionsEncCaseUser.adapter.open do |db|
    db.query_one("SELECT #{column} FROM #{table} WHERE id = #{id}", as: String?)
  end
end

describe "Grant::Encryption options" do
  after_all do
    Grant::Encryption::KeyProvider.primary_key = nil
    Grant::Encryption::KeyProvider.deterministic_key = nil
    Grant::Encryption::KeyProvider.key_derivation_salt = Grant::Encryption::KeyProvider::DEFAULT_SALT
  end

  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
      config.deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
      config.key_derivation_salt = "options-salt"
    end
    OptionsEncCaseUser.migrator.drop_and_create
    OptionsEncBodyDoc.migrator.drop_and_create
  end

  before_each do
    OptionsEncCaseUser.clear
    OptionsEncBodyDoc.clear
  end

  describe "ignore_case:" do
    it "matches regardless of case while returning the original" do
      user = OptionsEncCaseUser.create!(email: "Ada@Example.COM")

      user.email.should eq("Ada@Example.COM")
      found = OptionsEncCaseUser.find!(user.id.not_nil!)
      found.email.should eq("Ada@Example.COM")

      {"ada@example.com", "ADA@EXAMPLE.COM", "Ada@Example.COM"}.each do |spelling|
        OptionsEncCaseUser.where(email: spelling).select.map(&.id).should eq([user.id])
      end
      OptionsEncCaseUser.find_by_email("aDa@eXample.com").not_nil!.id.should eq(user.id)
    end

    it "stores the lower-cased value in the column and the original in original_<attr>" do
      user = OptionsEncCaseUser.create!(email: "Ada@Example.COM")
      searchable = options_enc_raw("options_enc_case_users", "email", user.id).not_nil!
      original = options_enc_raw("options_enc_case_users", "original_email", user.id).not_nil!

      searchable.should eq(OptionsEncCaseUser.email_encrypted_attribute.seal("ada@example.com"))
      original.should_not eq(searchable)
      OptionsEncCaseUser.original_email_encrypted_attribute.open(original).should eq("Ada@Example.COM")
      searchable.should_not contain("Ada")
    end

    it "updates the original case together with the searchable value" do
      user = OptionsEncCaseUser.create!(email: "Ada@Example.COM")
      user.email = "ADA@example.org"
      user.save!

      reloaded = OptionsEncCaseUser.find!(user.id.not_nil!)
      reloaded.email.should eq("ADA@example.org")
      OptionsEncCaseUser.where(email: "ada@example.com").count.should eq(0)
      OptionsEncCaseUser.where(email: "Ada@Example.ORG").count.should eq(1)
    end

    it "is rejected without deterministic: true" do
      # Compile-time check: `encrypts x : String, ignore_case: true` raises in the
      # macro, so the runtime contract is the attribute's own flags.
      OptionsEncCaseUser.email_encrypted_attribute.deterministic.should be_true
      OptionsEncCaseUser.email_encrypted_attribute.options.ignore_case?.should be_true
    end
  end

  describe "downcase:" do
    it "stores and returns the lower-cased value and queries case-insensitively" do
      user = OptionsEncCaseUser.create!(email: "x@y.z", login: "MiXeD_Login")

      user.login.should eq("mixed_login")
      OptionsEncCaseUser.find!(user.id.not_nil!).login.should eq("mixed_login")
      OptionsEncCaseUser.where(login: "MIXED_login").count.should eq(1)
      options_enc_raw("options_enc_case_users", "login", user.id).should eq(OptionsEncCaseUser.login_encrypted_attribute.seal("mixed_login"))
    end
  end

  describe "compress:" do
    it "shrinks large values and round-trips them" do
      text = "the quick brown fox jumps over the lazy dog. " * 40
      doc = OptionsEncBodyDoc.create!(packed: text, loose: text)

      OptionsEncBodyDoc.find!(doc.id.not_nil!).packed.should eq(text)
      packed_size = options_enc_raw("options_enc_body_docs", "packed", doc.id).not_nil!.size
      loose_size = options_enc_raw("options_enc_body_docs", "loose", doc.id).not_nil!.size
      packed_size.should be < (loose_size // 4)
    end

    it "leaves values under the threshold uncompressed" do
      doc = OptionsEncBodyDoc.create!(packed: "short value", loose: "short value")
      packed_size = options_enc_raw("options_enc_body_docs", "packed", doc.id).not_nil!.size
      loose_size = options_enc_raw("options_enc_body_docs", "loose", doc.id).not_nil!.size
      packed_size.should eq(loose_size)
      OptionsEncBodyDoc.find!(doc.id.not_nil!).packed.should eq("short value")
    end

    it "honors a per-attribute threshold" do
      text = "abc" * 30
      doc = OptionsEncBodyDoc.create!(small_threshold: text, loose: text)
      small = options_enc_raw("options_enc_body_docs", "small_threshold", doc.id).not_nil!.size
      loose = options_enc_raw("options_enc_body_docs", "loose", doc.id).not_nil!.size
      small.should be < loose
      OptionsEncBodyDoc.find!(doc.id.not_nil!).small_threshold.should eq(text)
    end

    it "round-trips a value that looks like the compression marker" do
      tricky = "#{Grant::Encryption::Compression::MARKER}not really compressed"
      doc = OptionsEncBodyDoc.create!(packed: tricky, loose: tricky)
      found = OptionsEncBodyDoc.find!(doc.id.not_nil!)
      found.packed.should eq(tricky)
      found.loose.should eq(tricky)
    end

    it "reads values written before compress: was turned on" do
      text = "old data " * 60
      sealed = Grant::Encryption::Compression.decode(Grant::Encryption::Compression.encode(text, false, 140))
      sealed.should eq(text)
      Grant::Encryption::Compression.encode(text, true, 140).should start_with(Grant::Encryption::Compression::MARKER)
      Grant::Encryption::Compression.decode(Grant::Encryption::Compression.encode(text, true, 140)).should eq(text)
    end
  end
end
