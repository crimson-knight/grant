require "../../spec_helper"
require "../../support/relation_sql_capture"

private def seed_parents(names : Array(String)) : Array(Parent)
  Parent.clear
  names.map { |name| Parent.create(name: name) }
end

describe "Relation immutability" do
  it "leaves the base relation unchanged after chaining" do
    seed_parents(["a", "b", "c"])

    base = Parent.where(name: "a")
    original_sql = base.to_sql

    with_b = base.where(name: "b")
    with_c = base.where(name: "c")

    base.to_sql.should eq original_sql
    with_b.to_sql.should_not eq original_sql
    with_c.to_sql.should_not eq original_sql
    with_b.where_fields.last.should_not eq with_c.where_fields.last
    with_b.should_not be(base)
    base.where_fields.size.should eq 1
    with_b.where_fields.size.should eq 2
    with_c.where_fields.size.should eq 2
  end

  it "returns a new relation from every chain method" do
    base = Parent.where(name: "a")
    sql = base.to_sql

    chained = [
      base.where(name: "b"),
      base.where("id > ?", 0),
      base.and(name: "b"),
      base.or(name: "b"),
      base.or { |q| q.where(name: "b") },
      base.not { |q| q.where(name: "b") },
      base.order(:id),
      base.order(name: :desc),
      base.reorder(:name),
      base.reverse_order,
      base.group_by(:name),
      base.regroup(:name),
      base.limit(5),
      base.offset(5),
      base.lock,
      base.distinct,
      base.having("COUNT(*) > ?", 0),
      base.none,
      base.reselect(:id),
      base.select(:id),
      base.rewhere(name: "z"),
      base.unscope(:where),
      base.joins("students", on: "students.id = parents.id"),
      base.left_joins("students", on: "students.id = parents.id"),
      base.merge(Parent.where(name: "z")),
      base.in_chunks(of: 10),
      base.use_index("idx_parents_name"),
      base.force_index("idx_parents_name"),
      base.ignore_index("idx_parents_name"),
      base.annotate("dashboard"),
      base.includes(:students),
      base.preload(:students),
      base.eager_load(:students),
      base.strict_loading,
      base.all,
    ]

    chained.each do |relation|
      relation.should_not be(base)
      relation.should be_a(Grant::Query::Builder(Parent))
    end

    base.to_sql.should eq sql
    base.order_fields.should be_empty
    base.group_fields.should be_empty
    base.join_clauses.should be_empty
    base.having_clauses.should be_empty
    base.limit.should be_nil
    base.offset.should be_nil
    base.lock_mode.should be_nil
    base.distinct?.should be_false
    base.is_none?.should be_false
    base.select_columns.should be_nil
    base.strict_loading?.should be_false
    base.where_fields.size.should eq 1
    base.index_hints.should be_empty
    base.annotation_comment.should be_nil
    base.includes_associations.should be_empty
    base.preload_associations.should be_empty
    base.eager_load_associations.should be_empty
  end

  it "does not let a stored relation accumulate clauses across helper calls" do
    seed_parents(["a", "b", "c"])
    active = Parent.where("name != ?", "c")

    by_name = ->(name : String) { active.where(name: name) }

    by_name.call("a").to_a.compact_map(&.name).should eq ["a"]
    by_name.call("b").to_a.compact_map(&.name).should eq ["b"]
    active.to_a.compact_map(&.name).sort!.should eq ["a", "b"]
  end

  it "keeps first, last, take and ordinal finders from mutating the receiver" do
    seed_parents(["a", "b", "c"])
    base = Parent.where("name != ?", "zzz")
    sql = base.to_sql

    base.first
    base.first(2)
    base.last
    base.last(2)
    base.take
    base.take(2)
    base.second
    base.third
    base.second_to_last

    base.to_sql.should eq sql
    base.order_fields.should be_empty
    base.limit.should be_nil
    base.offset.should be_nil
    base.select.size.should eq 3
    base.count.should eq 3
    base.select(:id).to_sql.should_not contain("LIMIT")
  end

  it "keeps any?, many?, one?, none?, empty? and sole from mutating the receiver" do
    seed_parents(["a"])
    base = Parent.where(name: "a")
    sql = base.to_sql

    base.any?.should be_true
    base.many?.should be_false
    base.one?.should be_true
    base.none?.should be_false
    base.empty?.should be_false
    base.sole.name.should eq "a"
    base.exists?.should be_true

    base.to_sql.should eq sql
    base.limit.should be_nil
    base.order_fields.should be_empty
  end

  it "keeps a later count free of the LIMIT and ORDER BY a terminal used" do
    seed_parents(["a", "b", "c"])
    base = Parent.where("name != ?", "zzz")

    base.first
    base.any?
    base.count.should eq 3
    base.size.should eq 3

    statements = capture_sql { base.count }
    statements.size.should eq 1
    statements.first.should_not contain("LIMIT")
    statements.first.should_not contain("ORDER BY")
  end

  it "does not mutate the receiver in or/not blocks" do
    base = Parent.where(name: "a")
    sql = base.to_sql

    base.or { |q| q.where(name: "b") }
    base.not { |q| q.where(name: "c") }

    base.to_sql.should eq sql
    base.where_fields.size.should eq 1
  end

  it "applies or/not blocks that return the relation they built" do
    seed_parents(["a", "b", "c"])

    Parent.where(name: "a").or { |q| q.where(name: "b") }.to_a.compact_map(&.name).sort!.should eq ["a", "b"]
    Parent.where("name != ?", "zzz").not { |q| q.where(name: "c") }.to_a.compact_map(&.name).sort!.should eq ["a", "b"]
  end

  it "shares no state between a relation and its copies in either direction" do
    base = Parent.where(name: "a")
    copy = base.all

    copy.where!(name: "b")
    copy.order!(:id)
    base.where_fields.size.should eq 1
    base.order_fields.should be_empty
    copy.where_fields.size.should eq 2
    copy.order_fields.size.should eq 1

    base.where!(name: "c")
    base.limit!(1)
    copy.where_fields.size.should eq 2
    copy.limit.should be_nil
    base.where_fields.size.should eq 2
  end

  it "mutates in place only through the bang variants" do
    base = Parent.where(name: "a")

    result = base.where!(name: "b").order!(:id).limit!(3)

    result.should be(base)
    base.where_fields.size.should eq 2
    base.order_fields.size.should eq 1
    base.limit.should eq 3
  end

  it "makes dup a copy-on-write copy that never writes through to the original" do
    base = Parent.where(name: "a")
    copy = base.dup

    copy.clear_where_fields
    copy.own_order_fields << {field: "id", direction: Grant::Query::Builder::Sort::Ascending}

    base.where_fields.size.should eq 1
    base.order_fields.should be_empty
    copy.where_fields.should be_empty
    copy.order_fields.size.should eq 1
  end

  it "does not leak default-scope or unscope changes into the base" do
    base = Parent.where(name: "a").order(:id)

    unscoped = base.unscope(:where, :order)

    unscoped.where_fields.should be_empty
    unscoped.order_fields.should be_empty
    base.where_fields.size.should eq 1
    base.order_fields.size.should eq 1
  end
end
