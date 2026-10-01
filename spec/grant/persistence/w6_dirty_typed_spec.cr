require "json"
require "../../spec_helper"

enum W6DirtyRank
  Low
  High
end

class W6DirtyMeta
  include JSON::Serializable

  property color : String

  def initialize(@color : String)
  end
end

class W6NoReverseConverter
  def self.to_db(value : Int32?) : Grant::Columns::Type
    value.try(&.to_s)
  end

  def self.from_rs(result : ::DB::ResultSet) : Int32?
    result.read(String?).try(&.to_i)
  end
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6DirtyTicket < Grant::Base
    connection {{ adapter_literal }}
    table w6_dirty_tickets

    column id : Int64, primary: true
    column title : String
    column rank : W6DirtyRank, converter: Grant::Converters::Enum(W6DirtyRank, String), column_type: "TEXT"
    column meta : W6DirtyMeta?, converter: Grant::Converters::Json(W6DirtyMeta, String), column_type: "TEXT"
    column score : Int32?, converter: W6NoReverseConverter, column_type: "TEXT"
    column views : Int32?
  end
{% end %}

W6DirtyTicket.migrator.drop_and_create

describe "Typed dirty tracking" do
  before_each { W6DirtyTicket.clear }

  it "returns _was and _change in the column type for a plain non-nilable column" do
    ticket = W6DirtyTicket.create!(title: "a", rank: W6DirtyRank::Low)
    ticket.title = "b"
    ticket.title_was.should eq("a")
    ticket.title_change.should eq({"a", "b"})
    typeof(ticket.title_was).should eq(String)
  end

  it "round-trips a converter-backed non-nilable column through _was and _change" do
    ticket = W6DirtyTicket.create!(title: "a", rank: W6DirtyRank::Low)
    loaded = W6DirtyTicket.find!(ticket.id)
    loaded.rank = W6DirtyRank::High

    loaded.rank_was.should eq(W6DirtyRank::Low)
    loaded.rank_change.should eq({W6DirtyRank::Low, W6DirtyRank::High})
    typeof(loaded.rank_was).should eq(W6DirtyRank)
    loaded.rank_in_database.should eq(W6DirtyRank::Low)
    loaded.rank_change_to_be_saved.should eq({W6DirtyRank::Low, W6DirtyRank::High})

    loaded.save!
    loaded.rank_before_last_save.should eq(W6DirtyRank::Low)
    loaded.rank_previously_was.should eq(W6DirtyRank::Low)
    loaded.saved_change_to_rank.should eq({W6DirtyRank::Low, W6DirtyRank::High})
    loaded.rank_was.should eq(W6DirtyRank::High)
  end

  it "round-trips a JSON object converter" do
    ticket = W6DirtyTicket.create!(title: "a", rank: W6DirtyRank::Low, meta: W6DirtyMeta.new("red"))
    loaded = W6DirtyTicket.find!(ticket.id)
    loaded.meta = W6DirtyMeta.new("blue")

    loaded.meta_was.not_nil!.color.should eq("red")
    change = loaded.meta_change.not_nil!
    change[0].not_nil!.color.should eq("red")
    change[1].not_nil!.color.should eq("blue")
  end

  it "raises a clear error when a converter cannot go back to the column type" do
    ticket = W6DirtyTicket.create!(title: "a", rank: W6DirtyRank::Low, score: 1)
    loaded = W6DirtyTicket.find!(ticket.id)
    loaded.score = 2
    expect_raises(Grant::ConverterError, /from_db/) { loaded.score_was }
  end

  it "reports changed_attributes as AR's name => original hash and changed as the names" do
    ticket = W6DirtyTicket.create!(title: "a", rank: W6DirtyRank::Low, views: 1)
    loaded = W6DirtyTicket.find!(ticket.id)
    loaded.title = "b"
    loaded.views = 2

    loaded.changed.should eq(["title", "views"])
    loaded.changed_attributes.should eq({"title" => "a", "views" => 1})
    loaded.changes.should eq({"title" => {"a", "b"}, "views" => {1, 2}})
  end

  describe "<attr>_came_from_user?" do
    it "is false for a loaded record and true once the attribute is assigned" do
      ticket = W6DirtyTicket.create!(title: "a", rank: W6DirtyRank::Low)
      loaded = W6DirtyTicket.find!(ticket.id)
      loaded.title_came_from_user?.should be_false

      loaded.title = "b"
      loaded.title_came_from_user?.should be_true
      loaded.views_came_from_user?.should be_false
      loaded.attribute_came_from_user?("title").should be_true
    end

    it "counts mass assignment on a new record, even of an unchanged value" do
      ticket = W6DirtyTicket.new(title: "typed", rank: W6DirtyRank::Low)
      ticket.title_came_from_user?.should be_true
      ticket.views_came_from_user?.should be_false
    end

    it "resets after save, reload and clear_changes_information" do
      ticket = W6DirtyTicket.new(title: "typed", rank: W6DirtyRank::Low)
      ticket.save!
      ticket.title_came_from_user?.should be_false

      ticket.title = "again"
      ticket.title_came_from_user?.should be_true
      ticket.reload
      ticket.title_came_from_user?.should be_false

      ticket.title = "third"
      ticket.clear_changes_information
      ticket.title_came_from_user?.should be_false
    end
  end
end
