require "../spec_helper"
require "file_utils"

# Helpers for the M03 migration runner specs: a clean database, contexts over
# it, a second database, and a scratch directory of migration files.
module M03Fixture
  TABLES = %w(m03_users m03_posts m03_tags m03_comments m03_widgets m03_micrate_users m03_micrate_posts m03_atomic
    m03_sql_one m03_sql_two m03_lock_rows m03_tenant_items m03_a m03_b m03_c m03_d m03_join_a_m03_join_b
    m03_joins m03_revert m03_dry)
  TRACKING = %w(schema_migrations micrate_db_version ar_internal_metadata)

  def self.adapter : Grant::Adapter::Base
    Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER)
  end

  def self.reset!(target : Grant::Adapter::Base = adapter) : Nil
    (TABLES + TRACKING).each do |table|
      target.open { |db| db.exec "DROP TABLE IF EXISTS #{table}" }
    end
    target.reset_schema_caches!
  end

  def self.table?(name : String, target : Grant::Adapter::Base = adapter) : Bool
    target.reset_schema_caches!
    target.schema.table_exists?(name)
  end

  def self.column?(table : String, column : String, target : Grant::Adapter::Base = adapter) : Bool
    target.reset_schema_caches!
    target.schema.table_exists?(table) && target.schema.columns(table).any? { |info| info.name == column }
  end

  def self.versions(target : Grant::Adapter::Base = adapter, tracking : Grant::Schema::Tracking = Grant::Schema::Tracking::Grant) : Array(Int64)
    Grant::Schema::SchemaMigration.new(target, tracking).versions.to_a.sort!
  end

  # A scratch directory that is removed after the block.
  def self.tmpdir(& : String -> T) : T forall T
    dir = File.join(Dir.tempdir, "m03_#{Random::Secure.hex(6)}")
    Dir.mkdir_p(dir)
    begin
      yield dir
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # A second, empty database of the same kind: another SQLite file, or another
  # PostgreSQL or MySQL database on the same server.
  def self.with_second_adapter(& : Grant::Adapter::Base -> T) : T forall T
    name = "m03_second_#{Random::Secure.hex(4)}"
    case CURRENT_ADAPTER
    when "pg"
      adapter.open { |db| db.exec "DROP DATABASE IF EXISTS #{name}" }
      adapter.open { |db| db.exec "CREATE DATABASE #{name}" }
      url = ADAPTER_URL.sub(/\/[^\/?]+(\?|\z)/, "/#{name}\\1")
      second = Grant::Adapter::Pg.new(name: name, url: url)
      begin
        yield second
      ensure
        second.disconnect!
        adapter.open { |db| db.exec "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '#{name}' AND pid <> pg_backend_pid()" }
        adapter.open { |db| db.exec "DROP DATABASE IF EXISTS #{name}" }
      end
    when "mysql"
      adapter.open { |db| db.exec "DROP DATABASE IF EXISTS #{name}" }
      adapter.open { |db| db.exec "CREATE DATABASE #{name}" }
      url = ADAPTER_URL.sub(/\/[^\/?]+(\?|\z)/, "/#{name}\\1")
      second = Grant::Adapter::Mysql.new(name: name, url: url)
      begin
        yield second
      ensure
        second.disconnect!
        adapter.open { |db| db.exec "DROP DATABASE IF EXISTS #{name}" }
      end
    when "sqlite"
      path = File.join(Dir.tempdir, "#{name}.sqlite3")
      second = Grant::Adapter::Sqlite.new(name: name, url: "sqlite3:#{path}")
      begin
        yield second
      ensure
        second.disconnect!
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    else
      raise "M03 specs need a second database for #{CURRENT_ADAPTER}"
    end
  end
end

# Migrations shared by the M03 specs.
class M03CreateUsers < Grant::Schema::Migration
  migration_version 20240101000001

  def change
    create_table :m03_users do |t|
      t.string :email, null: false
      t.timestamps
    end
  end
end

class M03AddAgeToUsers < Grant::Schema::Migration
  migration_version 20240101000002

  def change
    add_column :m03_users, :age, :integer
    add_index :m03_users, :email, unique: true
  end
end

class M03CreatePosts < Grant::Schema::Migration
  migration_version 20240101000003

  def up
    create_table :m03_posts do |t|
      t.string :title
    end
  end

  def down
    drop_table :m03_posts
  end
end
