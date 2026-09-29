require "../../spec_helper"
require "../../../src/grant/encryption"

class TransparentEncUser < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table transparent_enc_users

  column id : Int64, primary: true
  column name : String?

  encrypts email : String, deterministic: true
  encrypts balance : Int64
  encrypts seen_at : Time
  encrypts prefs : JSON::Any
  encrypts ratio : Float64
  encrypts active : Bool
  # The original storage form keeps working next to the new one.
  encrypts :legacy_note, deterministic: true
end

TransparentEncUser.migrator.drop_and_create

def transparent_raw_column(user : TransparentEncUser, column : String) : String?
  TransparentEncUser.adapter.open do |db|
    db.query_one("SELECT #{column} FROM transparent_enc_users WHERE id = #{user.id}", &.read(String?))
  end
end

describe "Grant::Encryption transparent same-name columns" do
  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
      config.deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
      config.key_derivation_salt = "transparent-salt"
    end
    TransparentEncUser.migrator.drop_and_create
  end

  before_each { TransparentEncUser.clear }

  it "stores ciphertext in the column of the same name and reads it back typed" do
    when_seen = Time.utc(2026, 9, 29, 12, 30, 45, nanosecond: 123_456_789)
    user = TransparentEncUser.create!(name: "Ada", email: "ada@example.com", balance: 1_234_567_890_123_i64, seen_at: when_seen, prefs: JSON.parse(%({"theme":"dark","n":[1,2]})), ratio: 2.5, active: true)

    stored = TransparentEncUser.find!(user.id.not_nil!)
    stored.email.should eq("ada@example.com")
    stored.balance.should eq(1_234_567_890_123_i64)
    stored.seen_at.should eq(when_seen)
    stored.prefs.not_nil!["theme"].as_s.should eq("dark")
    stored.ratio.should eq(2.5)
    stored.active.should be_true

    {"email", "balance", "seen_at", "prefs", "ratio", "active"}.each do |column|
      raw = transparent_raw_column(user, column).not_nil!
      raw.should_not eq("ada@example.com")
      raw.should_not contain("dark")
      Grant::Encryption::Cipher.encrypted_payload?(Base64.decode(raw)).should be_true
    end
    transparent_raw_column(user, "email").not_nil!.should_not contain("ada")
  end

  it "keeps nil as NULL" do
    user = TransparentEncUser.create!(name: "Nobody")
    transparent_raw_column(user, "email").should be_nil
    TransparentEncUser.find!(user.id.not_nil!).email.should be_nil
  end

  it "rewrites where(email:) for deterministic attributes at builder time" do
    ada = TransparentEncUser.create!(email: "ada@example.com", balance: 1_i64)
    TransparentEncUser.create!(email: "bob@example.com", balance: 2_i64)

    TransparentEncUser.where(email: "ada@example.com").select.map(&.id).should eq([ada.id])
    TransparentEncUser.where(email: ["ada@example.com", "bob@example.com"]).count.should eq(2)
    TransparentEncUser.where(email: "nobody@example.com").count.should eq(0)
    TransparentEncUser.where(email: nil).count.should eq(0)
    TransparentEncUser.find_by_email("ada@example.com").not_nil!.id.should eq(ada.id)
    TransparentEncUser.where_email("bob@example.com").count.should eq(1)
    TransparentEncUser.find_by(email: "ada@example.com").not_nil!.id.should eq(ada.id)

    sql = TransparentEncUser.where(email: "ada@example.com").to_sql
    sql.should contain("email")
    sql.should_not contain("ada@example.com")
  end

  it "computes one ciphertext per lookup, not per row" do
    5.times { |i| TransparentEncUser.create!(email: "user#{i}@example.com") }
    attribute = TransparentEncUser.email_encrypted_attribute
    values = attribute.query_values("user1@example.com")
    values.size.should eq(1)
    attribute.query_value("user1@example.com").should eq(values.first)
  end

  it "refuses to match non-deterministic encrypted attributes by value" do
    expect_raises(ArgumentError) { TransparentEncUser.where(balance: 5_i64).count }
  end

  it "still reads and queries the <attr>_encrypted form" do
    user = TransparentEncUser.create!(legacy_note: "old style")
    TransparentEncUser.find!(user.id.not_nil!).legacy_note.should eq("old style")
    transparent_raw_column(user, "legacy_note_encrypted").not_nil!.should_not contain("old style")
    TransparentEncUser.find_by_legacy_note("old style").not_nil!.id.should eq(user.id)
    TransparentEncUser.where(legacy_note: "old style").count.should eq(1)
  end

  it "reads rows that an earlier <attr>_encrypted declaration wrote" do
    user = TransparentEncUser.create!(legacy_note: "kept")
    Grant::Encryption.decrypt(transparent_raw_column(user, "legacy_note_encrypted"), "TransparentEncUser", "legacy_note").should eq("kept")
    TransparentEncUser.find!(user.id.not_nil!).legacy_note.should eq("kept")
  end

  it "updates typed values" do
    user = TransparentEncUser.create!(email: "ada@example.com", balance: 1_i64)
    user.balance = 99_i64
    user.save!
    TransparentEncUser.find!(user.id.not_nil!).balance.should eq(99_i64)
    TransparentEncUser.find!(user.id.not_nil!).email.should eq("ada@example.com")
  end

  it "masks the value in inspect" do
    user = TransparentEncUser.new(email: "ada@example.com", balance: 5_i64)
    user.inspect.should_not contain("ada@example.com")
    user.inspect.should contain("email: [FILTERED]")
  end
end
