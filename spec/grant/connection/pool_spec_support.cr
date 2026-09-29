require "../../spec_helper"
require "file_utils"

# Helpers shared by the connection pool specs. They run against whichever
# adapter CURRENT_ADAPTER selects, so the same example proves the behavior on
# SQLite and on PostgreSQL.
module C02Support
  def self.adapter_class : Grant::Adapter::Base.class
    case CURRENT_ADAPTER
    when "pg"    then Grant::Adapter::Pg
    when "mysql" then Grant::Adapter::Mysql
    else              Grant::Adapter::Sqlite
    end
  end

  # A URL for the adapter under test. SQLite gets its own file per *name* so
  # pool teardown in one example never touches another's database.
  def self.url(name : String) : String
    CURRENT_ADAPTER == "sqlite" ? "sqlite3:#{File.join(dir, "#{name}.sqlite3")}" : ADAPTER_URL
  end

  # A URL nothing listens on, for the adapter under test.
  def self.unreachable_url : String
    case CURRENT_ADAPTER
    when "pg"    then "postgres://localhost:1/c02_unreachable"
    when "mysql" then "mysql://localhost:1/c02_unreachable"
    else              "sqlite3:/c02_no_such_directory/unreachable.sqlite3"
    end
  end

  def self.dir : String
    path = File.join(Dir.tempdir, "c02_pool_#{Process.pid}")
    Dir.mkdir_p(path)
    path
  end

  def self.cleanup : Nil
    FileUtils.rm_rf(File.join(Dir.tempdir, "c02_pool_#{Process.pid}"))
  end

  def self.establish(database : String, role : Symbol = :writing, **options) : Grant::Adapter::Base
    Grant::ConnectionRegistry.establish_connection(**options, database: database, adapter: adapter_class, url: url(database), role: role)
    Grant::ConnectionRegistry.get_adapter(database, role)
  end
end
