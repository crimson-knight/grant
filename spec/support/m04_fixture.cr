require "../spec_helper"

# A schema with every feature the dumper round-trips: types, defaults,
# comments, auto and composite primary keys, partial, expression, descending and
# unique indexes, foreign keys with actions, a foreign key cycle, a self
# reference, check and unique constraints, and on PostgreSQL enums, arrays,
# jsonb/gin, operator classes, INCLUDE, deferrable keys and exclusions.
module M04Fixture
  TABLES = %w(m04_dump_cycle_a m04_dump_cycle_b m04_dump_notes m04_dump_memberships m04_dump_accounts m04_dump_pg)
  # Every table that is not the fixture's is left out of the dump.
  ONLY_FIXTURE = [/\A(?!m04_dump_)/] of (String | Regex)

  def self.adapter : Grant::Adapter::Base
    Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER)
  end

  def self.pg? : Bool
    CURRENT_ADAPTER == "pg"
  end

  def self.statements : Grant::Schema::AdapterStatements
    Grant::Schema::AdapterStatements.new(adapter)
  end

  def self.drop! : Nil
    drop_all = -> { statements.drop_table(:m04_dump_cycle_a, :m04_dump_cycle_b, :m04_dump_notes, :m04_dump_memberships, :m04_dump_accounts, :m04_dump_pg, if_exists: true, cascade: true) }
    if CURRENT_ADAPTER == "mysql"
      # MySQL ignores CASCADE; the cyclic keys need foreign key checks off, on one connection.
      adapter.with_connection do |connection|
        connection.exec "SET FOREIGN_KEY_CHECKS = 0"
        begin
          drop_all.call
        ensure
          connection.exec "SET FOREIGN_KEY_CHECKS = 1"
        end
      end
    else
      drop_all.call
    end
    adapter.open { |db| db.exec "DROP TYPE IF EXISTS m04_mood CASCADE" } if pg?
    adapter.reset_schema_caches!
  end

  def self.create! : Nil
    drop!
    s = statements
    s.create_enum(:m04_mood, ["happy", "sad"]) if pg?
    s.create_table(:m04_dump_accounts, comment: "Customer accounts") do |t|
      t.string :name, null: false, limit: 80, comment: "Display name"
      t.decimal :balance, precision: 12, scale: 2, null: false, default: 0
      t.string :status, null: false, default: "active"
      t.text :notes
      t.boolean :active, null: false, default: true
      t.timestamps
      if CURRENT_ADAPTER == "mysql"
        t.index :status, name: "idx_m04_accounts_status"
      else
        t.index :status, name: "idx_m04_accounts_status", where: "status <> 'closed'"
      end
      t.index "lower(name)", name: "idx_m04_accounts_lower_name", unique: true
      t.check_constraint "balance >= 0", name: "chk_m04_balance"
      t.unique_constraint [:name, :status], name: "uniq_m04_name_status"
    end
    s.create_table(:m04_dump_memberships, id: false, primary_key: [:account_id, :member_id]) do |t|
      t.bigint :account_id
      t.bigint :member_id
      t.string :role, null: false, default: "member"
      t.index :member_id
      if pg?
        t.foreign_key :m04_dump_accounts, column: :account_id, on_delete: :cascade, on_update: :restrict, deferrable: :deferred
      else
        t.foreign_key :m04_dump_accounts, column: :account_id, on_delete: :cascade, on_update: :restrict
      end
    end
    s.create_table(:m04_dump_notes) do |t|
      t.references :account, foreign_key: {to_table: :m04_dump_accounts, on_delete: :cascade}
      t.bigint :parent_id
      t.string :slug, limit: 40
      t.datetime :posted_at, precision: 3
      t.index [:slug, :account_id], name: "idx_m04_notes_slug_account", unique: true
      t.index :posted_at, name: "idx_m04_notes_posted_desc", order: :desc
      t.foreign_key :m04_dump_notes, column: :parent_id, on_delete: :set_null
    end
    s.create_table(:m04_dump_cycle_a) { |t| t.bigint :b_id }
    s.create_table(:m04_dump_cycle_b) do |t|
      t.bigint :a_id
      t.foreign_key :m04_dump_cycle_a, column: :a_id
    end
    s.add_foreign_key :m04_dump_cycle_a, :m04_dump_cycle_b, column: :b_id
    if pg?
      s.create_table(:m04_dump_pg, id: :uuid, comment: "PostgreSQL only") do |t|
        t.enum :mood, enum_type: :m04_mood, null: false, default: "happy"
        t.text :code, null: false
        t.string :slug, limit: 30
        t.text :tags, array: true
        t.jsonb :data
        t.index :data, name: "idx_m04_pg_data", using: :gin
        t.index :code, name: "idx_m04_pg_code_cover", include: [:slug]
        t.index :slug, name: "idx_m04_pg_slug_ops", opclass: "text_pattern_ops", comment: "prefix search"
        t.exclusion_constraint "code WITH =", using: :btree, name: "excl_m04_code"
      end
    end
    adapter.reset_schema_caches!
  end

  # Column, index, key and constraint facts of the fixture tables, read back
  # from the catalog, for comparing two databases.
  def self.fingerprint : Array(String)
    adapter.reset_schema_caches!
    schema = adapter.schema
    lines = [] of String
    TABLES.sort.each do |table|
      next unless schema.table_exists?(table)
      schema.columns(table).each do |c|
        lines << "col #{table}.#{c.name} #{c.sql_type} null=#{c.null?} default=#{c.default.inspect} pk=#{c.primary_key_position} comment=#{c.comment.inspect}"
      end
      schema.indexes(table).sort_by(&.name).each { |i| lines << "idx #{table}.#{i.name} #{i.columns} unique=#{i.unique?} where=#{i.where.inspect}" }
      schema.foreign_keys(table).sort_by { |k| k.columns.join(",") }.each do |k|
        lines << "fk #{table} #{k.columns} -> #{k.to_table}#{k.primary_key_columns} del=#{k.on_delete} upd=#{k.on_update}"
      end
      schema.check_constraints(table).each { |c| lines << "chk #{table} #{c.name} #{c.expression}" }
      schema.unique_constraints(table).each { |u| lines << "uniq #{table} #{u.columns} #{u.deferrable?}" }
      schema.exclusion_constraints(table).each { |e| lines << "excl #{table} #{e.name} #{e.definition}" }
      lines << "comment #{table} #{schema.table_comment(table).inspect}"
    end
    lines
  end
end
