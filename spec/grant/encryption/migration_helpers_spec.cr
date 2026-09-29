require "../../spec_helper"
require "../../../src/grant/encryption"
require "../../../src/grant/encryption/migration_helpers"

class MigEncTransparent < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table mig_enc_transparents

  column id : Int64, primary: true
  column name : String?
  encrypts ssn : String, deterministic: true
end

class MigEncLegacy < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table mig_enc_legacies

  column id : Int64, primary: true
  column name : String?
  encrypts :ssn
end

def mig_enc_reset
  MigEncTransparent.migrator.drop_and_create
  MigEncLegacy.migrator.drop_and_create
  MigEncLegacy.adapter.open { |db| db.exec("ALTER TABLE mig_enc_legacies ADD COLUMN ssn TEXT") }
end

def mig_enc_exec(sql : String)
  MigEncTransparent.adapter.open { |db| db.exec(sql) }
end

def mig_enc_raw(table : String, column : String) : Array(String?)
  values = [] of String?
  MigEncTransparent.adapter.open do |db|
    db.query("SELECT #{column} FROM #{table} ORDER BY id") { |rs| rs.each { values << rs.read(String?) } }
  end
  values
end

def mig_enc_capture(& : ->) : Array(String)
  statements = [] of String
  handler = ->(event : Grant::Events::SQL) { statements << event.sql; nil }
  Grant::Notifications.subscribed(Grant::Events::SQL, handler) { yield }
  statements
end

