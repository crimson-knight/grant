require "./spec_helper"

describe "Grant::Query::Builder - Modifiers" do
  describe "#reorder" do
    it "clears existing order and replaces" do
      query = builder.order(name: :asc).reorder(age: :desc)
      query.order_fields.size.should eq 1
      query.order_fields.first[:field].should eq "age"
      query.order_fields.first[:direction].should eq Grant::Query::Builder::Sort::Descending
    end

    it "clears multiple existing orders" do
      query = builder.order(name: :asc).order(age: :desc).reorder(name: :desc)
      query.order_fields.size.should eq 1
      query.order_fields.first[:field].should eq "name"
      query.order_fields.first[:direction].should eq Grant::Query::Builder::Sort::Descending
    end

    it "accepts a single symbol field" do
      query = builder.order(name: :desc).reorder(:age)
      query.order_fields.size.should eq 1
      query.order_fields.first[:field].should eq "age"
      query.order_fields.first[:direction].should eq Grant::Query::Builder::Sort::Ascending
    end
  end

  describe "#reverse_order" do
    it "flips ascending to descending" do
      query = builder.order(name: :asc).reverse_order
      query.order_fields.first[:direction].should eq Grant::Query::Builder::Sort::Descending
    end

    it "flips descending to ascending" do
      query = builder.order(name: :desc).reverse_order
      query.order_fields.first[:direction].should eq Grant::Query::Builder::Sort::Ascending
    end

    it "flips all order directions" do
      query = builder.order(name: :asc).order(age: :desc).reverse_order
      query.order_fields[0][:direction].should eq Grant::Query::Builder::Sort::Descending
      query.order_fields[1][:direction].should eq Grant::Query::Builder::Sort::Ascending
    end

    it "is a no-op when no orders set" do
      query = builder.reverse_order
      query.order_fields.should be_empty
    end
  end

  describe "#rewhere" do
    it "clears existing where conditions and replaces" do
      query = builder.where(name: "bob").rewhere(name: "alice")
      query.where_fields.size.should eq 1
      field = query.where_fields.first
      field.should eq({join: :and, field: "name", operator: :eq, value: "alice"})
    end

    it "clears all where conditions" do
      query = builder.where(name: "bob").where(age: 25).rewhere(name: "alice")
      query.where_fields.size.should eq 1
    end
  end

  describe "#reselect" do
    it "clears existing select columns and replaces" do
      query = builder.select(:id, :name).reselect(:id, :email)
      query.select_columns.should eq ["id", "email"]
    end
  end

  describe "#regroup" do
    it "clears existing group and replaces with single field" do
      query = builder.group_by(:status).regroup(:department)
      query.group_fields.size.should eq 1
      query.group_fields.first[:field].should eq "department"
    end

    it "accepts multiple fields" do
      query = builder.group_by(:status).regroup(:department, :role)
      query.group_fields.size.should eq 2
      query.group_fields[0][:field].should eq "department"
      query.group_fields[1][:field].should eq "role"
    end
  end

  describe "#none" do
    it "sets the is_none flag" do
      query = builder.none
      query.is_none?.should be_true
    end

    it "defaults to not none" do
      query = builder
      query.is_none?.should be_false
    end

    it "none chains safely with where and order" do
      query = builder.none.where(name: "bob").order(name: :asc)
      query.is_none?.should be_true
      query.where_fields.size.should eq 1
      query.order_fields.size.should eq 1
    end
  end

  describe "dup preserves none" do
    it "copies none flag on dup" do
      original = builder.none
      copy = original.dup
      copy.is_none?.should be_true
    end

    it "non-none is preserved on dup" do
      original = builder
      copy = original.dup
      copy.is_none?.should be_false
    end
  end

  describe "merge preserves none" do
    it "merges none flag from other builder" do
      b1 = builder
      b2 = builder.none
      b1.merge(b2)
      b1.is_none?.should be_true
    end
  end
end
