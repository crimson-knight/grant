require "sqlite3"
require "../src/grant"
require "../src/grant/sharding"
require "../src/adapter/sqlite"

# Sharding strategies in Grant, one model per strategy.
#
# Every shard here is its own SQLite file, so the example runs anywhere:
#
#   crystal run examples/sharding_examples.cr
#
# In production each shard is a separate database server; register its URL
# with `Grant::ConnectionRegistry.establish_connection(shard: ...)` the same way.

EXAMPLE_DATABASE  = "sharding_examples"
EXAMPLE_DIRECTORY = File.join(Dir.tempdir, "grant_sharding_examples")

# 1. Hash sharding: rows spread evenly over :shard_0 ... :shard_3 by user id.
class ShardedUser < Grant::Base
  connection "sharding_examples"
  table sharded_users
  include Grant::Sharding::Model

  shards_by :id, strategy: :hash, count: 4

  column id : Int64, primary: true
  column email : String
  column country : String
end

# 2. Lookup sharding: each tenant is placed on a named shard; unknown tenants
#    go to the default shard.
class TenantRecord < Grant::Base
  connection "sharding_examples"
  table tenant_records
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup,
    lookup: {"1" => :shard_0, "2" => :shard_1},
    default_shard: :shard_2

  column id : Int64, primary: true
  column tenant_id : Int64
  column value : String
end

# 3. Time-range sharding: events are placed by the half-year they happened in.
#    `from` is inclusive and `to` is exclusive.
class ShardedEvent < Grant::Base
  connection "sharding_examples"
  table sharded_events
  include Grant::Sharding::Model

  shards_by :created_at, strategy: :time_range, ranges: [
    {from: Time.utc(2026, 1, 1), to: Time.utc(2026, 7, 1), shard: :shard_0},
    {from: Time.utc(2026, 7, 1), to: Time.utc(2027, 1, 1), shard: :shard_1},
  ]

  column id : Int64, primary: true
  column event_type : String
  column created_at : Time
end

# 4. Geographic sharding: personal data stays in the region its country
#    belongs to; every other country goes to the default shard.
class PersonalData < Grant::Base
  connection "sharding_examples"
  table personal_data
  include Grant::Sharding::Model

  shards_by :country, strategy: :geo,
    regions: [
      {shard: :shard_0, countries: ["DE", "FR", "IT", "ES", "NL", "BE", "PL"], states: nil, cities: nil},
      {shard: :shard_1, countries: ["US"], states: nil, cities: nil},
      {shard: :shard_2, countries: ["JP", "SG", "KR", "IN"], states: nil, cities: nil},
    ],
    default_shard: :shard_3

  column id : Int64, primary: true
  column user_id : Int64
  column country : String
  column data_classification : String
end

SCHEMA = [
  "CREATE TABLE IF NOT EXISTS sharded_users (id INTEGER PRIMARY KEY, email TEXT NOT NULL, country TEXT NOT NULL)",
  "CREATE TABLE IF NOT EXISTS tenant_records (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, value TEXT NOT NULL)",
  "CREATE TABLE IF NOT EXISTS sharded_events (id INTEGER PRIMARY KEY, event_type TEXT NOT NULL, created_at TEXT NOT NULL)",
  "CREATE TABLE IF NOT EXISTS personal_data (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, country TEXT NOT NULL, data_classification TEXT NOT NULL)",
]

# Creates one SQLite file per shard and registers it as that shard's primary.
Dir.mkdir_p(EXAMPLE_DIRECTORY)
[:shard_0, :shard_1, :shard_2, :shard_3].each do |shard|
  path = File.join(EXAMPLE_DIRECTORY, "#{shard}.db")
  File.delete?(path)
  url = "sqlite3:#{path}"
  DB.open(url) do |db|
    SCHEMA.each { |statement| db.exec(statement) }
  end
  Grant::ConnectionRegistry.establish_connection(
    database: EXAMPLE_DATABASE,
    adapter: Grant::Adapter::Sqlite,
    url: url,
    role: :primary,
    shard: shard
  )
end

puts "=== Sharding Examples ==="

# Writes are routed by the shard key: no shard is named by the caller.
user = ShardedUser.new(email: "user@example.com", country: "US")
user.id = 42_i64
user.save!
puts "User #{user.id} saved on #{user.current_shard}"

# Queries without a shard key fan out to every shard and merge the result.
puts "Users across all shards: #{ShardedUser.count}"

# A query can also be pinned to one shard.
on_shard = ShardedUser.on_shard(user.determine_shard).where(country: "US").all
puts "US users on #{user.current_shard}: #{on_shard.size}"

# Or a block can run with one shard active.
Grant::ShardManager.with_shard(:shard_0) do
  puts "Users on shard_0: #{ShardedUser.where(country: "US").count}"
end

record = TenantRecord.new(tenant_id: 2_i64, value: "settings")
record.id = 1_i64
record.save!
puts "Tenant 2 data saved on #{record.current_shard}"

event = ShardedEvent.new(event_type: "login", created_at: Time.utc(2026, 8, 15))
event.id = 1_i64
event.save!
puts "August event saved on #{event.current_shard}"

personal = PersonalData.new(user_id: 42_i64, country: "DE", data_classification: "PII")
personal.id = 1_i64
personal.save!
puts "German personal data saved on #{personal.current_shard}"

# Every record of every shard, read in keyset batches.
ShardedUser.find_each_shard(batch_size: 100) do |each_user|
  puts "#{each_user.email} lives on #{each_user.current_shard}"
end