describe Grant::Encryption::MigrationHelpers do
  after_all do
    Grant::Encryption::KeyProvider.primary_key = nil
    Grant::Encryption::KeyProvider.deterministic_key = nil
    Grant::Encryption::KeyProvider.key_derivation_salt = Grant::Encryption::KeyProvider::DEFAULT_SALT
  end

  helpers = Grant::Encryption::MigrationHelpers

  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
      config.deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
      config.key_derivation_salt = "migration-helpers-salt"
    end
  end

  before_each { mig_enc_reset }

  describe ".encrypt_column" do
    it "encrypts plaintext in place for a transparent attribute, in keyset batches" do
      25.times { |i| mig_enc_exec("INSERT INTO mig_enc_transparents (name, ssn) VALUES ('n#{i}', '000-00-#{1000 + i}')") }
      mig_enc_exec("INSERT INTO mig_enc_transparents (name, ssn) VALUES ('nil ssn', NULL)")

      entries = mig_enc_capture { helpers.encrypt_column(MigEncTransparent, :ssn, batch_size: 7, progress: false).should eq(26) }

      raw = mig_enc_raw("mig_enc_transparents", "ssn")
      raw.compact.size.should eq(25)
      raw.compact.each { |value| value.should_not start_with("000-00-") }
      MigEncTransparent.order(id: :asc).select.map(&.ssn).compact.first.should eq("000-00-1000")
      MigEncTransparent.where(ssn: "000-00-1005").count.should eq(1)

      selects = entries.select { |entry| entry.includes?("SELECT") && entry.includes?("ORDER BY") && !entry.includes?("COUNT") }
      selects.size.should eq(4) # 26 rows in batches of 7: 7 + 7 + 7 + 5
      entries.none?(&.includes?("OFFSET")).should be_true
      selects[1..].each { |entry| entry.should contain("> ") }
    end

    it "is idempotent: a second run leaves ciphertext untouched" do
      3.times { |i| mig_enc_exec("INSERT INTO mig_enc_transparents (name, ssn) VALUES ('n#{i}', 'plain-#{i}')") }
      helpers.encrypt_column(MigEncTransparent, :ssn, batch_size: 2, progress: false)
      first = mig_enc_raw("mig_enc_transparents", "ssn")
      helpers.encrypt_column(MigEncTransparent, :ssn, batch_size: 2, progress: false)
      mig_enc_raw("mig_enc_transparents", "ssn").should eq(first)
    end

    it "writes ciphertext to <attr>_encrypted from a plaintext source column" do
      4.times { |i| mig_enc_exec("INSERT INTO mig_enc_legacies (name, ssn) VALUES ('n#{i}', 'legacy-#{i}')") }
      helpers.encrypt_column(MigEncLegacy, :ssn, batch_size: 3, progress: false).should eq(4)

      mig_enc_raw("mig_enc_legacies", "ssn_encrypted").compact.each { |value| value.should_not contain("legacy-") }
      MigEncLegacy.order(id: :asc).select.map(&.ssn).should eq(["legacy-0", "legacy-1", "legacy-2", "legacy-3"])
    end

    it "rejects attributes that are not encrypted" do
      expect_raises(ArgumentError) { helpers.encrypt_column(MigEncLegacy, :name, progress: false) }
    end
  end

  describe ".decrypt_column" do
    it "restores plaintext in the same column for a transparent attribute and skips plaintext rows" do
      3.times { |i| MigEncTransparent.create!(name: "n#{i}", ssn: "secret-#{i}") }
      mig_enc_exec("INSERT INTO mig_enc_transparents (name, ssn) VALUES ('already plain', 'plain-row')")

      helpers.decrypt_column(MigEncTransparent, :ssn, batch_size: 2, progress: false).should eq(3)
      mig_enc_raw("mig_enc_transparents", "ssn").should eq(["secret-0", "secret-1", "secret-2", "plain-row"])
      helpers.decrypt_column(MigEncTransparent, :ssn, batch_size: 2, progress: false).should eq(0)
    end

    it "writes plaintext to a target column for the <attr>_encrypted form" do
      2.times { |i| MigEncLegacy.create!(name: "n#{i}", ssn: "kept-#{i}") }
      helpers.decrypt_column(MigEncLegacy, :ssn, target_column: :ssn, batch_size: 1, progress: false).should eq(2)
      mig_enc_raw("mig_enc_legacies", "ssn").should eq(["kept-0", "kept-1"])
    end
  end

  describe ".rotate_encryption" do
    it "re-encrypts a transparent attribute written under other keys" do
      old_primary = Base64.strict_encode("old_primary_key_32_bytes_long!!!".to_slice)
      old_determ = Base64.strict_encode("old_determ_key_32_bytes_long!!!!".to_slice)
      Grant::Encryption.with_context(primary_key: old_primary, deterministic_key: old_determ) do
        5.times { |i| MigEncTransparent.create!(name: "n#{i}", ssn: "rot-#{i}") }
      end
      expect_raises(Grant::Encryption::Cipher::DecryptionError) { MigEncTransparent.all.to_a }

      helpers.rotate_encryption(MigEncTransparent, :ssn, old_keys: {primary: old_primary, deterministic: old_determ}, batch_size: 2, progress: false).should eq(5)
      MigEncTransparent.order(id: :asc).select.map(&.ssn).should eq((0...5).map { |i| "rot-#{i}" })
      MigEncTransparent.where(ssn: "rot-3").count.should eq(1)
    end
  end

  describe ".generate_migration" do
    it "describes a transparent column and the data migration" do
      text = helpers.generate_migration(MigEncTransparent, :ssn)
      text.should contain("alter_table :mig_enc_transparents")
      text.should contain("change_column :ssn, :text")
      text.should contain("add_index :ssn")
      text.should contain("Grant::Encryption::MigrationHelpers.encrypt_column(")
      text.should contain("MigEncTransparent")
    end

    it "describes the extra column of the <attr>_encrypted form, without an index when not deterministic" do
      text = helpers.generate_migration(MigEncLegacy, :ssn)
      text.should contain("add_column :ssn_encrypted, :text")
      text.should_not contain("add_index")
      text.should contain("drop_column :ssn")
    end

    it "rejects attributes that are not encrypted" do
      expect_raises(ArgumentError) { helpers.generate_migration(MigEncLegacy, :name) }
    end
  end
end
