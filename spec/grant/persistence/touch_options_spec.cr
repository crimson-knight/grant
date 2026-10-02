require "../../spec_helper"
require "../../support/write_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class TouchTicket < Grant::Base
    connection {{ adapter_literal }}
    table touch_tickets

    column id : Int64, primary: true
    column title : String?
    column views : Int32?
    column last_seen_at : Time?
    timestamps
  end
{% end %}

TouchTicket.migrator.drop_and_create

private def updates_in(statements : Array(String)) : Array(String)
  statements.select(&.match(/\A\[[^\]]*\]\s+UPDATE\b/i))
end

FIXED_TIME = Time.utc(2020, 1, 2, 3, 4, 5)

describe "touch options" do
  before_each { TouchTicket.clear }

  describe "#touch(time:)" do
    it "stamps updated_at with the given time" do
      ticket = TouchTicket.create!(title: "t")
      ticket.touch(time: FIXED_TIME).should be_true

      ticket.updated_at.not_nil!.to_utc.should eq(FIXED_TIME)
      TouchTicket.find!(ticket.id).updated_at.not_nil!.to_utc.should eq(FIXED_TIME)
    end

    it "stamps extra columns with the same time in one UPDATE" do
      ticket = TouchTicket.create!(title: "t")
      statements = WriteSqlCapture.statements { ticket.touch(:last_seen_at, time: FIXED_TIME) }
      updates_in(statements).size.should eq(1)

      reloaded = TouchTicket.find!(ticket.id)
      reloaded.updated_at.not_nil!.to_utc.should eq(FIXED_TIME)
      reloaded.last_seen_at.not_nil!.to_utc.should eq(FIXED_TIME)
    end

    it "defaults to now" do
      ticket = TouchTicket.create!(title: "t")
      before = Time.utc - 1.second
      ticket.touch
      ticket.updated_at.not_nil!.to_utc.should be > before
    end

    it "leaves other pending changes dirty and unwritten" do
      ticket = TouchTicket.create!(title: "t")
      ticket.title = "unsaved"
      ticket.touch(time: FIXED_TIME)
      ticket.title_changed?.should be_true
      TouchTicket.find!(ticket.id).title.should eq("t")
    end
  end

  describe "#increment! / #decrement! touch:" do
    it "does not touch by default" do
      ticket = TouchTicket.create!(title: "t", views: 1)
      ticket.touch(time: FIXED_TIME)
      ticket.increment!(:views)
      TouchTicket.find!(ticket.id).updated_at.not_nil!.to_utc.should eq(FIXED_TIME)
    end

    it "folds updated_at into the same UPDATE with touch: true" do
      ticket = TouchTicket.create!(title: "t", views: 1)
      ticket.touch(time: FIXED_TIME)

      statements = WriteSqlCapture.statements { ticket.increment!(:views, by: 2, touch: true) }
      updates = updates_in(statements)
      updates.size.should eq(1)
      updates.first.should contain("views")
      updates.first.should contain("updated_at")

      reloaded = TouchTicket.find!(ticket.id)
      reloaded.views.should eq(3)
      reloaded.updated_at.not_nil!.to_utc.should be > FIXED_TIME
      ticket.changed?.should be_false
      ticket.updated_at.should eq(reloaded.updated_at)
    end

    it "touches a named column as well as updated_at" do
      ticket = TouchTicket.create!(title: "t", views: 0)
      ticket.touch(time: FIXED_TIME)

      statements = WriteSqlCapture.statements { ticket.increment!(:views, touch: :last_seen_at) }
      updates_in(statements).size.should eq(1)

      reloaded = TouchTicket.find!(ticket.id)
      reloaded.last_seen_at.should_not be_nil
      reloaded.updated_at.not_nil!.to_utc.should be > FIXED_TIME
    end

    it "supports decrement! with touch:" do
      ticket = TouchTicket.create!(title: "t", views: 5)
      ticket.touch(time: FIXED_TIME)
      ticket.decrement!(:views, by: 2, touch: true)
      reloaded = TouchTicket.find!(ticket.id)
      reloaded.views.should eq(3)
      reloaded.updated_at.not_nil!.to_utc.should be > FIXED_TIME
    end

    it "treats a NULL counter as zero" do
      ticket = TouchTicket.create!(title: "t")
      ticket.increment!(:views)
      TouchTicket.find!(ticket.id).views.should eq(1)
    end

    it "rejects a touch column the model does not have" do
      ticket = TouchTicket.create!(title: "t", views: 1)
      expect_raises(ArgumentError, /nope/) { ticket.increment!(:views, touch: :nope) }
    end
  end

  describe "#toggle!" do
    it "stamps updated_at through the save it performs" do
      ticket = TouchTicket.create!(title: "t")
      ticket.touch(time: FIXED_TIME)
      ticket.update_column(:title, "before")
      ticket.title = "after"
      ticket.save!
      TouchTicket.find!(ticket.id).updated_at.not_nil!.to_utc.should be > FIXED_TIME
    end
  end
end
