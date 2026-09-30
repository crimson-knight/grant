require "yaml"
require "digest/crc32"
require "uuid"
require "../grant"

# YAML fixtures for specs (ActiveRecord's `FixtureSet`): one file per table,
# rows named by a label, ids derived from the label so a fixture can point at
# another by name, and an accessor per set.
#
# `spec/fixtures/users.yml`:
#
# ```yaml
# alice:
#   email: alice@example.com
#   admin: true
# bob:
#   email: bob@example.com
# ```
#
# `spec/fixtures/posts.yml` (`author: alice` fills the `belongs_to :author`
# foreign key with alice's id):
#
# ```yaml
# hello:
#   title: Hello
#   author: alice
# ```
#
# `spec/spec_helper.cr`:
#
# ```
# require "grant/test_fixtures"
# require "grant/spec_support/transactional"
#
# Grant::TestFixtures.fixtures users: User, posts: Post
#
# Spec.before_suite { Grant::TestFixtures.load("spec/fixtures") }
# Grant::Spec.transactional
#
# # in a spec:
# users(:alice).email # => "alice@example.com"
# ```
#
# `load` empties each fixture table and refills it with one multi-row
# `INSERT` (split only when a table exceeds the adapter's bind-parameter cap),
# with foreign key checks off so files may load in any order. The rows are
# committed; `Grant::Spec.transactional` then rolls back every example's own
# changes, so the suite never truncates between examples. To keep the rows out
# of the database altogether, load inside `Grant::Spec.within_transaction`.
#
# Ids are `identify(label)`, the CRC32 of the label modulo 2**30 - 1, so the
# same label always gets the same id (UUID primary keys get a v5 UUID of the
# label). A row that sets its own `id` keeps it. `created_at` and `updated_at`
# default to the load time when the table has them. Columns a row leaves out
# are NULL when another row of the set fills them. Not supported: ERB in YAML,
# fixture files for join tables by label (write the two foreign keys, or use
# `identify` for their values).
module Grant::TestFixtures
  # Raised for an unreadable, malformed or inconsistent fixture file.
  class Error < Grant::ErrorBase
  end

  # The largest id `identify` returns.
  MAX_ID = 2_i64**30 - 1

  # Namespace of the v5 UUIDs derived from labels.
  UUID_NAMESPACE = UUID.new("3e2f9a4c-58a8-5f4e-b3f0-0c9f0b7d1e11")

  # What `fixtures` records for each set.
  record Registration,
    name : String,
    model_name : String,
    table : String,
    primary_key : String,
    uuid_key : Bool,
    columns : Array(String),
    adapter : Proc(Grant::Adapter::Base)

  # One labeled row, its values already typed for binding.
  record Row, label : String, values : Hash(String, Grant::Columns::Type)

  @@registrations = {} of String => Registration

  # Declares the fixture sets and defines an accessor method for each.
  #
  # ```
  # Grant::TestFixtures.fixtures users: User, posts: Post
  # users(:alice) # => the User loaded from the `alice` label
  # ```
  #
  # The set name is the fixture file name (`users.yml`). An accessor looks the
  # record up by its label's id, so it raises `Grant::RecordNotFound` for a
  # label the file does not define.
  macro fixtures(**sets)
    {% for name, model in sets %}
      Grant::TestFixtures.register(
        name: {{name.stringify}},
        model_name: {{model.stringify}},
        table: {{model}}.table_name,
        primary_key: {{model}}.primary_name || "id",
        uuid_key: {{model}}.primary_type.to_s.includes?("UUID"),
        columns: {{model}}.fields,
        adapter: ->{ {{model}}.adapter.as(Grant::Adapter::Base) })

      def {{name.id}}(label : Symbol | String) : {{model}}
        {{model}}.find!(Grant::TestFixtures.id_for({{name.stringify}}, label))
      end
    {% end %}
  end

  # :nodoc:
  def self.register(name : String, model_name : String, table : String, primary_key : String,
                    uuid_key : Bool, columns : Array(String), adapter : Proc(Grant::Adapter::Base)) : Nil
    @@registrations[name] = Registration.new(name, model_name, table, primary_key, uuid_key, columns, adapter)
  end

  # The id `label` gets: the CRC32 of the label modulo `MAX_ID`.
  def self.identify(label : Symbol | String) : Int64
    Digest::CRC32.checksum(label.to_s).to_i64 % MAX_ID
  end

  # The UUID `label` gets, for models with a UUID primary key.
  def self.identify_uuid(label : Symbol | String) : UUID
    UUID.v5(label.to_s, UUID_NAMESPACE)
  end

  # The primary key value of the fixture `label` in the set `name`.
  def self.id_for(name : String, label : Symbol | String) : Int64 | UUID
    registration = @@registrations[name]? || raise Error.new("No fixture set named #{name}; declare it with Grant::TestFixtures.fixtures")
    registration.uuid_key ? identify_uuid(label) : identify(label)
  end

  # Loads the declared sets (or only the named ones) from *directory*.
  #
  # Each set's `<name>.yml` (or `.yaml`) must exist. Per adapter the work runs
  # in one transaction: tables are emptied, then refilled, one bulk `INSERT`
  # per table. Raises `Error` for a missing or malformed file.
  def self.load(directory : String, only : Array(String)? = nil) : Nil
    selected = @@registrations.values
    selected = selected.select { |registration| only.includes?(registration.name) } if only
    raise Error.new("No fixture sets declared; call Grant::TestFixtures.fixtures first") if selected.empty?

    loaded = selected.map { |registration| {registration, read_rows(registration, directory)} }
    loaded.group_by { |(registration, _)| registration.adapter.call.object_id }.each_value do |group|
      adapter = group.first[0].adapter.call
      within_adapter(adapter) do
        group.each { |(registration, _)| delete_all(adapter, registration) }
        group.each { |(registration, rows)| insert_rows(adapter, registration, rows) }
      end
    end
  end

  # Parses one fixture file into rows with typed values and resolved ids.
  # :nodoc:
  def self.read_rows(registration : Registration, directory : String) : Array(Row)
    path = ["yml", "yaml"].map { |ext| File.join(directory, "#{registration.name}.#{ext}") }.find { |candidate| File.exists?(candidate) }
    raise Error.new("Fixture file for #{registration.name} not found in #{directory}") unless path

    document = begin
      YAML.parse(File.read(path))
    rescue ex : YAML::ParseException
      raise Error.new("#{path} is not valid YAML: #{ex.message}")
    end
    return [] of Row if document.raw.nil?
    entries = document.as_h? || raise Error.new("#{path} must map labels to rows")

    rows = [] of Row
    seen_ids = {} of Int64 | UUID => String
    entries.each do |label_node, row_node|
      label = label_node.as_s? || label_node.raw.to_s
      next if label == "DEFAULTS"
      attributes = row_node.as_h? || raise Error.new("#{path}: fixture #{label} must be a mapping")

      values = {} of String => Grant::Columns::Type
      attributes.each { |key, value| assign(registration, values, key.as_s, value) }
      unless values.has_key?(registration.primary_key)
        values[registration.primary_key] = registration.uuid_key ? identify_uuid(label) : identify(label)
      end
      id = values[registration.primary_key].as(Int64 | UUID)
      if other = seen_ids[id]?
        raise Error.new("#{path}: fixtures #{other} and #{label} hash to the same id #{id}")
      end
      seen_ids[id] = label

      rows << Row.new(label, values)
    end
    rows
  end

  private def self.assign(registration : Registration, values : Hash(String, Grant::Columns::Type), key : String, node : YAML::Any) : Nil
    if node.raw.is_a?(String) && (meta = belongs_to_meta(registration, key))
      label = node.as_s
      uuid = @@registrations.each_value.any? { |other| other.model_name == meta[:target_class].name && other.uuid_key }
      values[meta[:foreign_key]] = uuid ? identify_uuid(label) : identify(label)
    elsif key == registration.primary_key && registration.uuid_key && node.raw.is_a?(String)
      values[key] = UUID.new(node.as_s)
    else
      values[key] = typed(node)
    end
  end

  private def self.belongs_to_meta(registration : Registration, key : String)
    return nil if registration.columns.includes?(key)
    meta = Grant::AssociationRegistry.get(registration.model_name, key)
    meta if meta && meta[:type] == :belongs_to
  end

  private def self.typed(node : YAML::Any) : Grant::Columns::Type
    case raw = node.raw
    when Nil, Bool, Int64, Float64, String, Time
      raw
    when Array, Hash
      node.to_json
    else
      raw.to_s
    end
  end

  private def self.within_adapter(adapter : Grant::Adapter::Base, & : ->) : Nil
    if adapter.supports_disable_referential_integrity?
      adapter.disable_referential_integrity { yield }
    else
      Grant::Transaction.run(adapter, Grant::Transaction::Options.new) { yield }
    end
  end

  private def self.delete_all(adapter : Grant::Adapter::Base, registration : Registration) : Nil
    statement = Grant::QueryLogs.append("DELETE FROM #{adapter.quote(registration.table)}")
    elapsed = Time.measure { adapter.open(statement) { |db| db.exec statement } }
    adapter.log statement, elapsed
  end

  # One multi-row INSERT for the whole set, in chunks only when the row count
  # times the column count passes the adapter's bind-parameter cap.
  private def self.insert_rows(adapter : Grant::Adapter::Base, registration : Registration, rows : Array(Row)) : Nil
    return if rows.empty?

    now = Time.utc
    columns = [] of String
    rows.each { |row| row.values.each_key { |key| columns << key unless columns.includes?(key) } }
    ["created_at", "updated_at"].each do |stamp|
      columns << stamp if registration.columns.includes?(stamp) && !columns.includes?(stamp)
    end

    quoted_columns = columns.map { |column| adapter.quote(column) }.join(", ")
    rows.each_slice(adapter.bulk_chunk_rows(columns.size)) do |slice|
      params = [] of Grant::Columns::Type
      tuples = slice.map do |row|
        placeholders = columns.map do |column|
          params << (row.values.has_key?(column) ? row.values[column] : (column.in?("created_at", "updated_at") ? now : nil))
          adapter.parameter_placeholder(params.size)
        end
        "(#{placeholders.join(", ")})"
      end

      statement = Grant::QueryLogs.append("INSERT INTO #{adapter.quote(registration.table)} (#{quoted_columns}) VALUES #{tuples.join(", ")}")
      elapsed = Time.measure do
        adapter.open(statement, params) { |db| db.exec statement, args: adapter.normalize_bind_values(params) }
      end
      adapter.log statement, elapsed, params
    end
  end
end
