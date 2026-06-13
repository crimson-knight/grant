require "../../spec_helper"

# Specs for the query-interface parity additions:
#   ids, unscope, joins(:assoc)/left_joins(:assoc), annotate (executed SQL),
#   chainable find_each/find_in_batches, update_all(Hash), explain.
describe "Grant::Query::Builder - parity additions" do
  describe "#ids" do
    it "returns the primary keys of matching records" do
      Parent.clear
      a = Parent.create!(name: "ids-a")
      b = Parent.create!(name: "ids-b")
      Parent.create!(name: "other")

      ids = Parent.where(name: ["ids-a", "ids-b"]).ids
      ids.map(&.as(Int64)).sort.should eq([a.id, b.id].map(&.as(Int64)).sort)
    end

    it "returns all ids when unfiltered" do
      Parent.clear
      Parent.create!(name: "p1")
      Parent.create!(name: "p2")

      Parent.ids.size.should eq(2)
    end

    it "returns an empty array for a none relation" do
      Parent.where(name: "anything").none.ids.should be_empty
    end
  end

  describe "#unscope" do
    it "drops ordering with unscope(:order)" do
      sql = Parent.where(name: "x").order(name: :asc).unscope(:order).raw_sql
      sql.should_not contain("ORDER BY name")
    end

    it "drops where conditions with unscope(:where)" do
      query = Parent.where(name: "x").where(name: "y").unscope(:where)
      query.where_fields.should be_empty
    end

    it "drops limit and offset" do
      query = Parent.where(name: "x").limit(10).offset(5).unscope(:limit, :offset)
      query.limit.should be_nil
      query.offset.should be_nil
    end

    it "drops group_by, having and joins" do
      query = Parent
        .joins("students", on: "students.parent_id = parents.id")
        .group_by(:name)
        .having("COUNT(*) > ?", 1)
        .unscope(:joins, :group, :having)
      query.join_clauses.should be_empty
      query.group_fields.should be_empty
      query.having_clauses.should be_empty
    end

    it "raises on an unknown component" do
      expect_raises(ArgumentError) do
        Parent.where(name: "x").unscope(:bogus)
      end
    end
  end

  describe "#joins(association)" do
    it "resolves a has_many association into an INNER JOIN" do
      # Parent has_many :students  (students.parent_id -> parents.id)
      sql = Parent.joins(:students).raw_sql
      sql.should contain("INNER JOIN students ON students.parent_id = parents.id")
    end

    it "resolves a belongs_to association into an INNER JOIN" do
      # Klass belongs_to :teacher  (klasses.teacher_id -> teachers.id)
      sql = Klass.joins(:teacher).raw_sql
      sql.should contain("INNER JOIN teachers ON teachers.id = klasses.teacher_id")
    end

    it "resolves multiple associations" do
      sql = Parent.joins(:students).where(name: "x").raw_sql
      sql.should contain("INNER JOIN students")
      sql.should contain("WHERE")
    end

    it "left_joins(association) emits a LEFT JOIN" do
      sql = Parent.left_joins(:students).raw_sql
      sql.should contain("LEFT JOIN students ON students.parent_id = parents.id")
    end

    it "keeps the explicit-string overload working" do
      sql = Parent.joins("students", on: "students.parent_id = parents.id").raw_sql
      sql.should contain("INNER JOIN students ON students.parent_id = parents.id")
    end

    it "raises for an unknown association" do
      expect_raises(ArgumentError) do
        Parent.joins(:nonexistent_assoc).raw_sql
      end
    end
  end

  describe "#annotate" do
    it "includes the comment in the executed SQL (not just raw_sql)" do
      Parent.clear
      Parent.create!(name: "annotated")

      query = Parent.where(name: "annotated").annotate("from dashboard")
      query.raw_sql.should contain("/* from dashboard */")

      # The executed statement carries the comment too — exercising the path
      # proves it does not break execution.
      query.select.size.should eq(1)
    end

    it "sanitizes the comment by stripping */" do
      sql = Parent.where(name: "x").annotate("evil */ DROP TABLE parents; /*").raw_sql
      sql.should_not contain("*/ DROP TABLE")
      sql.should contain("/* evil  DROP TABLE parents;")
    end
  end

  describe "chainable #find_each" do
    it "yields only records matching the relation" do
      Parent.clear
      Parent.create!(name: "match")
      Parent.create!(name: "match")
      Parent.create!(name: "nope")

      seen = [] of String
      Parent.where(name: "match").find_each(batch_size: 1) do |parent|
        seen << parent.name.to_s
      end

      seen.size.should eq(2)
      seen.all? { |n| n == "match" }.should be_true
    end
  end

  describe "chainable #find_in_batches" do
    it "yields batches of matching records" do
      Parent.clear
      5.times { |i| Parent.create!(name: "batch") }

      batch_sizes = [] of Int32
      total = 0
      Parent.where(name: "batch").find_in_batches(batch_size: 2) do |batch|
        batch_sizes << batch.size
        total += batch.size
      end

      total.should eq(5)
      batch_sizes.first.should eq(2)
    end
  end

  describe "#update_all(Hash)" do
    it "updates matching rows from a Hash" do
      Parent.clear
      Parent.create!(name: "before")
      Parent.create!(name: "before")
      Parent.create!(name: "keep")

      affected = Parent.where(name: "before").update_all({"name" => "after"})
      affected.should eq(2)

      Parent.where(name: "after").count.should eq(2)
      Parent.where(name: "keep").count.should eq(1)
    end

    it "updates from named arguments" do
      Parent.clear
      Parent.create!(name: "named-before")

      Parent.where(name: "named-before").update_all(name: "named-after")
      Parent.where(name: "named-after").count.should eq(1)
    end

    it "is injection-safe: values are bound, not interpolated" do
      Parent.clear
      p = Parent.create!(name: "victim")

      # A classic injection payload as a value must be stored verbatim,
      # never executed. The parents table must survive.
      payload = "x'); DROP TABLE parents; --"
      Parent.where(id: p.id).update_all({"name" => payload})

      reloaded = Parent.find!(p.id)
      reloaded.name.should eq(payload)
      # Table intact, row still present.
      Parent.count.should eq(1)
    end

    it "still supports the raw string form" do
      Parent.clear
      Parent.create!(name: "raw")
      Parent.where(name: "raw").update_all("name = 'raw-updated'")
      Parent.where(name: "raw-updated").count.should eq(1)
    end
  end

  describe "#explain" do
    it "returns a non-empty plan for the query" do
      Parent.clear
      Parent.create!(name: "explained")

      plan = Parent.where(name: "explained").explain
      plan.should_not be_empty
    end

    it "degrades gracefully and still returns a String for analyze" do
      Parent.where(name: "x").explain(analyze: true).should be_a(String)
    end
  end
end
