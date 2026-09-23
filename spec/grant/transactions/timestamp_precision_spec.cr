require "../../spec_helper"

class TimestampPrecisionRecord < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table timestamp_precision_records

  column id : Int64, primary: true
  column label : String
  timestamps
end

describe "timestamp precision" do
  before_all do
    TimestampPrecisionRecord.migrator.drop_and_create
  end

  before_each do
    Grant.settings.default_timezone = "UTC"
    TimestampPrecisionRecord.clear
  end

  it "preserves microseconds when timestamps are saved and reloaded" do
    timestamp = Time.utc(2020, 1, 1) + 123_456.microseconds
    record = TimestampPrecisionRecord.new(label: "fixed")
    record.set_timestamps(to: timestamp)
    record.created_at.should eq(timestamp)
    record.updated_at.should eq(timestamp)
    record.save!(skip_timestamps: true)

    reloaded = TimestampPrecisionRecord.find!(record.id.not_nil!)
    reloaded.created_at.should eq(timestamp)
    reloaded.updated_at.should eq(timestamp)
  end

  it "keeps subsecond precision when touching timestamps" do
    old_timestamp = Time.utc(2020, 1, 1) + 123_456.microseconds
    record = TimestampPrecisionRecord.new(label: "touch")
    record.set_timestamps(to: old_timestamp)
    record.save!(skip_timestamps: true)
    record.touch.should be_true

    updated_at = TimestampPrecisionRecord.find!(record.id.not_nil!).updated_at.not_nil!
    updated_at.should be > old_timestamp
    updated_at.nanosecond.should be > 0
  end
end
