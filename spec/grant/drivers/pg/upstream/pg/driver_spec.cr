require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../spec_helper"

def assert_single_read(rs, value_type, value)
  rs.move_next.should be_true
  rs.read(value_type).should eq(value)
  rs.move_next.should be_false
end

class NotSupportedType
end

struct StructWithMapping
  include DB::Serializable

  property a : Int32
  property b : Int32
end

describe Grant::PG::Driver do
  it "should register postgres name" do
    DB.driver_class("postgres").should eq(Grant::PG::Driver)
  end

  it "exectes and selects value" do
    PG_DRIVER_DB.query "select 123::int4" do |rs|
      assert_single_read rs, Int32, 123
    end
  end

  it "gets column count" do
    PG_DRIVER_DB.query "select 1::int4, 1::int4" do |rs|
      rs.column_count.should eq(2)
    end
  end

  it "gets column names" do
    PG_DRIVER_DB.query "select 1::int4 as foo, 1::int4 as bar" do |rs|
      rs.column_name(0).should eq("foo")
      rs.column_name(1).should eq("bar")
    end
  end

  it "should raise an exception if unique constraint is violated" do
    expect_raises(Grant::PQ::PQError) do
      PG_DRIVER_DB.exec "drop table if exists contacts"
      PG_DRIVER_DB.exec "create table contacts (name varchar(256), CONSTRAINT key_name UNIQUE(name))"

      result = PG_DRIVER_DB.query "insert into contacts values ($1)", "Foo"
      result = PG_DRIVER_DB.query "insert into contacts values ($1)", "Foo" do |rs|
        rs.move_next
      end
    end
  end

  it "executes insert" do
    PG_DRIVER_DB.exec "drop table if exists contacts"
    PG_DRIVER_DB.exec "create table contacts (name varchar(256), age int4)"

    result = PG_DRIVER_DB.exec "insert into contacts values ($1, $2)", "Foo", 10

    result.last_insert_id.should eq(0) # postgres doesn't support this
    result.rows_affected.should eq(1)
  end

  it "executes insert via query" do
    PG_DRIVER_DB.query("drop table if exists contacts") do |rs|
      rs.move_next.should be_false
    end
  end

  it "executes update" do
    PG_DRIVER_DB.exec "drop table if exists contacts"
    PG_DRIVER_DB.exec "create table contacts (name varchar(256), age int4)"

    PG_DRIVER_DB.exec "insert into contacts values ($1, $2)", "Foo", 10
    PG_DRIVER_DB.exec "insert into contacts values ($1, $2)", "Baz", 10
    PG_DRIVER_DB.exec "insert into contacts values ($1, $2)", "Baz", 20

    result = PG_DRIVER_DB.exec "update contacts set age = 30 where age = 10"

    result.last_insert_id.should eq(0) # postgres doesn't support this
    result.rows_affected.should eq(2)
  end

  it "traverses result set" do
    PG_DRIVER_DB.exec "drop table if exists contacts"
    PG_DRIVER_DB.exec "create table contacts (name varchar(256), age int4)"

    PG_DRIVER_DB.exec "insert into contacts values ($1, $2)", "Foo", 10
    PG_DRIVER_DB.exec "insert into contacts values ($1, $2)", "Bar", 20

    PG_DRIVER_DB.query "select name, age from contacts order by age" do |rs|
      rs.move_next.should be_true
      rs.read(String).should eq("Foo")
      rs.move_next.should be_true
      rs.read(String).should eq("Bar")
      rs.move_next.should be_false
    end
  end

  it "treats Slice(UInt8) as String" do
    with_pg_driver_db do |db|
      # Grant: a server built without contrib modules has no citext to test against.
      begin
        db.exec "create extension if not exists citext with schema public"
      rescue error : Grant::PQ::PQError
        next if error.message.to_s.includes?("citext")

        raise error
      end
      db.exec "drop table if exists users"
      db.exec "create table users (email citext)"
      db.exec "insert into users values ($1)", "foo@example.com"

      db.query "select email from users limit 1" do |rs|
        assert_single_read rs, String, "foo@example.com"
      end

      db.query "select email from users limit 1" do |rs|
        assert_single_read rs, String?, "foo@example.com"
      end

      # Grant: this database is shared with the whole suite, and schema dumps list
      # installed extensions, so nothing from this spec may stay behind.
      db.exec "drop table users"
      db.exec "drop extension citext"
    end
  end

  it "converts json result into JSON::Any if requested" do
    with_pg_driver_db do |db|
      db.exec "drop table if exists users"
      db.exec "create table users (properties jsonb)"
      db.exec "insert into users values ($1)", "{\"hello\": \"world\"}"

      db.query "select properties from users limit 1" do |rs|
        assert_single_read rs, JSON::Any, JSON.parse("{\"hello\": \"world\"}")
      end
    end
  end

  describe "transactions" do
    it "can read inside transaction and rollback after" do
      with_pg_driver_db do |db|
        db.exec "drop table if exists person"
        db.exec "create table person (name varchar(25))"
        db.transaction do |tx|
          tx.connection.scalar("select count(*) from person").should eq(0)
          tx.connection.exec "insert into person (name) values ($1)", "John Doe"
          tx.connection.scalar("select count(*) from person").should eq(1)
          tx.rollback
        end
        db.scalar("select count(*) from person").should eq(0)
      end
    end

    it "can read inside transaction or after commit" do
      with_pg_driver_db do |db|
        db.exec "drop table if exists person"
        db.exec "create table person (name varchar(25))"
        db.transaction do |tx|
          tx.connection.scalar("select count(*) from person").should eq(0)
          tx.connection.exec "insert into person (name) values ($1)", "John Doe"
          tx.connection.scalar("select count(*) from person").should eq(1)
          # using other connection
          db.scalar("select count(*) from person").should eq(0)
        end
        db.scalar("select count(*) from person").should eq(1)
      end
    end
  end

  describe "nested transactions" do
    it "can read inside transaction and rollback after" do
      with_pg_driver_db do |db|
        db.exec "drop table if exists person"
        db.exec "create table person (name varchar(25))"
        db.transaction do |tx_0|
          tx_0.connection.scalar("select count(*) from person").should eq(0)
          tx_0.connection.exec "insert into person (name) values ($1)", "John Doe"
          tx_0.transaction do |tx_1|
            tx_1.connection.exec "insert into person (name) values ($1)", "Sarah"
            tx_1.connection.scalar("select count(*) from person").should eq(2)
            tx_1.transaction do |tx_2|
              tx_2.connection.exec "insert into person (name) values ($1)", "Jimmy"
              tx_2.connection.scalar("select count(*) from person").should eq(3)
              tx_2.rollback
            end
          end
          tx_0.connection.scalar("select count(*) from person").should eq(2)
          tx_0.rollback
        end
        db.scalar("select count(*) from person").should eq(0)
      end
    end
  end

  describe "move_next" do
    it "properly skips null columns" do
      no_nulls = StructWithMapping.from_rs(PG_DRIVER_DB.query("select 1 as a, 1 as b")).first
      {no_nulls.a, no_nulls.b}.should eq({1, 1})
      err = DB::MappingException

      expect_raises(err, "In Grant::PG::ResultSet#read the column b returned a Nil but a Int32 was expected.") do
        StructWithMapping.from_rs(PG_DRIVER_DB.query("select 2 as a, null as b"))
      end

      # importantly not an IndexError: Index out of bounds
      expect_raises(err, "In Grant::PG::ResultSet#read the column a returned a Nil but a Int32 was expected.") do
        StructWithMapping.from_rs(PG_DRIVER_DB.query("select null as a, null as b"))
      end
    end
  end
end
