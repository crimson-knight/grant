require "../spec_helper"
require "../../src/grant/secure_password"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SecurePasswordAccount < Grant::Base
    connection {{ adapter_literal }}
    table secure_password_accounts

    column id : Int64, primary: true
    column email : String?
    has_secure_password
  end

  class SecurePasswordBare < Grant::Base
    connection {{ adapter_literal }}
    table secure_password_bares

    column id : Int64, primary: true
    has_secure_password :pin, validations: false, reset_token: false
  end

  class SecurePasswordExpiredToken < Grant::Base
    connection {{ adapter_literal }}
    table secure_password_expired_tokens

    column id : Int64, primary: true
    # A negative lifetime mints tokens that are already expired.
    has_secure_password reset_token_expires_in: -1.minute
  end
{% end %}

describe Grant::SecurePassword do
  before_all do
    Grant.settings.secure_password_cost = 4
    SecurePasswordAccount.migrator.drop_and_create
    SecurePasswordBare.migrator.drop_and_create
    SecurePasswordExpiredToken.migrator.drop_and_create
  end

  before_each do
    ENV["GRANT_SIGNING_SECRET"] = "secure-password-spec-secret"
    SecurePasswordAccount.clear
  end

  after_each { ENV.delete("GRANT_SIGNING_SECRET") }

  it "hashes on password= and stores a bcrypt digest, never the plain text" do
    account = SecurePasswordAccount.new(email: "a@example.com")
    account.password = "s3cret"
    digest = account.password_digest.not_nil!
    digest.should start_with("$2")
    digest.should_not contain("s3cret")
    account.password_confirmation = "s3cret"
    account.save.should be_true
    SecurePasswordAccount.find!(account.id).password_digest.should eq(digest)
    SecurePasswordAccount.find!(account.id).password.should be_nil
  end

  it "produces and accepts standard bcrypt hashes" do
    ours = Grant::SecurePassword.digest("s3cret")
    Crypto::Bcrypt::Password.new(ours).verify("s3cret").should be_true
    Grant::SecurePassword.matches?(Crypto::Bcrypt::Password.create("s3cret", cost: 4).to_s, "s3cret").should be_true
    Grant::SecurePassword.matches?(ours, "S3cret").should be_false
    Grant::SecurePassword.matches?("garbage", "s3cret").should be_false
    full = "a" * 72
    Grant::SecurePassword.matches?(Grant::SecurePassword.digest(full), full).should be_true
    Grant::SecurePassword.matches?(Grant::SecurePassword.digest(full), "a" * 71).should be_false
  end

  it "never matches a malformed or truncated digest" do
    good = Grant::SecurePassword.digest("s3cret")
    Grant::SecurePassword.matches?(good[0, 40], "s3cret").should be_false
    Grant::SecurePassword.matches?("$2a$04$abc", "s3cret").should be_false
    Grant::SecurePassword.matches?("$2a$04$" + "é" * 20, "s3cret").should be_false
    Grant::SecurePassword.matches?(nil, "s3cret").should be_false
    account = SecurePasswordAccount.new
    account.password_digest = "$2a$04$abc"
    account.authenticate("s3cret").should be_nil
  end

  it "reads the bcrypt cost from Grant.settings and rejects an out-of-range cost" do
    Grant::SecurePassword.digest("s3cret").should start_with("$2a$04$")
    expect_raises(ArgumentError, /secure_password_cost/) { Grant.settings.secure_password_cost = 3 }
    Grant.settings.secure_password_cost.should eq(4)
  end

  it "requires a password on a new record" do
    account = SecurePasswordAccount.new(email: "a@example.com")
    account.valid?.should be_false
    account.errors[:password].should contain("can't be blank")
  end

  it "ignores an empty string and clears the digest on nil" do
    account = SecurePasswordAccount.new
    account.password = "abc"
    digest = account.password_digest
    account.password = ""
    account.password_digest.should eq(digest)
    account.password = nil
    account.password_digest.should be_nil
  end

  it "validates confirmation only when assigned" do
    account = SecurePasswordAccount.new
    account.password = "s3cret"
    account.valid?.should be_true
    account.password_confirmation = "other"
    account.valid?.should be_false
    account.errors[:password_confirmation].should_not be_empty
    account.password_confirmation = "s3cret"
    account.valid?.should be_true
  end

  it "rejects passwords over 72 bytes and accepts exactly 72" do
    account = SecurePasswordAccount.new
    account.password = "a" * 73
    account.valid?.should be_false
    account.errors[:password].first.should contain("too long")
    account.password = "a" * 72
    account.valid?.should be_true
  end

  it "clears the old digest when an over-long password is assigned" do
    bare = SecurePasswordBare.new
    bare.pin = "1234"
    bare.save.should be_true
    bare.pin = "9" * 73
    bare.pin_digest.should be_nil
    bare.save.should be_true
    SecurePasswordBare.find!(bare.id).authenticate_pin("1234").should be_nil
  end

  it "assigns password, confirmation and challenge through mass assignment" do
    SecurePasswordAccount.new(password: "s3cret", password_confirmation: "other").valid?.should be_false
    account = SecurePasswordAccount.create(email: "a@example.com", password: "s3cret", password_confirmation: "s3cret")
    account.persisted?.should be_true
    found = SecurePasswordAccount.find!(account.id)
    found.set_attributes({"password" => "next-pass", "password_challenge" => "wrong"} of String | Symbol => String)
    found.valid?.should be_false
    found.errors[:password_challenge].should_not be_empty
  end

  it "skips the confirmation check when no new password was assigned" do
    account = SecurePasswordAccount.create(email: "a@example.com", password: "s3cret")
    found = SecurePasswordAccount.find!(account.id)
    found.password_confirmation = "anything"
    found.valid?.should be_true
  end

  it "does not require a password on update" do
    account = SecurePasswordAccount.create(email: "a@example.com", password: "s3cret")
    found = SecurePasswordAccount.find!(account.id)
    found.email = "b@example.com"
    found.save.should be_true
  end

  it "authenticates with authenticate and authenticate_password" do
    account = SecurePasswordAccount.new
    account.password = "s3cret"
    account.save
    account.authenticate("s3cret").should eq(account)
    account.authenticate_password("s3cret").should eq(account)
    account.authenticate("wrong").should be_nil
    account.authenticate("").should be_nil
    account.authenticate("a" * 100).should be_nil
    SecurePasswordAccount.new.authenticate("x").should be_nil
  end

  it "checks password_challenge against the digest before the change" do
    account = SecurePasswordAccount.new
    account.password = "old-pass"
    account.save.should be_true
    found = SecurePasswordAccount.find!(account.id)
    found.password = "new-pass"
    found.password_challenge = "wrong"
    found.valid?.should be_false
    found.errors[:password_challenge].should_not be_empty
    found.password_challenge = "old-pass"
    found.valid?.should be_true
    found.save.should be_true
    found.authenticate("new-pass").should eq(found)
  end

  it "supports a named attribute without validations or reset token" do
    bare = SecurePasswordBare.new
    bare.pin = "1234"
    bare.save.should be_true
    bare.authenticate_pin("1234").should eq(bare)
    bare.authenticate_pin("9999").should be_nil
    bare.responds_to?(:authenticate).should be_false
  end

  describe "reset token" do
    it "finds the record until the password changes" do
      account = SecurePasswordAccount.create(email: "a@example.com", password: "s3cret")
      token = account.password_reset_token
      SecurePasswordAccount.find_by_password_reset_token(token).should eq(account)
      SecurePasswordAccount.find_by_password_reset_token!(token).should eq(account)

      account.password = "changed"
      account.save.should be_true
      SecurePasswordAccount.find_by_password_reset_token(token).should be_nil
      expect_raises(Grant::InvalidToken) { SecurePasswordAccount.find_by_password_reset_token!(token) }
    end

    it "rejects an expired token" do
      record = SecurePasswordExpiredToken.create(password: "s3cret")
      token = record.password_reset_token
      SecurePasswordExpiredToken.find_by_password_reset_token(token).should be_nil
      expect_raises(Grant::InvalidToken) { SecurePasswordExpiredToken.find_by_password_reset_token!(token) }
    end

    it "rejects a forged token" do
      SecurePasswordAccount.find_by_password_reset_token("nope").should be_nil
    end
  end
end
