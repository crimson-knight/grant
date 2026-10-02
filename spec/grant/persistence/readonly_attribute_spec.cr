require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class ReadonlyAccount < Grant::Base
    connection {{ adapter_literal }}
    table readonly_accounts

    column id : Int64, primary: true
    column login : String?
    column nickname : String?

    attr_readonly :login
  end

  class ReadonlyLegacyAccount < Grant::Base
    connection {{ adapter_literal }}
    table readonly_legacy_accounts

    column id : Int64, primary: true
    column login : String?
    column nickname : String?

    attr_readonly :login, raise_on_assign: false
  end

  class ReadonlyStiAccount < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table readonly_sti_accounts

    column id : Int64, primary: true
    column type : String
    column login : String?

    attr_readonly :login
  end

  class ReadonlyStiAdmin < ReadonlyStiAccount
  end
{% end %}

ReadonlyAccount.migrator.drop_and_create
ReadonlyLegacyAccount.migrator.drop_and_create
ReadonlyStiAccount.migrator.drop_and_create

describe "Readonly attributes" do
  before_each do
    ReadonlyAccount.clear
    ReadonlyLegacyAccount.clear
    ReadonlyStiAccount.clear
  end

  it "lists the readonly attributes" do
    ReadonlyAccount.readonly_attributes.should eq(["login"])
    ReadonlyAccount.readonly_attribute?("login").should be_true
    ReadonlyAccount.readonly_attribute?("nickname").should be_false
  end

  it "accepts the readonly column while the record is new" do
    account = ReadonlyAccount.new(login: "ada")
    account.login = "grace"
    account.save!
    ReadonlyAccount.find!(account.id).login.should eq("grace")
  end

  it "raises when a persisted record assigns the readonly column" do
    account = ReadonlyAccount.create!(login: "ada", nickname: "A")
    error = expect_raises(Grant::ReadonlyAttributeError, /login is marked as readonly/) do
      account.login = "grace"
    end
    error.attribute.should eq("login")
    account.login.should eq("ada")
    account.changed?.should be_false
  end

  it "raises for a loaded record too, and for update" do
    ReadonlyAccount.create!(login: "ada")
    loaded = ReadonlyAccount.first!
    expect_raises(Grant::ReadonlyAttributeError) { loaded.login = "x" }
    expect_raises(Grant::ReadonlyAttributeError) { loaded.update(login: "x") }
    expect_raises(Grant::ReadonlyAttributeError) { loaded.update_attribute(:login, "x") }
  end

  it "is a Grant::ReadOnlyRecordError" do
    account = ReadonlyAccount.create!(login: "ada")
    expect_raises(Grant::ReadOnlyRecordError) { account.login = "x" }
  end

  it "still updates the other columns" do
    account = ReadonlyAccount.create!(login: "ada", nickname: "A")
    account.update!(nickname: "B")
    ReadonlyAccount.find!(account.id).nickname.should eq("B")
    ReadonlyAccount.find!(account.id).login.should eq("ada")
  end

  it "rejects update_columns for the readonly column" do
    account = ReadonlyAccount.create!(login: "ada")
    expect_raises(Grant::ReadOnlyRecordError) { account.update_columns(login: "x") }
    expect_raises(Grant::ReadOnlyRecordError) { account.update_column(:login, "x") }
  end

  it "keeps record-level readonly! and readonly? working" do
    account = ReadonlyAccount.create!(login: "ada", nickname: "A")
    account.readonly?.should be_false
    account.readonly!
    account.readonly?.should be_true
    account.nickname = "B"
    expect_raises(Grant::ReadOnlyRecordError) { account.save! }
    expect_raises(Grant::ReadOnlyRecordError) { account.destroy }
  end

  it "does not raise when loading rows or reloading" do
    ReadonlyAccount.create!(login: "ada")
    account = ReadonlyAccount.first!
    account.reload.login.should eq("ada")
  end

  it "restores the silent behavior with raise_on_assign: false" do
    account = ReadonlyLegacyAccount.create!(login: "ada", nickname: "A")
    account.login = "grace"
    account.nickname = "B"
    account.save!

    reloaded = ReadonlyLegacyAccount.find!(account.id)
    reloaded.login.should eq("ada")
    reloaded.nickname.should eq("B")
    ReadonlyLegacyAccount.readonly_attribute?("login").should be_true
  end

  it "loads an STI subclass through a base-class query without raising" do
    ReadonlyStiAdmin.create!(login: "root")
    loaded = ReadonlyStiAccount.first!
    loaded.should be_a(ReadonlyStiAdmin)
    loaded.login.should eq("root")
    expect_raises(Grant::ReadonlyAttributeError) { loaded.login = "other" }
  end
end
