require "../../spec_helper"
require "../../../src/grant/encryption"
require "log/spec"

class W6bLazyUser < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_lazy_users

  column id : Int64, primary: true
  column name : String?
  encrypts email : String, deterministic: true, lazy: true
  encrypts nickname : String, ignore_case: true, deterministic: true, lazy: true
  encrypts secret : String, lazy: true
  encrypts eager_note : String
  encrypts balance : Int64
end

# Decrypt operations the encryption log records while the block runs.
private def w6b_decrypts(& : ->) : Array(String)
  backend = Log::MemoryBackend.new
  Log.builder.bind("grant.encryption", Log::Severity::Debug, backend)
  previous = Grant::Encryption::Config.verbose_logging
  Grant::Encryption::Config.verbose_logging = true
  begin
    yield
  ensure
    Grant::Encryption::Config.verbose_logging = previous
    Log.builder.unbind("grant.encryption", Log::Severity::Debug, backend)
  end
  backend.entries.compact_map(&.message).select(&.starts_with?("decrypt "))
end

private def w6b_raw(user_id, column : String) : String?
  W6bLazyUser.adapter.open do |db|
    db.query_one("SELECT #{column} FROM w6b_lazy_users WHERE id = #{user_id}", as: String?)
  end
end

describe "Grant::Encryption lazy decryption of typed attributes" do
  after_all do
    Grant::Encryption::KeyProvider.primary_key = nil
    Grant::Encryption::KeyProvider.deterministic_key = nil
    Grant::Encryption::KeyProvider.key_derivation_salt = Grant::Encryption::KeyProvider::DEFAULT_SALT
  end

  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
      config.deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
      config.key_derivation_salt = "lazy-salt"
    end
    W6bLazyUser.migrator.drop_and_create
  end

  before_each { W6bLazyUser.clear }

  it "does not decrypt String attributes while rows are hydrated" do
    5.times { |i| W6bLazyUser.create!(name: "n#{i}", email: "u#{i}@example.com", secret: "s#{i}", nickname: "Nick#{i}") }

    rows = [] of W6bLazyUser
    decrypts = w6b_decrypts { rows = W6bLazyUser.order(:name).select }
    rows.size.should eq(5)
    decrypts.should be_empty
  end

  it "decrypts on first read and then keeps the value" do
    user = W6bLazyUser.create!(email: "ada@example.com", secret: "hush")
    loaded = W6bLazyUser.find!(user.id)

    first = w6b_decrypts { loaded.email.should eq("ada@example.com") }
    first.size.should eq(1)
    first.first.should contain("W6bLazyUser.email")

    w6b_decrypts { loaded.email.should eq("ada@example.com") }.should be_empty
    w6b_decrypts { loaded.email?.should eq("ada@example.com"); loaded.email!.should eq("ada@example.com") }.should be_empty
    # Reading one attribute leaves the others sealed.
    w6b_decrypts { loaded.secret.should eq("hush") }.size.should eq(1)
  end

  it "never decrypts an attribute that is not read while the record is only read or changed in memory" do
    user = W6bLazyUser.create!(name: "a", email: "ada@example.com", secret: "hush")

    loaded = W6bLazyUser.find!(user.id)
    decrypts = w6b_decrypts do
      loaded.name = "b"
      loaded.name_changed?.should be_true
      loaded.changed.should eq(["name"])
      loaded.reload
      loaded.dup
    end
    decrypts.should be_empty

    # A full-row UPDATE writes every column, so a save reads the sealed ones.
    loaded.name = "b"
    loaded.save!
    reloaded = W6bLazyUser.find!(user.id)
    reloaded.name.should eq("b")
    reloaded.email.should eq("ada@example.com")
    reloaded.secret.should eq("hush")
  end

  it "loads a row whose ciphertext cannot be opened and fails only on read" do
    user = W6bLazyUser.create!(name: "a", secret: "hush")
    W6bLazyUser.adapter.open { |db| db.exec("UPDATE w6b_lazy_users SET secret = '#{Base64.strict_encode(Random::Secure.random_bytes(64))}' WHERE id = #{user.id}") }

    loaded = W6bLazyUser.find!(user.id)
    loaded.name.should eq("a")
    expect_raises(Grant::Encryption::Cipher::DecryptionError) { loaded.secret }
    expect_raises(Grant::Encryption::Cipher::DecryptionError) { loaded.secret }
  end

  it "reports the stored ciphertext through the database-level readers" do
    user = W6bLazyUser.create!(email: "ada@example.com")
    loaded = W6bLazyUser.find!(user.id)

    stored = w6b_raw(user.id, "email").not_nil!
    decrypts = w6b_decrypts do
      loaded.attributes["email"].should eq(stored)
      loaded.read_attribute(:email).should eq(stored)
      loaded.inspect.should contain("email: [FILTERED]")
    end
    decrypts.should be_empty
    # The by-name reader returns the attribute's own value, as it always has.
    loaded.read_attribute("email").should eq("ada@example.com")
    loaded.email.should eq("ada@example.com")
  end

  it "tracks changes against the stored ciphertext without decrypting" do
    user = W6bLazyUser.create!(email: "ada@example.com", secret: "hush")
    loaded = W6bLazyUser.find!(user.id)

    w6b_decrypts do
      loaded.email_changed?.should be_false
      loaded.has_changes_to_save?.should be_false
      # The same plaintext for a deterministic attribute is no change.
      loaded.email = "ada@example.com"
      loaded.email_changed?.should be_false
      loaded.secret = "other"
      loaded.secret_changed?.should be_true
    end
    loaded.changed.should eq(["secret"])
    loaded.save!
    loaded.reload.secret.should eq("other")
    loaded.email.should eq("ada@example.com")
  end

  it "keeps a value through reload, dup and a transaction rollback" do
    user = W6bLazyUser.create!(email: "ada@example.com", secret: "hush")

    loaded = W6bLazyUser.find!(user.id)
    loaded.reload
    loaded.email.should eq("ada@example.com")

    sealed = W6bLazyUser.find!(user.id)
    copy = sealed.dup
    copy.save!
    W6bLazyUser.find!(copy.id).email.should eq("ada@example.com")
    W6bLazyUser.find!(copy.id).secret.should eq("hush")

    again = W6bLazyUser.find!(user.id)
    begin
      W6bLazyUser.transaction do
        again.secret = "changed"
        again.save!
        raise Grant::Transaction::Rollback.new
      end
    rescue Grant::Transaction::Rollback
    end
    W6bLazyUser.find!(user.id).secret.should eq("hush")
  end

  it "decrypts before serializing to JSON and YAML" do
    user = W6bLazyUser.create!(name: "a", email: "ada@example.com", secret: "hush")
    loaded = W6bLazyUser.find!(user.id)
    loaded.to_json.should contain("ada@example.com")
    loaded.to_json.should_not contain("grant-sealed")
    W6bLazyUser.find!(user.id).to_yaml.should contain("ada@example.com")
    W6bLazyUser.find!(user.id).to_h["email"].should eq("ada@example.com")
  end

  it "applies the ignore_case original through the lazy attribute" do
    user = W6bLazyUser.create!(nickname: "Ada L")
    W6bLazyUser.find!(user.id).nickname.should eq("Ada L")
    W6bLazyUser.where(nickname: "ada l").count.should eq(1)
  end

  it "reads like an eagerly decrypted attribute around without_encryption" do
    user = W6bLazyUser.create!(secret: "hush")

    # Loaded outside the block, the value is plaintext inside it.
    outside = W6bLazyUser.find!(user.id)
    Grant::Encryption.without_encryption { outside.secret }.should eq("hush")
    outside.secret.should eq("hush")

    # Loaded inside the block, the raw ciphertext is the value, and stays so.
    inside = Grant::Encryption.without_encryption { W6bLazyUser.find!(user.id) }
    inside.secret.should eq(w6b_raw(user.id, "secret"))
  end

  it "rejects plaintext that collides with the internal sealed marker" do
    expect_raises(ArgumentError, /reserved/) { W6bLazyUser.new.secret = Grant::Encryption::Sealed::PREFIX + "x" }
    W6bLazyUser.new(secret: Grant::Encryption::Sealed::PREFIX + "x").errors.map(&.message.to_s).first.should contain("reserved")
  end

  it "keeps attributes without lazy: true and non-String types decrypting at load" do
    user = W6bLazyUser.create!(eager_note: "note", balance: 7_i64)
    decrypts = w6b_decrypts { W6bLazyUser.find!(user.id) }
    decrypts.size.should eq(2)
    decrypts.any?(&.includes?("eager_note")).should be_true
    decrypts.any?(&.includes?("balance")).should be_true
  end
end
