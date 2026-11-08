require "spec"

{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "./spec_helper"

def assert_filename(uri, filename)
  Grant::SQLite3::Connection.filename(URI.parse(uri)).should eq(filename)
end

describe Grant::SQLite3::Driver do
  it "should register sqlite3 name" do
    DB.driver_class("sqlite3").should eq(Grant::SQLite3::Driver)
  end

  it "should get filename from uri" do
    assert_filename("sqlite3:%3Amemory%3A", ":memory:")
    assert_filename("sqlite3://%3Amemory%3A", ":memory:")

    assert_filename("sqlite3:./file.db", "./file.db")
    assert_filename("sqlite3://./file.db", "./file.db")

    assert_filename("sqlite3:/path/to/file.db", "/path/to/file.db")
    assert_filename("sqlite3:///path/to/file.db", "/path/to/file.db")

    assert_filename("sqlite3:./file.db?max_pool_size=5", "./file.db")
    assert_filename("sqlite3:/path/to/file.db?max_pool_size=5", "/path/to/file.db")
    assert_filename("sqlite3://./file.db?max_pool_size=5", "./file.db")
    assert_filename("sqlite3:///path/to/file.db?max_pool_size=5", "/path/to/file.db")
  end

  it "should use database option as file to open" do
    with_sqlite_driver_db do |db|
      db.checkout.should be_a(Grant::SQLite3::Connection)
      File.exists?(SQLITE_DRIVER_DB_FILENAME).should be_true
    end
  end
end
