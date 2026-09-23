require "../../spec_helper"

describe "Advanced Query Interface" do
  describe "Query#merge" do
    it "merges where conditions" do
      query1 = AdvancedQueryParent.where(name: "test")
      query2 = AdvancedQueryParent.where(locked: true)

      merged = query1.merge(query2)

      merged.where_fields.size.should eq(2)
      merged.where_fields[0].should eq({join: :and, field: "name", operator: :eq, value: "test"})
      merged.where_fields[1].should eq({join: :and, field: "locked", operator: :eq, value: true})
    end

    it "uses other query's order when merging" do
      query1 = AdvancedQueryParent.order(name: :asc)
      query2 = AdvancedQueryParent.order(id: :desc)

      merged = query1.merge(query2)

      merged.order_fields.size.should eq(1)
      merged.order_fields[0][:field].should eq("id")
    end

    it "merges group fields without duplicates" do
      query1 = AdvancedQueryParent.where(id: [1, 2, 3]).group_by(:name)
      query2 = AdvancedQueryParent.where(id: [1, 2, 3]).group_by(:name).group_by(:locked)

      merged = query1.merge(query2)

      merged.group_fields.size.should eq(2)
      merged.group_fields.map { |f| f[:field] }.should eq(["name", "locked"])
    end

    it "uses other query's limit and offset" do
      query1 = AdvancedQueryParent.limit(10).offset(5)
      query2 = AdvancedQueryParent.limit(20).offset(10)

      merged = query1.merge(query2)

      merged.limit.should eq(20)
      merged.offset.should eq(10)
    end
  end

  describe "Query#dup" do
    it "creates a copy of the query" do
      original = AdvancedQueryParent.where(name: "test").order(id: :desc).limit(10)
      copy = original.dup

      # Modify copy
      copy.where(locked: true)

      # Original should be unchanged
      original.where_fields.size.should eq(1)
      copy.where_fields.size.should eq(2)
    end
  end

  describe "WhereChain" do
    it "provides not_in method" do
      query = AdvancedQueryParent.where.not_in(:id, [1, 2, 3])

      query.where_fields.size.should eq(1)
      field = query.where_fields[0]
      # Since WhereField is a union type, we need to check which variant we have
      case field
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field[:field].should eq("id")
        field[:operator].should eq(:nin)
        field[:value].should eq([1, 2, 3])
      else
        raise "Expected field-based condition but got statement-based"
      end
    end

    it "provides like method" do
      query = AdvancedQueryParent.where.like(:name, "%test%")

      query.where_fields.size.should eq(1)
      field = query.where_fields[0]
      case field
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field[:operator].should eq(:like)
        field[:value].should eq("%test%")
      else
        raise "Expected field-based condition"
      end
    end

    it "provides not_like method" do
      query = AdvancedQueryParent.where.not_like(:name, "%spam%")

      query.where_fields.size.should eq(1)
      field = query.where_fields[0]
      case field
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field[:operator].should eq(:nlike)
        field[:value].should eq("%spam%")
      else
        raise "Expected field-based condition"
      end
    end

    it "provides comparison methods" do
      query = AdvancedQueryParent.where.gt(:id, 10).where.lt(:id, 20)

      query.where_fields.size.should eq(2)

      field1 = query.where_fields[0]
      case field1
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field1[:operator].should eq(:gt)
        field1[:value].should eq(10)
      else
        raise "Expected field-based condition"
      end

      field2 = query.where_fields[1]
      case field2
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field2[:operator].should eq(:lt)
        field2[:value].should eq(20)
      else
        raise "Expected field-based condition"
      end
    end

    it "provides is_null and is_not_null methods" do
      query = AdvancedQueryParent.where.is_null(:deleted_at).where.is_not_null(:confirmed_at)

      query.where_fields.size.should eq(2)

      field1 = query.where_fields[0]
      case field1
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field1[:field].should eq("deleted_at")
        field1[:operator].should eq(:eq)
        field1[:value].should be_nil
      else
        raise "Expected field-based condition"
      end

      field2 = query.where_fields[1]
      case field2
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field2[:field].should eq("confirmed_at")
        field2[:operator].should eq(:neq)
        field2[:value].should be_nil
      else
        raise "Expected field-based condition"
      end
    end

    it "provides between method" do
      query = AdvancedQueryParent.where.between(:id, 10..20)

      query.where_fields.size.should eq(2)

      field1 = query.where_fields[0]
      case field1
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field1[:operator].should eq(:gteq)
        field1[:value].should eq(10)
      else
        raise "Expected field-based condition"
      end

      field2 = query.where_fields[1]
      case field2
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        field2[:operator].should eq(:lteq)
        field2[:value].should eq(20)
      else
        raise "Expected field-based condition"
      end
    end

    it "chains back to regular query methods" do
      query = AdvancedQueryParent.where.gt(:id, 10).order(name: :asc).limit(5)

      query.where_fields.size.should eq(1)
      query.order_fields.size.should eq(1)
      query.limit.should eq(5)
    end
  end

  describe "Subquery support" do
    it "supports subqueries in where conditions" do
      admin_ids = AdvancedQueryParent.where(name: "admin").select(:id)
      query = AdvancedQueryChild.where(parent_id: admin_ids)

      query.where_fields.size.should eq(1)
      # The subquery should be converted to SQL
      field = query.where_fields[0]
      case field
      when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
        field[:stmt].should contain("#{AdvancedQueryChild.quote("parent_id")} IN (SELECT")
        field[:values].should eq(["admin"])
      else
        raise "Expected statement-based condition for subquery"
      end
    end

    it "supports EXISTS subqueries" do
      subquery = AdvancedQueryChild.where(name: "test")
      query = AdvancedQueryParent.where.exists(subquery)

      query.where_fields.size.should eq(1)
      field = query.where_fields[0]
      case field
      when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
        field[:stmt].should match(/EXISTS \(SELECT/)
        field[:values].should eq(["test"])
      else
        raise "Expected statement-based condition for EXISTS"
      end
    end

    it "supports NOT EXISTS subqueries" do
      subquery = AdvancedQueryChild.where(name: "test")
      query = AdvancedQueryParent.where.not_exists(subquery)

      query.where_fields.size.should eq(1)
      field = query.where_fields[0]
      case field
      when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
        field[:stmt].should match(/NOT EXISTS \(SELECT/)
        field[:values].should eq(["test"])
      else
        raise "Expected statement-based condition for NOT EXISTS"
      end
    end
  end

  describe "Complex query combinations" do
    it "combines multiple advanced features" do
      # Complex query using multiple features
      query = AdvancedQueryParent
        .where(active: true)
        .where.gt(:created_at, 1.week.ago)
        .where.not_like(:email, "%spam%")
        .or { |q| q.where(role: "admin") }
        .not { |q| q.where.is_null(:confirmed_at) }
        .order(created_at: :desc)
        .limit(10)

      # Should have multiple where conditions
      query.where_fields.size.should be > 3

      # Should have order and limit
      query.order_fields.size.should eq(1)
      query.limit.should eq(10)
    end
  end
end

# Test models for specs
class AdvancedQueryParent < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table advanced_query_parents

  column id : Int64, primary: true
  column name : String
  column email : String?
  column active : Bool = false
  column locked : Bool = false
  column role : String?
  column deleted_at : Time?
  column confirmed_at : Time?
  column created_at : Time = Time.utc
  column updated_at : Time = Time.utc

  has_many children : AdvancedQueryChild
end

class AdvancedQueryChild < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table advanced_query_children

  column id : Int64, primary: true
  column parent_id : Int64
  column name : String
  column created_at : Time = Time.utc
  column updated_at : Time = Time.utc

  belongs_to parent : AdvancedQueryParent
end
