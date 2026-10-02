require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class AeItem < Grant::Base
    connection {{ adapter_literal }}
    table ae_items
    column id : Int64, primary: true
    column weight : Int64
  end
{% end %}

describe "aggregations next to the Enumerable forms" do
  before_all { AeItem.migrator.drop_and_create }

  before_each do
    AeItem.clear
    AeItem.create!(weight: 2_i64)
    AeItem.create!(weight: 5_i64)
  end

  it "keeps the block forms of Enumerable on a relation" do
    AeItem.all.sum(&.weight).should eq(7_i64)
    AeItem.all.max_of(&.weight).should eq(5_i64)
    AeItem.all.count { |item| item.weight > 3 }.should eq(1)
  end

  it "answers the column forms in SQL" do
    AeItem.all.sum(:weight).should eq(7_i64)
    AeItem.all.count(:weight).should eq(2_i64)
  end

  it "counts through the model class, with a column and distinct" do
    AeItem.count.should eq(2_i64)
    AeItem.count(:weight).should eq(2_i64)
    AeItem.count(:weight, distinct: true).should eq(2_i64)
  end

  it "sums and averages through the model class as scalars" do
    AeItem.sum(:weight).should eq(7_i64)
    AeItem.sum(:weight).should be_a(Int64)
    AeItem.avg(:weight).should eq(3.5)
    AeItem.min(:weight).should eq(2_i64)
    AeItem.max(:weight).should eq(5_i64)
  end
end
