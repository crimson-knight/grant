require "../../spec_helper"
require "../../support/crystal_compiler"
require "../../../src/grant/spec_support/*"

{% begin %}
{% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}
class LockingColumnSpecLedger < Grant::Base
  connection {{adapter_literal}}
  table locking_column_spec_ledgers

  locking_column :revision
  include Grant::Locking::Optimistic

  column id : Int64, primary: true
  column title : String
end

class LockingColumnSpecDefault < Grant::Base
  connection {{adapter_literal}}
  table locking_column_spec_defaults

  include Grant::Locking::Optimistic

  column id : Int64, primary: true
  column title : String
end

class LockingColumnSpecPlain < Grant::Base
  connection {{adapter_literal}}
  table locking_column_spec_plains

  column id : Int64, primary: true
  column title : String
end
{% end %}

LockingColumnSpecLedger.migrator.drop_and_create
LockingColumnSpecDefault.migrator.drop_and_create
LockingColumnSpecPlain.migrator.drop_and_create

describe "locking_column and lock_optimistically" do
  before_each do
    LockingColumnSpecLedger.clear
    LockingColumnSpecDefault.clear
    LockingColumnSpecPlain.clear
    LockingColumnSpecLedger.lock_optimistically = true
    LockingColumnSpecDefault.lock_optimistically = true
  end

  describe "locking_column :revision" do
    it "names the column and does not add lock_version" do
      LockingColumnSpecLedger.locking_column.should eq("revision")
      LockingColumnSpecLedger.fields.should contain("revision")
      LockingColumnSpecLedger.fields.should_not contain("lock_version")
      LockingColumnSpecDefault.locking_column.should eq("lock_version")
    end

    it "starts at 0 and counts updates in the custom column" do
      ledger = LockingColumnSpecLedger.create!(title: "v0")
      ledger.revision.should eq(0)

      ledger.update!(title: "v1")
      ledger.update!(title: "v2")

      ledger.revision.should eq(2)
      LockingColumnSpecLedger.find!(ledger.id).revision.should eq(2)
    end

    it "puts the version in the UPDATE's WHERE clause on the custom column" do
      ledger = LockingColumnSpecLedger.create!(title: "v0")

      queries = Grant::Spec.capture_queries { ledger.update!(title: "v1") }
      update = queries.find!(&.sql.starts_with?("UPDATE"))
      update.sql.should contain("revision")
      update.sql.should_not contain("lock_version")
    end

    it "raises StaleObjectError for a stale copy and accepts it after reload" do
      ledger = LockingColumnSpecLedger.create!(title: "v0")
      stale = LockingColumnSpecLedger.find!(ledger.id)

      ledger.update!(title: "winner")

      stale.title = "loser"
      expect_raises(Grant::Locking::Optimistic::StaleObjectError, "stale LockingColumnSpecLedger") { stale.save! }
      LockingColumnSpecLedger.find!(ledger.id).title.should eq("winner")

      stale.reload
      stale.revision.should eq(1)
      stale.update!(title: "second try")
      LockingColumnSpecLedger.find!(ledger.id).revision.should eq(2)
    end

    it "checks the custom column on destroy" do
      ledger = LockingColumnSpecLedger.create!(title: "v0")
      stale = LockingColumnSpecLedger.find!(ledger.id)
      ledger.update!(title: "v1")

      expect_raises(Grant::Locking::Optimistic::StaleObjectError) { stale.destroy }
      LockingColumnSpecLedger.exists?(ledger.id).should be_true
    end

    it "refuses to be declared after the include, where the default column already exists" do
      compiler = spec_crystal_compiler

      root = File.expand_path("../../..", __DIR__)
      source = File.tempfile("locking_column_late", ".cr", dir: root) do |file|
        file.puts %(require "./src/grant")
        file.puts %(require "sqlite3")
        file.puts "class LockingColumnSpecLate < Grant::Base"
        file.puts "  include Grant::Locking::Optimistic"
        file.puts "  locking_column :revision"
        file.puts "  column id : Int64, primary: true"
        file.puts "end"
      end

      begin
        output = IO::Memory.new
        status = Process.run(compiler.not_nil!, ["build", "--no-codegen", source.path], output: output, error: output, chdir: root)
        status.success?.should be_false
        output.to_s.should contain("must be declared before `include Grant::Locking::Optimistic`")
      ensure
        source.delete
      end
    end
  end

  describe "lock_optimistically" do
    it "defaults to true and reports locking_enabled?" do
      LockingColumnSpecDefault.lock_optimistically.should be_true
      LockingColumnSpecDefault.locking_enabled?.should be_true
      LockingColumnSpecLedger.locking_enabled?.should be_true
    end

    it "is false for a model that does not include the module" do
      LockingColumnSpecPlain.locking_enabled?.should be_false
    end

    it "turns off the version check and the bump when set to false" do
      record = LockingColumnSpecDefault.create!(title: "v0")
      stale = LockingColumnSpecDefault.find!(record.id)
      record.update!(title: "v1")
      record.lock_version.should eq(1)

      LockingColumnSpecDefault.lock_optimistically = false
      LockingColumnSpecDefault.locking_enabled?.should be_false

      stale.title = "last write wins"
      stale.save!
      row = LockingColumnSpecDefault.find!(record.id)
      row.title.should eq("last write wins")
      row.lock_version.should eq(1)
      stale.lock_version.should eq(0)
    end

    it "turns destroy and touch checks off too" do
      record = LockingColumnSpecDefault.create!(title: "v0")
      stale = LockingColumnSpecDefault.find!(record.id)
      record.update!(title: "v1")

      LockingColumnSpecDefault.lock_optimistically = false
      stale.destroy.should be_true
      LockingColumnSpecDefault.exists?(record.id).should be_false
    end

    it "checks again once it is turned back on" do
      record = LockingColumnSpecDefault.create!(title: "v0")
      LockingColumnSpecDefault.lock_optimistically = false
      LockingColumnSpecDefault.lock_optimistically = true

      stale = LockingColumnSpecDefault.find!(record.id)
      record.update!(title: "v1")
      stale.title = "late"
      expect_raises(Grant::Locking::Optimistic::StaleObjectError) { stale.save! }
    end

    it "is per model class" do
      LockingColumnSpecLedger.lock_optimistically = false
      LockingColumnSpecDefault.locking_enabled?.should be_true
    end
  end
end
