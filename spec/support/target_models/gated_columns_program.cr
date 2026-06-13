# Standalone program compiled under each -Dgrant_target_* flag by
# spec/grant/compile_target_columns_compile_spec.cr.
#
# It exercises per-target column gating end to end:
#   * gated columns present under their target, absent under others
#   * shared (ungated) columns always present
#   * a gated column on an STI subclass
#   * JSON/YAML round-trip with gated columns (the #41 abstract-base fix must
#     still hold)
#
# It prints `KEY=value` lines and a final `RESULT=OK`. The spec asserts on the
# emitted lines per active flag, so the *same source* proves the behaviour
# differs by build flag (zero runtime cost: gated-out columns are not in
# `fields` at all).

require "../../../src/grant"
require "../../../src/adapter/sqlite"

# In-memory SQLite — no schema needed; we only introspect fields + (de)serialize
# in memory, we do not hit the DB.
Grant::ConnectionRegistry.establish_connection(
  database: "primary",
  adapter: Grant::Adapter::Sqlite,
  url: "sqlite3://%3Amemory%3A"
)

class TargetUser < Grant::Base
  connection "primary"
  table target_users

  column id : Int64, primary: true                            # shared (never gated)
  column email : String?                                      # shared
  column password_digest : String?, targets: [:web]           # server-only
  column push_token : String?, targets: [:mobile]             # device-only
  column avatar_cache : String?, targets: [:mobile, :desktop] # device family
end

# STI hierarchy with a gated column on a subclass — the highest-risk interaction.
class TargetAccount < Grant::Base
  include Grant::STI
  connection "primary"
  table target_accounts

  column id : Int64, primary: true
  column type : String
  column name : String?
end

class TargetAdminAccount < TargetAccount
  column admin_note : String?
  column server_secret : String?, targets: [:web] # gated subclass column
end

def has_field?(klass, name : String) : Bool
  klass.fields.includes?(name)
end

puts "TARGETS=#{Grant.active_targets.join(",")}"
puts "COMPILED=#{Grant.compiled_adapters.join(",")}"

# Shared columns are present on every target.
puts "user_has_id=#{has_field?(TargetUser, "id")}"
puts "user_has_email=#{has_field?(TargetUser, "email")}"

# Gated columns.
puts "user_has_password_digest=#{has_field?(TargetUser, "password_digest")}"
puts "user_has_push_token=#{has_field?(TargetUser, "push_token")}"
puts "user_has_avatar_cache=#{has_field?(TargetUser, "avatar_cache")}"

# STI subclass: shared + gated.
puts "admin_has_name=#{has_field?(TargetAdminAccount, "name")}"
puts "admin_has_admin_note=#{has_field?(TargetAdminAccount, "admin_note")}"
puts "admin_has_server_secret=#{has_field?(TargetAdminAccount, "server_secret")}"

# Serialization round-trip (must work regardless of which columns are gated).
u = TargetUser.new
u.id = 1_i64
u.email = "a@example.com"
{% if flag?(:grant_target_web) %}
  u.password_digest = "hashed"
{% end %}
{% if flag?(:grant_target_mobile) %}
  u.push_token = "tok-123"
{% end %}

json = u.to_json
back = TargetUser.from_json(json)
puts "json_roundtrip_email=#{back.email}"

{% if flag?(:grant_target_web) %}
  puts "json_has_password_digest=#{json.includes?("password_digest")}"
  puts "json_roundtrip_password_digest=#{back.password_digest}"
{% end %}
{% unless flag?(:grant_target_web) %}
  # Absent target: the column does not exist, so it never appears in JSON.
  puts "json_has_password_digest=#{json.includes?("password_digest")}"
{% end %}

# STI subclass serialization round-trip with its gated column.
a = TargetAdminAccount.new
a.id = 2_i64
a.name = "root"
a.admin_note = "note"
{% if flag?(:grant_target_web) %}
  a.server_secret = "s3cr3t"
{% end %}

ayaml = a.to_yaml
aback = TargetAdminAccount.from_yaml(ayaml)
puts "admin_yaml_roundtrip_name=#{aback.name}"
puts "admin_yaml_has_server_secret=#{ayaml.includes?("server_secret")}"
{% if flag?(:grant_target_web) %}
  puts "admin_yaml_roundtrip_server_secret=#{aback.server_secret}"
{% end %}

puts "RESULT=OK"
