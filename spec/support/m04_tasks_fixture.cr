require "../spec_helper"
require "file_utils"

# Databases of their own for the database task specs: a scratch SQLite file or
# a scratch PostgreSQL database on the spec server, so creating, dropping and
# purging never touch the shared spec database.
module M04Tasks
  def self.url(name : String) : String
    case CURRENT_ADAPTER
    when "pg"
      ADAPTER_URL.sub(/\/[^\/?]+(\?|\z)/, "/#{name}\\1")
    when "sqlite"
      "sqlite3:#{File.join(Dir.tempdir, "#{name}.sqlite3")}"
    else
      raise "M04 task specs need a scratch database for #{CURRENT_ADAPTER}"
    end
  end

  # A unique scratch database name.
  def self.unique_name : String
    "grant_w5_m04_t_#{Random::Secure.hex(4)}"
  end

  def self.tasks(name : String, environment : String = "development", **options) : Grant::Tasks::Database
    Grant::Tasks::Database.new(url(name), environment, **options)
  end

  # Runs the block with scratch tasks, dropping the database afterward.
  def self.with_tasks(environment : String = "development", **options, & : Grant::Tasks::Database ->) : Nil
    name = unique_name
    tasks = tasks(name, environment, **options)
    begin
      yield tasks
    ensure
      tasks.drop(force: true)
    end
  end

  def self.table?(tasks : Grant::Tasks::Database, name : String) : Bool
    tasks.adapter.reset_schema_caches!
    tasks.adapter.schema.table_exists?(name)
  end

  def self.count(tasks : Grant::Tasks::Database, table : String) : Int64
    tasks.adapter.open { |db| db.scalar("SELECT COUNT(*) FROM #{table}").as(Int).to_i64 }
  end
end

class M04TaskCreateWidgets < Grant::Schema::Migration
  migration_version 20260101000001

  def change
    create_table :m04_task_widgets do |t|
      t.string :title, null: false
    end
  end
end

class M04TaskCreateGadgets < Grant::Schema::Migration
  migration_version 20260101000002

  def change
    create_table :m04_task_gadgets do |t|
      t.references :widget, foreign_key: {to_table: :m04_task_widgets}
    end
  end
end

class M04TaskAddColorToGadgets < Grant::Schema::Migration
  migration_version 20260101000003

  def change
    add_column :m04_task_gadgets, :color, :string
  end
end

# The schema those first two migrations produce, as a dump file would hold it.
Grant::Schema.define(version: 20260101000002, source: "db_m04/schema.cr") do |schema|
  schema.create_table "m04_task_widgets", id: :bigint, force: :cascade do |t|
    t.string "title", null: false
  end

  schema.create_table "m04_task_gadgets", id: :bigint, force: :cascade do |t|
    t.bigint "widget_id"
    t.index ["widget_id"]
    t.foreign_key "m04_task_widgets", column: "widget_id"
  end
end

Grant::Seeds.define("db_m04/seeds.cr") do
  Grant::Seeds.load_once("m04-widget") do
    Grant::Seeds.default_adapter.open { |db| db.exec "INSERT INTO m04_task_widgets (title) VALUES ('seeded')" }
  end
end

M04_TASK_MIGRATIONS = [M04TaskCreateWidgets.entry, M04TaskCreateGadgets.entry, M04TaskAddColorToGadgets.entry]
