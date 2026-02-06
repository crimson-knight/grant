require "../../spec_helper"

describe "Joins, Distinct, Having - Integration" do
  describe "joins SQL generation" do
    it "generates INNER JOIN SQL" do
      sql = Parent.where(name: "test")
        .joins("students", on: "students.parent_id = parents.id")
        .raw_sql
      sql.should contain("INNER JOIN students ON students.parent_id = parents.id")
      sql.should contain("WHERE")
    end

    it "generates LEFT JOIN SQL" do
      sql = Parent.where(name: "test")
        .left_joins("students", on: "students.parent_id = parents.id")
        .raw_sql
      sql.should contain("LEFT JOIN students ON students.parent_id = parents.id")
    end

    it "supports multiple joins in SQL" do
      sql = Parent
        .joins("students", on: "students.parent_id = parents.id")
        .joins("enrollments", on: "enrollments.student_id = students.id")
        .raw_sql
      sql.should contain("INNER JOIN students ON students.parent_id = parents.id")
      sql.should contain("INNER JOIN enrollments ON enrollments.student_id = students.id")
    end

    it "works with order, limit, and group_by" do
      sql = Parent
        .joins("students", on: "students.parent_id = parents.id")
        .order(name: :asc)
        .limit(10)
        .group_by(:name)
        .raw_sql
      sql.should contain("INNER JOIN")
      sql.should contain("ORDER BY")
      sql.should contain("LIMIT 10")
      sql.should contain("GROUP BY name")
    end
  end

  describe "distinct SQL generation" do
    it "generates SELECT DISTINCT" do
      sql = Parent.distinct.raw_sql
      sql.should contain("SELECT DISTINCT")
    end

    it "does not add DISTINCT by default" do
      sql = Parent.where(name: "test").raw_sql
      sql.should_not contain("DISTINCT")
    end

    it "works with where and order" do
      sql = Parent.distinct.where(name: "test").order(name: :asc).raw_sql
      sql.should contain("SELECT DISTINCT")
      sql.should contain("WHERE")
      sql.should contain("ORDER BY")
    end
  end

  describe "having SQL generation" do
    it "generates HAVING with group_by" do
      sql = Parent
        .group_by(:name)
        .having("COUNT(*) > ?", 5)
        .raw_sql
      sql.should contain("GROUP BY name")
      sql.should contain("HAVING")
    end

    it "generates HAVING without value parameter" do
      sql = Parent
        .group_by(:name)
        .having("COUNT(*) > 0")
        .raw_sql
      sql.should contain("HAVING COUNT(*) > 0")
    end

    it "chains multiple having clauses with AND" do
      sql = Parent
        .group_by(:name)
        .having("COUNT(*) > ?", 5)
        .having("COUNT(*) < ?", 100)
        .raw_sql
      sql.should contain("HAVING")
      sql.should contain("AND")
    end

    it "works with joins and group_by" do
      sql = Parent
        .joins("students", on: "students.parent_id = parents.id")
        .group_by(:name)
        .having("COUNT(*) > ?", 3)
        .raw_sql
      sql.should contain("INNER JOIN")
      sql.should contain("GROUP BY name")
      sql.should contain("HAVING")
    end
  end

  describe "none" do
    it "returns empty results" do
      Parent.none.select.should be_empty
    end

    it "any? returns false" do
      Parent.none.any?.should be_false
    end

    it "exists? returns false" do
      Parent.none.exists?.should be_false
    end

    it "chains with other methods safely" do
      Parent.none.where(name: "test").order(name: :asc).select.should be_empty
    end
  end

  describe "reorder" do
    it "replaces existing order" do
      sql = Parent.order(name: :asc).reorder(name: :desc).raw_sql
      sql.should contain("ORDER BY name DESC")
      sql.should_not contain("ORDER BY name ASC")
    end
  end

  describe "reverse_order" do
    it "flips order direction" do
      sql = Parent.order(name: :asc).reverse_order.raw_sql
      sql.should contain("ORDER BY name DESC")
    end
  end

  describe "rewhere" do
    it "replaces existing conditions" do
      # First build a query with two where clauses, then rewhere replaces all
      q = Parent.where(name: "bob").where(name: "charlie")
      q.where_fields.size.should eq 2

      # rewhere clears and replaces
      q2 = Parent.where(name: "bob").rewhere(name: "alice")
      q2.where_fields.size.should eq 1
    end
  end
end
