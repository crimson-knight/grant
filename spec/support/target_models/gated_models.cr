# Shared gated-column models + assertion harness for the compile-target specs.
#
# Required by the three thin per-target entrypoints (`entry_{mobile,desktop,
# web}.cr`), each of which first selects its adapter and target via plain
# `require`s — there is NO `-D` flag. Because the *same models* expand under a
# different `GRANT_COMPILE_TARGET`, the same source proves the behaviour differs
# by build:
#
#   * gated columns present under their target, absent under others
#   * shared (ungated) columns always present
#   * a gated column on an STI subclass
#   * JSON/YAML round-trip with gated columns (the #41 abstract-base fix holds)
#
# Each entrypoint calls `GatedColumns.run`, which prints `KEY=value` lines and a
# final `RESULT=OK`; the spec driver asserts on the emitted lines per target.
#
# NOTE: the entrypoint must `require` its adapter and `grant/target/<name>`
# (i.e. set GRANT_COMPILE_TARGET) BEFORE requiring this file, so the constant is
# defined when these models expand.

# In-memory only — no schema needed; we introspect `fields` and (de)serialize in
# memory, we never hit the DB. The entrypoint requires the adapter; here we only
# register the connection so model classes resolve their adapter.
Grant::ConnectionRegistry.establish_connection(
  database: "primary",
  adapter: {% if @top_level.has_constant?("GRANT_COMPILE_TARGET") && @top_level.constant("GRANT_COMPILE_TARGET") == :web %} Grant::Adapter::Pg {% else %} Grant::Adapter::Sqlite {% end %},
  url: {% if @top_level.has_constant?("GRANT_COMPILE_TARGET") && @top_level.constant("GRANT_COMPILE_TARGET") == :web %} "postgres://localhost/grant_target_spec_unused" {% else %} "sqlite3://%3Amemory%3A" {% end %}
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

module GatedColumns
  def self.has_field?(klass, name : String) : Bool
    klass.fields.includes?(name)
  end

  def self.run
    puts "TARGET=#{Grant.compile_target}"
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
    {% if @top_level.has_constant?("GRANT_COMPILE_TARGET") && @top_level.constant("GRANT_COMPILE_TARGET") == :web %}
      u.password_digest = "hashed"
    {% end %}
    {% if @top_level.has_constant?("GRANT_COMPILE_TARGET") && @top_level.constant("GRANT_COMPILE_TARGET") == :mobile %}
      u.push_token = "tok-123"
    {% end %}

    json = u.to_json
    back = TargetUser.from_json(json)
    puts "json_roundtrip_email=#{back.email}"
    puts "json_has_password_digest=#{json.includes?("password_digest")}"
    {% if @top_level.has_constant?("GRANT_COMPILE_TARGET") && @top_level.constant("GRANT_COMPILE_TARGET") == :web %}
      puts "json_roundtrip_password_digest=#{back.password_digest}"
    {% end %}

    # STI subclass serialization round-trip with its gated column.
    a = TargetAdminAccount.new
    a.id = 2_i64
    a.name = "root"
    a.admin_note = "note"
    {% if @top_level.has_constant?("GRANT_COMPILE_TARGET") && @top_level.constant("GRANT_COMPILE_TARGET") == :web %}
      a.server_secret = "s3cr3t"
    {% end %}

    ayaml = a.to_yaml
    aback = TargetAdminAccount.from_yaml(ayaml)
    puts "admin_yaml_roundtrip_name=#{aback.name}"
    puts "admin_yaml_has_server_secret=#{ayaml.includes?("server_secret")}"
    {% if @top_level.has_constant?("GRANT_COMPILE_TARGET") && @top_level.constant("GRANT_COMPILE_TARGET") == :web %}
      puts "admin_yaml_roundtrip_server_secret=#{aback.server_secret}"
    {% end %}

    puts "RESULT=OK"
  end
end
