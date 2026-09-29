require "../../spec_helper"
require "../../../src/grant/encryption"

class CtxEncMember < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ctx_enc_members

  column id : Int64, primary: true
  column name : String?
  encrypts email : String, deterministic: true
  encrypts secret : String
  encrypts :legacy_secret
end

CtxEncMember.migrator.drop_and_create

def ctx_enc_raw(column : String, id) : String?
  CtxEncMember.adapter.open { |db| db.query_one("SELECT #{column} FROM ctx_enc_members WHERE id = #{id}", &.read(String?)) }
end

describe "Grant::Encryption context and record helpers" do
  after_all do
    Grant::Encryption::KeyProvider.primary_key = nil
    Grant::Encryption::KeyProvider.deterministic_key = nil
    Grant::Encryption::KeyProvider.key_derivation_salt = Grant::Encryption::KeyProvider::DEFAULT_SALT
  end

  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
      config.deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
      config.key_derivation_salt = "context-salt"
    end
    CtxEncMember.migrator.drop_and_create
  end

  before_each { CtxEncMember.clear }

  describe ".without_encryption" do
    it "writes plaintext and reads the stored text back, then restores encryption" do
      member = Grant::Encryption.without_encryption { CtxEncMember.create!(email: "raw@example.com", secret: "shh") }
      ctx_enc_raw("email", member.id).should eq("raw@example.com")

      Grant::Encryption.without_encryption { CtxEncMember.find!(member.id.not_nil!).email.should eq("raw@example.com") }
      Grant::Encryption.encryption_enabled?.should be_true

      sealed = CtxEncMember.create!(email: "sealed@example.com")
      ctx_enc_raw("email", sealed.id).should_not eq("sealed@example.com")
      Grant::Encryption.without_encryption { CtxEncMember.find!(sealed.id.not_nil!).email }.should eq(ctx_enc_raw("email", sealed.id))
    end

    it "returns the block value and restores the context when the block raises" do
      Grant::Encryption.without_encryption { 42 }.should eq(42)
      expect_raises(Exception, "boom") { Grant::Encryption.without_encryption { raise "boom" } }
      Grant::Encryption.encryption_enabled?.should be_true
    end

    it "is fiber-local: other fibers and children stay encrypted" do
      seen = Channel(Bool).new
      release = Channel(Nil).new

      spawn do
        Grant::Encryption.without_encryption do
          seen.send(Grant::Encryption.encryption_enabled?)
          release.receive
        end
      end

      seen.receive.should be_false
      Grant::Encryption.encryption_enabled?.should be_true

      child = Channel(Bool).new
      Grant::Encryption.without_encryption do
        Grant::Encryption.encryption_enabled?.should be_false
        spawn { child.send(Grant::Encryption.encryption_enabled?) }
        child.receive.should be_true
      end
      release.send(nil)
    end

    it "is ignored inside protecting_encrypted_data" do
      Grant::Encryption.protecting_encrypted_data do
        Grant::Encryption.without_encryption do
          Grant::Encryption.encryption_enabled?.should be_true
          member = CtxEncMember.create!(email: "still@example.com")
          ctx_enc_raw("email", member.id).should_not eq("still@example.com")
        end
      end
    end
  end

  describe ".with_context" do
    it "pins keys for the block only" do
      key = Base64.strict_encode("tenant_key_for_context_32_bytes!".to_slice)
      det = Base64.strict_encode("tenant_det_for_context_32_bytes!".to_slice)
      member = Grant::Encryption.with_context(primary_key: key, deterministic_key: det) do
        CtxEncMember.create!(email: "tenant@example.com", secret: "tenant secret")
      end

      expect_raises(Grant::Encryption::Cipher::DecryptionError) { CtxEncMember.find!(member.id.not_nil!) }
      Grant::Encryption.with_context(primary_key: key, deterministic_key: det) do
        found = CtxEncMember.find!(member.id.not_nil!)
        found.email.should eq("tenant@example.com")
        found.secret.should eq("tenant secret")
        CtxEncMember.where(email: "tenant@example.com").count.should eq(1)
      end
    end

    it "is fiber-local" do
      key = Base64.strict_encode("tenant_key_for_context_32_bytes!".to_slice)
      release = Channel(Nil).new
      pinned = Channel(Nil).new

      spawn do
        Grant::Encryption.with_context(primary_key: key) do
          pinned.send(nil)
          release.receive
        end
      end

      pinned.receive
      # This fiber still writes with the process-wide key.
      member = CtxEncMember.create!(secret: "global")
      CtxEncMember.find!(member.id.not_nil!).secret.should eq("global")
      release.send(nil)
    end
  end

  describe "record helpers" do
    it "reports encrypted attributes" do
      member = CtxEncMember.create!(email: "a@b.c", secret: "s", name: "Ada")
      member.encrypted_attribute?(:email).should be_true
      member.encrypted_attribute?("secret").should be_true
      member.encrypted_attribute?(:legacy_secret).should be_false # nil value
      member.encrypted_attribute?(:name).should be_false
    end

    it "returns the ciphertext for an attribute" do
      member = CtxEncMember.create!(email: "a@b.c", legacy_secret: "old form")
      member.ciphertext_for(:email).should eq(ctx_enc_raw("email", member.id))
      member.ciphertext_for(:legacy_secret).should eq(ctx_enc_raw("legacy_secret_encrypted", member.id))
      expect_raises(ArgumentError) { member.ciphertext_for(:name) }
    end

    it "decrypts to plaintext columns and encrypts them again" do
      member = CtxEncMember.create!(email: "a@b.c", secret: "s")
      loaded = CtxEncMember.find!(member.id.not_nil!)

      Grant::Encryption.without_encryption { loaded.decrypt }.should be_true
      # `decrypt` writes plaintext whatever the context.
      ctx_enc_raw("email", member.id).should eq("a@b.c")
      ctx_enc_raw("secret", member.id).should eq("s")

      Grant::Encryption.with_context { } # no-op context still restores
      loaded.encrypt.should be_true
      ctx_enc_raw("email", member.id).should_not eq("a@b.c")
      CtxEncMember.find!(member.id.not_nil!).secret.should eq("s")
    end

    it "refuses to rewrite a new record" do
      expect_raises(ArgumentError) { CtxEncMember.new(email: "x").encrypt }
    end
  end
end
