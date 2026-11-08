{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../spec_helper"

enum EncoderSpec::Status
  Open
  Closed
end

private def test_insert_and_read(datatype, value, file = __FILE__, line = __LINE__)
  it "inserts #{datatype}", file, line do
    PG_DRIVER_DB.exec "drop table if exists test_table"
    PG_DRIVER_DB.exec "create table test_table (v #{datatype})"
    # Grant: this one SQL text meets a differently typed table on every example,
    # and a named statement keeps its first parameter types, so it stays unnamed.
    PG_DRIVER_DB.unprepared.exec "insert into test_table values ($1)", args: [value]

    # Read casting the value
    actual_value = PG_DRIVER_DB.query_one "select v from test_table", as: value.class
    actual_value.should eq(value)
  end
end

describe Grant::PG::Driver, "encoder" do
  test_insert_and_read "int4", 123

  test_insert_and_read "float", 12.34

  test_insert_and_read "varchar", "hello world"

  test_insert_and_read "timestamp", Time.utc(2015, 2, 3, 17, 15, nanosecond: 13_000_000)
  test_insert_and_read "timestamp", Time.utc(2015, 2, 3, 17, 15, 13, nanosecond: 11_000_000)
  test_insert_and_read "timestamp", Time.utc(2015, 2, 3, 17, 15, 13, nanosecond: 123_456_000)
  test_insert_and_read "timestamptz", Time.local(2019, 8, 13, 12, 30, location: Time::Location.fixed(-14_400))

  test_insert_and_read "int4", EncoderSpec::Status::Open
  test_insert_and_read "int4", EncoderSpec::Status::Closed

  test_insert_and_read "bool[]", [true, false, true]

  test_insert_and_read "float[]", [1.2, 3.4, 5.6]

  test_insert_and_read "integer[]", [] of Int32
  test_insert_and_read "integer[]", [1, 2, 3]
  test_insert_and_read "integer[]", [[1, 2], [3, 4]]

  test_insert_and_read "text[]", ["t", "f", "t"]
  test_insert_and_read "text[]", [%("a), %(\\b~), %(c\\"d), %(\uFF8F)]
  test_insert_and_read "text[]", ["baz, bar"]
  test_insert_and_read "text[]", ["foo}"]

  test_insert_and_read "interval", Grant::PG::Interval.new
  test_insert_and_read "interval", Grant::PG::Interval.new(days: 400, microseconds: 5000000)

  describe "geo" do
    test_insert_and_read "point", Grant::PG::Geo::Point.new(1.2, 3.4)
    if PgDriverSpecHelper.db_version_gte(9, 4)
      test_insert_and_read "line", Grant::PG::Geo::Line.new(1.2, 3.4, 5.6)
    end
    test_insert_and_read "circle", Grant::PG::Geo::Circle.new(1.2, 3.4, 5.6)
    test_insert_and_read "lseg", Grant::PG::Geo::LineSegment.new(1.2, 3.4, 5.6, 7.8)
    test_insert_and_read "box", Grant::PG::Geo::Box.new(1.2, 3.4, 5.6, 7.8)
    test_insert_and_read "path", Grant::PG::Geo::Path.new([
      Grant::PG::Geo::Point.new(1.2, 3.4),
      Grant::PG::Geo::Point.new(5.6, 7.8),
    ], closed: false)
    test_insert_and_read "path", Grant::PG::Geo::Path.new([
      Grant::PG::Geo::Point.new(1.2, 3.4),
      Grant::PG::Geo::Point.new(5.6, 7.8),
    ], closed: true)
    test_insert_and_read "polygon", Grant::PG::Geo::Polygon.new([
      Grant::PG::Geo::Point.new(1.2, 3.4),
      Grant::PG::Geo::Point.new(5.6, 7.8),
    ])
  end
end
