require "../../spec_helper"

{% if (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}
  class W6SqliteStamp < Grant::Base
    connection sqlite
    table w6_sqlite_stamps

    column id : Int64, primary: true
    column seen_at : Time?
  end

  W6SqliteStamp.migrator.drop_and_create

  # What the general parser makes of *text*: the reference for the fast path.
  private def w6_reference_time(text : String) : Time
    format = text.includes?(".") ? "%F %H:%M:%S.%N" : SQLite3::DATE_FORMAT_SECOND
    Time.parse(text, format, location: SQLite3::TIME_ZONE).in(Grant.settings.default_timezone)
  end

  private def w6_stored_time(text : String) : Time?
    W6SqliteStamp.clear
    W6SqliteStamp.adapter.open do |db|
      db.exec "INSERT INTO w6_sqlite_stamps (id, seen_at) VALUES (1, ?)", text
    end
    W6SqliteStamp.find!(1_i64).seen_at
  end

  describe "SQLite timestamp reading" do
    [
      "2026-10-01 12:34:56",
      "2026-10-01 12:34:56.1",
      "2026-10-01 12:34:56.123",
      "2026-10-01 12:34:56.123456",
      "2026-10-01 12:34:56.123456789",
      "2026-02-28 23:59:59.999999",
      "2024-02-29 00:00:00",
      "1970-01-01 00:00:00",
      "0001-01-01 00:00:00",
    ].each do |text|
      it "reads #{text} exactly as the general parser does" do
        w6_stored_time(text).should eq(w6_reference_time(text))
      end
    end

    it "keeps every fractional digit of a nanosecond value" do
      stored = w6_stored_time("2026-10-01 12:34:56.123456789").not_nil!
      stored.nanosecond.should eq(123_456_789)
    end

    it "reads a value written by a save back to the same instant" do
      moment = Time.utc(2026, 3, 4, 5, 6, 7, nanosecond: 891_234_000)
      W6SqliteStamp.clear
      saved = W6SqliteStamp.create!(seen_at: moment)

      W6SqliteStamp.find!(saved.id).seen_at.should eq(moment)
    end

    it "falls back to the general parser for text the fast path does not own" do
      expect_raises(Exception) { w6_stored_time("2026-13-45 99:99:99") }
    end
  end
{% else %}
  describe "SQLite timestamp reading" do
    pending "applies to the SQLite adapter only" { }
  end
{% end %}
