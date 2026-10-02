require "../../spec_helper"
require "../../support/column_type"

class UuidTypeAccount < Grant::Base
  connection {{ env("CURRENT_ADAPTER") || "sqlite" }}
  table uuid_type_accounts

  column id : UUID, primary: true
  column name : String?
  column owner_ref : UUID?
end

class UuidTypeEvent < Grant::Base
  connection {{ env("CURRENT_ADAPTER") || "sqlite" }}
  table uuid_type_events

  column id : UUID, primary: true, uuid_version: :v7
  column name : String?
end

describe "UUID columns" do
  before_each do
    UuidTypeAccount.migrator.drop_and_create
    UuidTypeEvent.migrator.drop_and_create
  end

  it "round trips a generated v4 key and a UUID attribute" do
    owner = UUID.random
    account = UuidTypeAccount.create!(name: "a", owner_ref: owner)
    account.id.should be_a(UUID)
    account.id!.version.v4?.should be_true

    reloaded = UuidTypeAccount.find!(account.id!)
    reloaded.id.should eq account.id
    reloaded.owner_ref.should eq owner
    UuidTypeAccount.create!(name: "n").owner_ref.should be_nil
  end

  it "finds by UUID value and by string" do
    account = UuidTypeAccount.create!(name: "a")
    UuidTypeAccount.find(account.id!).not_nil!.name.should eq "a"
    UuidTypeAccount.find(account.id!.to_s).not_nil!.name.should eq "a"
    UuidTypeAccount.find_by(id: account.id!.to_s).not_nil!.name.should eq "a"
    UuidTypeAccount.find_by(owner_ref: nil).not_nil!.name.should eq "a"
    UuidTypeAccount.find(UUID.random.to_s).should be_nil
  end

  it "finds by an upper-case UUID string" do
    account = UuidTypeAccount.create!(name: "a")
    UuidTypeAccount.find(account.id!.to_s.upcase).not_nil!.name.should eq "a"
  end

  it "casts a valid string and reports an invalid one" do
    account = UuidTypeAccount.new
    account.set_attributes({"owner_ref" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8"})
    account.errors.should be_empty
    account.owner_ref.should eq UUID.new("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

    bad = UuidTypeAccount.new
    bad.set_attributes({"owner_ref" => "not-a-uuid"})
    bad.errors.size.should eq 1
    bad.errors.first.field.should eq "owner_ref"
    bad.owner_ref.should be_nil
  end

  it "stores a native uuid column on PostgreSQL and text elsewhere" do
    type = database_column_type(UuidTypeAccount.adapter, "uuid_type_accounts", "id")
    case CURRENT_ADAPTER
    when "pg"    then type.should eq "uuid"
    when "mysql" then type.should eq "char(36)"
    else              type.should_not be_empty
    end
  end

  it "generates time-ordered v7 keys with uuid_version: :v7" do
    events = (1..5).map do |index|
      sleep 2.milliseconds
      UuidTypeEvent.create!(name: "e#{index}")
    end
    events.each(&.id!.version.v7?.should(be_true))
    events.map(&.id!.to_s).should eq events.map(&.id!.to_s).sort!
    UuidTypeEvent.find!(events.last.id!).name.should eq "e5"
  end

  it "honors an explicitly assigned key" do
    fixed = UUID.random
    account = UuidTypeAccount.new(name: "fixed")
    account.id = fixed
    account.save!
    UuidTypeAccount.find!(fixed).name.should eq "fixed"
  end
end
