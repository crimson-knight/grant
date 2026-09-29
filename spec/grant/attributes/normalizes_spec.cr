require "../../spec_helper"

class NrmAccount < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table nrm_accounts

  column id : Int64, primary: true
  column email : String?
  column handle : String?
  column nickname : String?
  column age : Int32?
  column code : String

  normalizes :email, :handle, with: ->(value : String) { value.strip.downcase }
  normalizes :age, with: ->(value : Int32) { value.clamp(0, 150) }
  normalizes :nickname, apply_to_nil: true do |value|
    value.nil? ? "anon" : value.strip
  end
  normalizes :code do |value|
    value.upcase
  end
end

describe "normalizes" do
  before_all do
    id_column = case CURRENT_ADAPTER
                when "pg"    then "BIGSERIAL PRIMARY KEY"
                when "mysql" then "BIGINT AUTO_INCREMENT PRIMARY KEY"
                else              "INTEGER PRIMARY KEY AUTOINCREMENT"
                end
    NrmAccount.exec("DROP TABLE IF EXISTS nrm_accounts")
    NrmAccount.exec("CREATE TABLE nrm_accounts (id #{id_column}, email VARCHAR(255), handle VARCHAR(255), nickname VARCHAR(255), age INTEGER, code VARCHAR(255) NOT NULL)")
  end

  before_each { NrmAccount.clear }

  it "normalizes several attributes declared in one call" do
    account = NrmAccount.new(email: "  A@B.COM ", handle: " HeLLo ", code: "x")
    account.email.should eq("a@b.com")
    account.handle.should eq("hello")
  end

  it "applies a typed proc to non-string columns" do
    account = NrmAccount.new(age: 900, code: "x")
    account.age.should eq(150)
  end

  it "applies in the setter, without validation" do
    account = NrmAccount.new(code: "x")
    account.email = "  Q@Z.COM "
    account.email.should eq("q@z.com")
    account.email_changed?.should be_true
  end

  it "does not run for nil unless apply_to_nil is set" do
    account = NrmAccount.new(code: "x")
    account.email = nil
    account.email.should be_nil
    account.nickname = nil
    account.nickname.should eq("anon")
    account.nickname = "  bob "
    account.nickname.should eq("bob")
  end

  it "normalizes non-nilable columns" do
    NrmAccount.new(code: "abc").code.should eq("ABC")
  end

  it "persists the normalized value" do
    account = NrmAccount.create!(email: " P@Q.COM ", code: "k")
    NrmAccount.find!(account.id).email.should eq("p@q.com")
  end

  it "skips normalizers when loading from the database" do
    NrmAccount.exec("INSERT INTO nrm_accounts (email, code) VALUES ('  RAW@X.COM ', 'lower')")
    loaded = NrmAccount.first!
    loaded.email.should eq("  RAW@X.COM ")
    loaded.code.should eq("lower")
    loaded.email_changed?.should be_false
  end

  it "bypasses nothing on update" do
    account = NrmAccount.create!(email: "a@b.com", code: "k")
    account.update!(email: " NEW@B.COM ")
    NrmAccount.find!(account.id).email.should eq("new@b.com")
  end

  describe ".normalize_value_for" do
    it "applies the declared normalizer" do
      NrmAccount.normalize_value_for(:email, " A@X ").should eq("a@x")
      NrmAccount.normalize_value_for("age", 500).should eq(150)
    end

    it "passes through values of undeclared attributes" do
      NrmAccount.normalize_value_for(:unknown, " Keep ").should eq(" Keep ")
    end
  end
end
