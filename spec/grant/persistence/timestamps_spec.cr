require "../../spec_helper"
require "../../support/write_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class StampedRow < Grant::Base
    connection {{ adapter_literal }}
    table stamped_rows

    column id : Int64, primary: true
    column name : String?
    timestamps
  end

  class UnstampedRow < Grant::Base
    connection {{ adapter_literal }}
    table unstamped_rows

    column id : Int64, primary: true
    column name : String?
    timestamps

    record_timestamps false
  end

  class OnColumnRow < Grant::Base
    connection {{ adapter_literal }}
    table on_column_rows

    column id : Int64, primary: true
    column name : String?
    column created_on : Time?
    column updated_on : Time?
  end
{% end %}

StampedRow.migrator.drop_and_create
UnstampedRow.migrator.drop_and_create
OnColumnRow.migrator.drop_and_create

describe "Automatic timestamps" do
  before_each do
    StampedRow.clear
    UnstampedRow.clear
    OnColumnRow.clear
  end

  it "stamps created_at and updated_at with one clock on create" do
    row = StampedRow.create!(name: "a")
    row.created_at.should_not be_nil
    row.created_at.should eq(row.updated_at)
    loaded = StampedRow.find!(row.id)
    loaded.created_at.should eq(loaded.updated_at)
  end

  it "bumps only updated_at on update" do
    row = StampedRow.create!(name: "a")
    created = row.created_at
    sleep 5.milliseconds
    row.update!(name: "b")
    row.created_at.should eq(created)
    row.updated_at.not_nil!.should be > created.not_nil!
  end

  it "honors skip_timestamps per call" do
    row = StampedRow.create!({"name" => "a"}, skip_timestamps: true)
    row.created_at.should be_nil
    row.updated_at.should be_nil
  end

  it "uses the configured default timezone for the shared clock" do
    Grant::Timestamps.current_time.location.should eq(Grant.settings.default_timezone)
  end

  it "reflects the timestamp columns a model declares" do
    StampedRow.timestamped_attributes.should eq(["created_at", "updated_at"])
    OnColumnRow.timestamped_attributes.should eq(["created_on", "updated_on"])
    OnColumnRow.update_timestamp_columns.should eq(["updated_on"])
  end

  describe "record_timestamps" do
    it "defaults to true" do
      StampedRow.record_timestamps?.should be_true
      UnstampedRow.record_timestamps?.should be_false
    end

    it "stops stamping on create and update when off" do
      row = UnstampedRow.create!(name: "a")
      row.created_at.should be_nil
      row.updated_at.should be_nil
      row.update!(name: "b")
      UnstampedRow.find!(row.id).updated_at.should be_nil
    end

    it "still lets an explicit value through" do
      pinned = Time.utc(2020, 5, 6, 7, 8, 9)
      row = UnstampedRow.create!(name: "a", created_at: pinned, updated_at: pinned)
      loaded = UnstampedRow.find!(row.id)
      loaded.created_at.not_nil!.to_utc.should eq(pinned)
    end
  end

  describe "created_on / updated_on" do
    it "stamps both on create" do
      row = OnColumnRow.create!(name: "a")
      row.created_on.should_not be_nil
      row.created_on.should eq(row.updated_on)
    end

    it "bumps only updated_on on update and never rewrites created_on" do
      row = OnColumnRow.create!(name: "a")
      created = row.created_on
      sleep 5.milliseconds
      statements = WriteSqlCapture.statements { row.update!(name: "b") }
      statements.first.should_not contain("created_on")
      statements.first.should contain("updated_on")
      row.created_on.should eq(created)
      # *_on columns hold dates: both are today's date at midnight UTC.
      row.updated_on.not_nil!.should be >= created.not_nil!
    end

    it "is refreshed by touch" do
      row = OnColumnRow.create!(name: "a")
      pinned = Time.utc(2020, 1, 2, 3, 4, 5)
      row.touch(time: pinned)
      OnColumnRow.find!(row.id).updated_on.not_nil!.to_utc.should eq(Time.utc(2020, 1, 2))
    end
  end

  describe "bulk paths" do
    it "stamps insert_all with the same clock" do
      before = Time.utc - 2.seconds
      StampedRow.insert_all([{"name" => "bulk"}])
      loaded = StampedRow.find_by!(name: "bulk")
      loaded.created_at.not_nil!.to_utc.should be > before
      loaded.created_at.should eq(loaded.updated_at)
    end

    it "follows the model's record_timestamps false" do
      UnstampedRow.insert_all([{"name" => "bulk"}])
      loaded = UnstampedRow.find_by!(name: "bulk")
      loaded.created_at.should be_nil
      loaded.updated_at.should be_nil
    end

    it "lets an explicit record_timestamps: true override the model" do
      UnstampedRow.insert_all([{"name" => "forced"}], record_timestamps: true)
      UnstampedRow.find_by!(name: "forced").created_at.should_not be_nil
    end

    it "stamps created_on and updated_on" do
      OnColumnRow.insert_all([{"name" => "bulk"}])
      loaded = OnColumnRow.find_by!(name: "bulk")
      loaded.created_on.should_not be_nil
      loaded.created_on.should eq(loaded.updated_on)
    end
  end
end
