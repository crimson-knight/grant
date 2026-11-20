require "../../spec_helper"

# A model whose default scope keeps only its first row, so a clause that
# `raw_all` runs (the scope inside a derived table, the clause outside it)
# gives a different answer from one `where` adds to the scope.
class AllFirstRowOnly < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table all_first_row_only_notes

  column id : Int64, primary: true
  column title : String?

  default_scope { order(id: :asc).limit(1) }
end

describe "#all" do
  it "finds all the records" do
    Parent.clear
    model_ids = (0...100).map do |i|
      Parent.new(name: "model_#{i}").tap(&.save)
    end.map(&.id)

    all = Parent.all
    all.size.should eq model_ids.size
    all.compact_map(&.id).sort!.should eq model_ids.compact
  end

  # TODO Fails under MySQL
  # it "finds records with numbered query substition" do
  #   name = "findable model"
  #   model = Parent.new(name: name).tap(&.save)
  #   set = Parent.all("WHERE name = $1", [name])
  #   set.size.should eq 1
  #   set.first.name.should eq name
  # end

  it "finds records with question mark substition" do
    name = "findable model"
    Parent.new(name: name).save
    set = Parent.all("WHERE name = ?", [name])
    set.size.should eq 1
    set.first.name.should eq name
  end
  # Issue #43: a raw clause carrying SQL after its condition used to be wrapped
  # in `where`, and the builder appended a second ORDER BY (with the implicit
  # primary-key order on, as in Grant 0.23).
  describe "with a raw clause that orders and limits (issue #43)" do
    around_each do |example|
      Grant.settings.implicit_order = true
      begin
        example.run
      ensure
        Grant.settings.implicit_order = false
      end
    end

    it "runs WHERE ... ORDER BY ... LIMIT with one bind as written" do
      Parent.clear
      first = Parent.new(name: "issue43").tap(&.save!)
      second = Parent.new(name: "issue43").tap(&.save!)
      Parent.new(name: "other").save!

      found = Parent.all("WHERE name = ? ORDER BY id DESC LIMIT 20", ["issue43"] of Grant::Columns::Type)
      found.map(&.id).should eq [second.id, first.id]
    end

    it "runs LIMIT and OFFSET without binds as written" do
      Parent.clear
      ids = (1..3).map { |number| Parent.new(name: "n#{number}").tap(&.save!).id }

      Parent.all("ORDER BY id ASC LIMIT 1 OFFSET 1").map(&.id).should eq [ids[1]]
      Parent.all("WHERE name <> ? ORDER BY id DESC LIMIT 2", ["n9"] of Grant::Columns::Type).map(&.id).should eq [ids[2], ids[1]]
    end

    # `raw_all` selects every column of the derived table, so the clause groups
    # by all of them: that shape is valid under MySQL's ONLY_FULL_GROUP_BY and
    # in PostgreSQL. Wrapped in `where`, the clause would be a syntax error.
    it "runs GROUP BY and HAVING as written" do
      Parent.clear
      first = Parent.new(name: "kept").tap(&.save!)
      second = Parent.new(name: "kept").tap(&.save!)
      Parent.new(name: "dropped").save!

      clause = "WHERE name IS NOT NULL GROUP BY id, name, created_at, updated_at HAVING COUNT(*) = ? AND name <> ? ORDER BY id"
      found = Parent.all(clause, [1, "dropped"] of Grant::Columns::Type)
      found.map(&.id).should eq [first.id, second.id]
    end

    it "still filters a plain WHERE clause through the relation" do
      Parent.clear
      Parent.new(name: "keep").save!
      Parent.new(name: "drop").save!
      Parent.all("WHERE name = ?", ["keep"] of Grant::Columns::Type).map(&.name).should eq ["keep"]
    end
  end

  # Keywords inside a quoted literal or identifier are data, not SQL after the
  # condition, so the clause still goes through `where` and the default scope.
  describe "with a keyword inside a quoted literal" do
    # `clear` honors the default scope too, so each example starts from a new
    # table.
    before_each do
      AllFirstRowOnly.migrator.drop_and_create
      AllFirstRowOnly.create!(title: "other")
      AllFirstRowOnly.create!(title: "LIMIT")
      AllFirstRowOnly.create!(title: "order by")
    end

    it "filters inside the default scope as the bound form does" do
      AllFirstRowOnly.all("WHERE title = ?", ["LIMIT"] of Grant::Columns::Type).map(&.title).should eq ["LIMIT"]
      AllFirstRowOnly.all("WHERE title = 'LIMIT'").map(&.title).should eq ["LIMIT"]
      AllFirstRowOnly.all("WHERE title = 'order by'").map(&.title).should eq ["order by"]
      AllFirstRowOnly.all("WHERE title = 'it''s a join' OR title = 'LIMIT'").map(&.title).should eq ["LIMIT"]
    end

    it "still sends a real LIMIT after the condition to raw_all" do
      # raw_all keeps the default scope inside its derived table, so only the
      # first row is left to filter.
      AllFirstRowOnly.all("WHERE title <> 'limit' ORDER BY id DESC LIMIT 5").map(&.title).should eq ["other"]
    end
  end
end
