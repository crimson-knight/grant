require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6Stamped < Grant::Base
    connection {{ adapter_literal }}
    table w6_stampeds

    column id : Int64, primary: true
    column title : String?
    timestamps precision: 3
  end

  class W6StampedSeconds < Grant::Base
    connection {{ adapter_literal }}
    table w6_stamped_seconds

    column id : Int64, primary: true
    column title : String?
    timestamps precision: 0
  end

  class W6Dated < Grant::Base
    connection {{ adapter_literal }}
    table w6_dateds

    column id : Int64, primary: true
    column title : String?
    date_timestamps
  end

  class W6Switch < Grant::Base
    connection {{ adapter_literal }}
    table w6_switches

    column id : Int64, primary: true
    column title : String?
    timestamps
  end

  class W6SwitchChild < W6Switch
  end
{% end %}

W6Stamped.migrator.drop_and_create
W6StampedSeconds.migrator.drop_and_create
W6Dated.migrator.drop_and_create
W6Switch.migrator.drop_and_create

private def w6_today : Time
  local = Grant::Timestamps.current_time
  Time.utc(local.year, local.month, local.day)
end

describe "Timestamps" do
  before_each do
    W6Stamped.clear
    W6StampedSeconds.clear
    W6Dated.clear
    W6Switch.clear
  end

  describe "precision:" do
    it "truncates stamped values to the declared fractional digits" do
      row = W6Stamped.new(title: "p")
      row.set_timestamps(to: Time.utc(2020, 1, 2, 3, 4, 5, nanosecond: 123_456_789))
      row.created_at.not_nil!.nanosecond.should eq(123_000_000)
      row.updated_at.not_nil!.nanosecond.should eq(123_000_000)

      seconds = W6StampedSeconds.new(title: "p")
      seconds.set_timestamps(to: Time.utc(2020, 1, 2, 3, 4, 5, nanosecond: 999_999_999))
      seconds.created_at.not_nil!.nanosecond.should eq(0)
    end

    it "stores what it stamped, so memory and database agree" do
      row = W6Stamped.create!(title: "p")
      stored = W6Stamped.find!(row.id)
      stored.created_at.not_nil!.to_unix_ms.should eq(row.created_at.not_nil!.to_unix_ms)
      (row.created_at.not_nil!.nanosecond % 1_000_000).should eq(0)
    end

    it "applies to touch as well" do
      row = W6Stamped.create!(title: "p")
      row.touch(time: Time.utc(2021, 6, 7, 8, 9, 10, nanosecond: 987_654_321))
      row.updated_at.not_nil!.nanosecond.should eq(987_000_000)
    end

    it "leaves models without precision: at full resolution" do
      W6Switch.timestamp_precision.should be_nil
      W6Stamped.timestamp_precision.should eq(3)
    end
  end

  describe "created_on / updated_on date columns" do
    it "stamps the current date at midnight UTC and round-trips it" do
      row = W6Dated.create!(title: "d")
      row.created_on.should eq(w6_today)
      row.updated_on.should eq(w6_today)

      stored = W6Dated.find!(row.id)
      stored.created_on.should eq(w6_today)
      stored.created_on.not_nil!.hour.should eq(0)
    end

    it "stamps updated_on only on later saves" do
      row = W6Dated.create!(title: "d")
      row.set_timestamps(to: Time.utc(2000, 1, 1, 12, 30), mode: :update)
      row.created_on.should eq(w6_today)
      row.updated_on.should eq(Time.utc(2000, 1, 1))
    end

    it "touches updated_on with the date of the given time" do
      row = W6Dated.create!(title: "d")
      row.touch(time: Time.utc(2020, 5, 6, 7, 8, 9))
      row.updated_on.should eq(Time.utc(2020, 5, 6))
      W6Dated.find!(row.id).updated_on.should eq(Time.utc(2020, 5, 6))
    end

    it "stamps updated_on with a date in the bulk touch" do
      row = W6Dated.create!(title: "d")
      W6Dated.where(id: row.id).touch_all(time: Time.utc(2022, 3, 4, 5, 6, 7)).should eq(1)
      W6Dated.find!(row.id).updated_on.should eq(Time.utc(2022, 3, 4))
    end

    it "uses the shared clock for the bulk touch default" do
      row = W6Dated.create!(title: "d")
      stamped = W6Stamped.create!(title: "other")
      # Start from an old stamp so the touch changes the row: MySQL counts
      # changed rows, not matched ones.
      stamped.update_columns(updated_at: Time.utc(2000, 1, 1))
      W6Stamped.touch_all.should eq(1)
      W6Stamped.first!.updated_at.not_nil!.should be_close(Grant::Timestamps.current_time, 5.seconds)
      row.id.should_not be_nil
    end
  end

  describe "record_timestamps" do
    after_each do
      W6Switch.record_timestamps = true
    end

    it "is a run-time writer, not only a class-body macro" do
      W6Switch.record_timestamps = false
      W6Switch.record_timestamps?.should be_false
      row = W6Switch.create!(title: "off")
      row.created_at.should be_nil
      row.updated_at.should be_nil

      W6Switch.record_timestamps = true
      W6Switch.record_timestamps?.should be_true
      W6Switch.create!(title: "on").created_at.should_not be_nil
    end

    it "applies to subclasses and to updates" do
      row = W6Switch.create!(title: "x")
      stamp = row.updated_at

      W6Switch.record_timestamps = false
      W6SwitchChild.record_timestamps?.should be_false
      sleep 5.milliseconds
      row.title = "y"
      row.save!
      row.updated_at.should eq(stamp)
    end
  end
end
