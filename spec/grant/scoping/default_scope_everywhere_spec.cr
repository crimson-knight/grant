require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class EverywhereScopedRecord < Grant::Base
    connection {{ adapter_literal }}
    table everywhere_scoped_records

    column id : Int64, primary: true
    column title : String
    column visible : Bool = true
    column category : String
    column score : Int64 = 0_i64
    timestamps

    has_many :children, class_name: EverywhereScopedChild, foreign_key: :record_id

    scope :in_alpha, -> { where(category: "alpha") }
    scope :in_category, ->(category : String) { where(category: category) }
    scope :in_beta, ->(query : Grant::Query::Builder(EverywhereScopedRecord)) { query.where(category: "beta") }
    default_scope { where(visible: true) }
  end

  class EverywhereScopedChild < Grant::Base
    connection {{ adapter_literal }}
    table everywhere_scoped_children

    column id : Int64, primary: true
    column record_id : Int64
    column value : String

    # Optional: one fixture child deliberately points at a parent the default
    # scope hides, and a required belongs_to would (like Rails) reject that.
    belongs_to :record, class_name: EverywhereScopedRecord, foreign_key: :record_id, optional: true
  end

  class EverywhereScopedStiRecord < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table everywhere_scoped_sti_records

    column id : Int64, primary: true
    column type : String
    column title : String
    column visible : Bool = true

    default_scope { where(visible: true) }
  end

  class EverywhereScopedStiChild < EverywhereScopedStiRecord
  end
{% end %}

class DefaultScopeGenericClassLookup
  def self.exists?(model_class : Grant::Base.class, id : Int64) : Bool
    model_class.exists?(id)
  end
end

