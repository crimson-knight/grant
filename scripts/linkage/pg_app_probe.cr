# The PostgreSQL side of `default_app_probe.cr`. `scripts/check_pcre2_linkage.rb`
# only builds it (no server is needed) and requires that it links no PCRE2.
require "../../src/grant"
require "../../src/adapter/pg"

Grant::Connections << Grant::Adapter::Pg.new(name: "primary", url: ENV["PG_DATABASE_URL"]? || "postgres://localhost/grant_probe")

class Account < Grant::Base
  connection primary
  table accounts

  column id : Int64, primary: true
  column account_name : String
  timestamps

  validates_presence_of :account_name
end

Account.migrator.drop_and_create
Account.create!(account_name: "first")
puts Account.where(account_name: "first").order("account_name DESC").limit(1).map(&.account_name).inspect
