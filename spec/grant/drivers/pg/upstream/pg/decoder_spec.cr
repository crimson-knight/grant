{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "uuid"
require "../spec_helper"

describe Grant::PG::Decoders do
  #           name,             sql,              result
  test_pg_driver_decode "undefined    ", "'what'         ", "what"
  test_pg_driver_decode "text         ", "'what'::text   ", "what"
  test_pg_driver_decode "varchar      ", "'wh'::varchar  ", "wh"
  test_pg_driver_decode "empty strings", "''             ", ""
  test_pg_driver_decode "null as nil  ", "null           ", nil
  test_pg_driver_decode "boolean false", "false          ", false
  test_pg_driver_decode "boolean true ", "true           ", true
  test_pg_driver_decode "int2 smallint", "1::int2        ", 1
  test_pg_driver_decode "int2 smallint", "-1::int2       ", -1
  test_pg_driver_decode "int4 int     ", "1::int4        ", 1
  test_pg_driver_decode "int4 int     ", "-1::int4       ", -1
  test_pg_driver_decode "int8 bigint  ", "1::int8        ", 1
  test_pg_driver_decode "int8 bigint  ", "-1::int8       ", -1
  test_pg_driver_decode "bigint       ", "12928394059603 ", 12928394059603
  test_pg_driver_decode "bigint       ", "-12928394059603", -12928394059603
  test_pg_driver_decode "float        ", "0.123::float   ", 0.123
  test_pg_driver_decode "float        ", "-0.123::float  ", -0.123
  test_pg_driver_decode "regtype      ", "pg_typeof(3)   ", 23

  test_pg_driver_decode "uint64       ", "'FFFFFFFF/FFFFFFFF'::pg_lsn", 18446744073709551615_u64

  test_pg_driver_decode "double prec.", "'35.03554004971999'::float8", 35.03554004971999
  test_pg_driver_decode "flot prec.", "'0.10000122'::float4", 0.10000122_f32

  test_pg_driver_decode "bytea", "E'\\\\001\\\\134\\\\176'::bytea",
    Slice(UInt8).new(UInt8[0o001, 0o134, 0o176].to_unsafe, 3)
  test_pg_driver_decode "bytea", "E'\\\\005\\\\000\\\\377\\\\200'::bytea",
    Slice(UInt8).new(UInt8[5, 0, 255, 128].to_unsafe, 4)
  test_pg_driver_decode "bytea empty", "E''::bytea",
    Slice(UInt8).new(UInt8[].to_unsafe, 0)

  test_pg_driver_decode "uuid", "'7d61d548124c4b38bc05cfbb88cfd1d1'::uuid",
    UUID.new("7d61d548-124c-4b38-bc05-cfbb88cfd1d1")
  test_pg_driver_decode "uuid", "'7d61d548-124c-4b38-bc05-cfbb88cfd1d1'::uuid",
    UUID.new("7d61d548-124c-4b38-bc05-cfbb88cfd1d1")

  if PgDriverSpecHelper.db_version_gte(9, 2)
    test_pg_driver_decode "json", %('[1,"a",true]'::json), JSON::PullParser.new(%([1,"a",true]))
    test_pg_driver_decode "json", %('{"a":1}'::json), JSON::PullParser.new(%({"a":1}))
  end
  if PgDriverSpecHelper.db_version_gte(9, 4)
    test_pg_driver_decode "jsonb", "'[1,2,3]'::jsonb", JSON::PullParser.new("[1,2,3]")
  end

  test_pg_driver_decode "timestamptz", "'2015-02-03 16:15:13-01'::timestamptz",
    Time.utc(2015, 2, 3, 17, 15, 13)

  test_pg_driver_decode "timestamptz", "'2015-02-03 16:15:14.23-01'::timestamptz",
    Time.utc(2015, 2, 3, 17, 15, 14, nanosecond: 230_000_000)

  test_pg_driver_decode "timestamptz", "'2015-02-03 16:15:14.23 America/New_York'::timestamptz",
    Time.local(2015, 2, 3, 16, 15, 14, nanosecond: 230_000_000, location: Time::Location.load("America/New_York")),
    time_zone: Time::Location.load("America/New_York")

  test_pg_driver_decode "timestamp", "'2015-02-03 16:15:15'::timestamp",
    Time.utc(2015, 2, 3, 16, 15, 15)

  test_pg_driver_decode "date", "'2015-02-03'::date",
    Time.utc(2015, 2, 3, 0, 0, 0)

  # -14706000000 = microseconds in -4 hours, -5 minutes -6 seconds
  test_pg_driver_decode "interval", "'P-1Y-2M3DT-4H-5M-6S'::interval", Grant::PG::Interval.new(-14706000000, 3, -14)
  test_pg_driver_decode "interval", "'178000000 years'::interval", Grant::PG::Interval.new(0, 0, 2_136_000_000)
  test_pg_driver_decode "interval", "'178000000 years 1 months 5 days 999999 microseconds'::interval", Grant::PG::Interval.new(999_999, 5, 2_136_000_001)

  it "numeric" do
    x = ->(q : String) do
      PG_DRIVER_DB.query_one "select '#{q}'::numeric", &.read(Grant::PG::Numeric)
    end
    x.call("1.3").to_f.should eq(1.3)
    x.call("nan").nan?.should be_true
  end

  it "decodes many uuids (#148)" do
    uuid = UUID.new("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ids = PG_DRIVER_DB.query_all("select '#{uuid}'::uuid from generate_series(1,1000)", as: UUID)
    ids.uniq.should eq([uuid])
  end

  test_pg_driver_decode "xml", "'<json>false</json>'::xml", "<json>false</json>"
  test_pg_driver_decode "char", %('c'::"char"), 'c'
  test_pg_driver_decode "bpchar", %('c'::char), "c"
  test_pg_driver_decode "bpchar", %('c'::char(5)), "c    "
  test_pg_driver_decode "name", %('hi'::name), "hi"
  test_pg_driver_decode "oid", %(2147483648::oid), 2147483648_u32
  test_pg_driver_decode "point", "'(1.2,3.4)'::point", Grant::PG::Geo::Point.new(1.2, 3.4)
  if PgDriverSpecHelper.db_version_gte(9, 4)
    test_pg_driver_decode "line ", "'(1,2,3,4)'::line ", Grant::PG::Geo::Line.new(1.0, -1.0, 1.0)
    test_pg_driver_decode "line ", "'1,2,3'::circle   ", Grant::PG::Geo::Circle.new(1.0, 2.0, 3.0)
  end
  test_pg_driver_decode "lseg ", "'(1,2,3,4)'::lseg ", Grant::PG::Geo::LineSegment.new(1.0, 2.0, 3.0, 4.0)
  test_pg_driver_decode "box  ", "'(1,2,3,4)'::box  ", Grant::PG::Geo::Box.new(1.0, 2.0, 3.0, 4.0)
  test_pg_driver_decode "path ", "'(1,2,3,4)'::path ", Grant::PG::Geo::Path.new([Grant::PG::Geo::Point.new(1.0, 2.0), Grant::PG::Geo::Point.new(3.0, 4.0)], closed: true)
  test_pg_driver_decode "path ", "'[1,2,3,4,5,6]'::path", Grant::PG::Geo::Path.new([Grant::PG::Geo::Point.new(1.0, 2.0), Grant::PG::Geo::Point.new(3.0, 4.0), Grant::PG::Geo::Point.new(5.0, 6.0)], closed: false)
  test_pg_driver_decode "polygon", "'1,2,3,4,5,6'::polygon", Grant::PG::Geo::Polygon.new([Grant::PG::Geo::Point.new(1.0, 2.0), Grant::PG::Geo::Point.new(3.0, 4.0), Grant::PG::Geo::Point.new(5.0, 6.0)])
end