describe "Grant default scope on every class and relation entry point" do
  before_all do
    EverywhereScopedRecord.migrator.drop_and_create
    EverywhereScopedChild.migrator.drop_and_create
    EverywhereScopedStiRecord.migrator.drop_and_create
  end

  before_each do
    EverywhereScopedChild.unscoped.delete_all
    EverywhereScopedRecord.unscoped.delete_all

    EverywhereScopedRecord.create!(title: "visible one", visible: true, category: "alpha", score: 10_i64)
    EverywhereScopedRecord.create!(title: "visible two", visible: true, category: "alpha", score: 20_i64)
    EverywhereScopedRecord.create!(title: "visible three", visible: true, category: "beta", score: 30_i64)
    EverywhereScopedRecord.create!(title: "hidden", visible: false, category: "hidden", score: 100_i64)

    visible_id = EverywhereScopedRecord.unscoped.where(title: "visible one").first!.id.not_nil!
    hidden_id = EverywhereScopedRecord.unscoped.where(title: "hidden").first!.id.not_nil!
    EverywhereScopedChild.create!(record_id: visible_id, value: "visible child")
    EverywhereScopedChild.create!(record_id: hidden_id, value: "hidden child")
  end

  it "keeps filters separate from default predicates when OR conditions are chained" do
    EverywhereScopedRecord.all.map(&.title).sort!.should eq(["visible one", "visible three", "visible two"])
    EverywhereScopedRecord.where(title: "hidden").select.should be_empty
    EverywhereScopedRecord.where.not(:visible, true).select.should be_empty
    EverywhereScopedRecord.where(title: "missing").or(title: "hidden").select.should be_empty
    EverywhereScopedRecord.in_alpha.select.map(&.title).sort!.should eq(["visible one", "visible two"])
    EverywhereScopedRecord.in_category("beta").select.map(&.title).should eq(["visible three"])
    EverywhereScopedRecord.in_beta.select.map(&.title).should eq(["visible three"])

    EverywhereScopedRecord.all("WHERE title IN (?, ?)", ["hidden", "visible two"] of Grant::Columns::Type).map(&.title).should eq(["visible two"])
    EverywhereScopedRecord.raw_all("WHERE title = ?", ["hidden"] of Grant::Columns::Type).should be_empty
  end

  it "dispatches default scopes through generic model references and composes with STI" do
    hidden_id = EverywhereScopedRecord.unscoped.where(title: "hidden").first!.id.not_nil!
    visible_id = EverywhereScopedRecord.unscoped.where(title: "visible one").first!.id.not_nil!
    DefaultScopeGenericClassLookup.exists?(EverywhereScopedRecord, hidden_id).should be_false
    DefaultScopeGenericClassLookup.exists?(EverywhereScopedRecord, visible_id).should be_true

    EverywhereScopedStiRecord.unscoped.delete_all
    EverywhereScopedStiRecord.create!(title: "visible root", visible: true)
    EverywhereScopedStiChild.create!(title: "visible child", visible: true)
    EverywhereScopedStiChild.create!(title: "hidden child", visible: false)

    EverywhereScopedStiRecord.all.map(&.title).sort!.should eq(["visible child", "visible root"])
    EverywhereScopedStiChild.all.map(&.title).should eq(["visible child"])
  end

  it "scopes class-level selection, ordering, projection, distinct, grouping, joins, and eager loading" do
    EverywhereScopedRecord.order(id: :desc).reorder(id: :asc).limit(2).offset(1).select.map(&.title).should eq(["visible two", "visible three"])
    EverywhereScopedRecord.select(:category).select.map(&.category).uniq!.sort!.should eq(["alpha", "beta"])
    EverywhereScopedRecord.pluck(:category).map(&.as(String)).uniq!.sort!.should eq(["alpha", "beta"])
    EverywhereScopedRecord.where(category: "alpha").pluck(:category).uniq.should eq([["alpha"] of Grant::Columns::Type])
    EverywhereScopedRecord.ids.size.should eq(3)
    EverywhereScopedRecord.distinct.select(:category).select.map(&.category).sort!.should eq(["alpha", "beta"])

    grouped_categories = EverywhereScopedRecord.group_by(:category)
      .having("COUNT(*) > ?", 0_i64)
      .select(:category)
      .select
      .map(&.category)
      .sort!
    grouped_categories.should eq(["alpha", "beta"])

    join_titles = EverywhereScopedRecord
      .joins("everywhere_scoped_children", on: "everywhere_scoped_children.record_id = everywhere_scoped_records.id")
      .select
      .map(&.title)
    join_titles.should eq(["visible one"])

    left_join_titles = EverywhereScopedRecord
      .left_joins("everywhere_scoped_children", on: "everywhere_scoped_children.record_id = everywhere_scoped_records.id")
      .select(:title)
      .select
      .map(&.title)
      .sort!
    left_join_titles.should eq(["visible one", "visible three", "visible two"])

    EverywhereScopedRecord.includes(:children).select.map(&.title).sort!.should eq(["visible one", "visible three", "visible two"])
    EverywhereScopedRecord.preload(:children).select.map(&.title).sort!.should eq(["visible one", "visible three", "visible two"])
    EverywhereScopedRecord.eager_load(:children).select.map(&.title).sort!.should eq(["visible one", "visible three", "visible two"])
  end

  it "scopes lookups, first and last helpers, and class-level iteration" do
    visible = EverywhereScopedRecord.unscoped.where(title: "visible one").first!
    hidden = EverywhereScopedRecord.unscoped.where(title: "hidden").first!

    EverywhereScopedRecord.find(visible.id).try(&.title).should eq("visible one")
    EverywhereScopedRecord.find(hidden.id).should be_nil
    EverywhereScopedRecord.find_by(title: "hidden").should be_nil
    EverywhereScopedRecord.find_by(title: "visible one").try(&.id).should eq(visible.id)
    EverywhereScopedRecord.find_sole_by(title: "visible two").title.should eq("visible two")
    EverywhereScopedRecord.first.not_nil!.title.should eq("visible one")
    EverywhereScopedRecord.first!.title.should eq("visible one")
    EverywhereScopedRecord.last.try(&.title).should eq("visible three")
    EverywhereScopedRecord.last!.title.should eq("visible three")
    EverywhereScopedRecord.take.try(&.title).should eq("visible one")
    EverywhereScopedRecord.take(2).map(&.title).should eq(["visible one", "visible two"])

    ids_from_each = [] of Int64
    EverywhereScopedRecord.find_each(batch_size: 2) { |record| ids_from_each << record.id.not_nil! }
    ids_from_each.size.should eq(3)

    batch_sizes = [] of Int32
    EverywhereScopedRecord.find_in_batches(batch_size: 2) { |batch| batch_sizes << batch.size }
    batch_sizes.should eq([2, 1])

    yielded_batches = [] of Int32
    EverywhereScopedRecord.in_batches(of: 2) { |batch| yielded_batches << batch.to_a.size }
    yielded_batches.should eq([2, 1])

    streamed_titles = [] of String
    EverywhereScopedRecord.each_streamed { |record| streamed_titles << record.title }
    streamed_titles.size.should eq(3)
    streamed_titles.should_not contain("hidden")
  end

  it "scopes calculations and existence checks" do
    hidden_id = EverywhereScopedRecord.unscoped.where(title: "hidden").first!.id.not_nil!
    visible_id = EverywhereScopedRecord.unscoped.where(title: "visible two").first!.id.not_nil!

    EverywhereScopedRecord.count.should eq(3)
    EverywhereScopedRecord.where(title: "hidden").count.should eq(0)
    EverywhereScopedRecord.exists?(hidden_id).should be_false
    EverywhereScopedRecord.exists?(id: hidden_id).should be_false
    EverywhereScopedRecord.where(id: hidden_id).exists?.should be_false
    EverywhereScopedRecord.exists?(visible_id).should be_true

    EverywhereScopedRecord.sum(:score).should eq(60.0)
    EverywhereScopedRecord.avg(:score).should eq(20.0)
    EverywhereScopedRecord.average(:score).should eq(20.0)
    EverywhereScopedRecord.min(:score).should eq(10_i64)
    EverywhereScopedRecord.minimum(:score).should eq(10_i64)
    EverywhereScopedRecord.max(:score).should eq(30_i64)
    EverywhereScopedRecord.maximum(:score).should eq(30_i64)
    EverywhereScopedRecord.order(id: :asc).pick(:title).should eq(["visible one"] of Grant::Columns::Type)
  end

  it "scopes bulk writes and leaves the hidden row unchanged" do
    hidden_id = EverywhereScopedRecord.unscoped.where(title: "hidden").first!.id.not_nil!

    EverywhereScopedRecord.update_all(score: 99_i64).should eq(3)
    EverywhereScopedRecord.unscoped.where(id: hidden_id).first!.title.should eq("hidden")
    EverywhereScopedRecord.unscoped do |_query|
      EverywhereScopedRecord.update_all(score: 101_i64).should eq(4)
    end
    EverywhereScopedRecord.unscoped.where(id: hidden_id).first!.score.should eq(101_i64)

    EverywhereScopedRecord.where(title: "hidden").update_all(title: "changed hidden").should eq(0)
    EverywhereScopedRecord.update_counters(hidden_id, {:score => 5}).should eq(0)
    EverywhereScopedRecord.delete_by(title: "hidden").should eq(0)
    EverywhereScopedRecord.destroy_by(title: "hidden").should eq(0)
    EverywhereScopedRecord.where(title: "hidden").delete_all.should eq(0)
    EverywhereScopedRecord.where(title: "hidden").destroy_all.should eq(0)
    EverywhereScopedRecord.touch_all(time: Time.utc(2020, 1, 1)).should eq(3)

    EverywhereScopedRecord.unscoped.where(id: hidden_id).first!.title.should eq("hidden")
    EverywhereScopedRecord.where(title: "visible one").update_all(title: "changed visible").should eq(1)
    EverywhereScopedRecord.delete_all.should eq(3)
    EverywhereScopedRecord.unscoped.where(id: hidden_id).first!.title.should eq("hidden")
    EverywhereScopedRecord.clear
    EverywhereScopedRecord.unscoped.where(title: "hidden").count.should eq(1)
    EverywhereScopedRecord.unscoped.where(title: "changed visible").count.should eq(0)
  end

  it "requires unscoped for raw SQL and preserves both explicit unscoped forms" do
    expect_raises(Grant::Querying::ScopedRawSqlError) do
      EverywhereScopedRecord.query("SELECT * FROM everywhere_scoped_records") { |_rs| }
    end

    unscoped_titles = EverywhereScopedRecord.unscoped.where(title: "hidden").select.map(&.title)
    unscoped_titles.should eq(["hidden"])

    block_titles = EverywhereScopedRecord.unscoped do |query|
      query.where(title: "hidden").select.map(&.title)
    end
    block_titles.should eq(["hidden"])
    EverywhereScopedRecord.unscoped { EverywhereScopedRecord.count }.should eq(4)
  end
end
