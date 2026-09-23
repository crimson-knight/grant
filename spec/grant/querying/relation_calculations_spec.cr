require "../../spec_helper"

{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}

  class RelationCalculationModel < Grant::Base
    connection {{ adapter_literal }}
    table relation_calculation_models

    column id : Int64, primary: true
    column category : String
    column amount : Int64
  end
{% end %}

describe "Grant relation calculations" do
  before_all do
    RelationCalculationModel.migrator.drop_and_create
  end

  before_each do
    RelationCalculationModel.clear
  end

  it "runs SQL calculations on a filtered relation" do
    RelationCalculationModel.create!(category: "included", amount: 10_i64)
    RelationCalculationModel.create!(category: "included", amount: 20_i64)
    RelationCalculationModel.create!(category: "excluded", amount: 100_i64)

    relation = RelationCalculationModel.where(category: "included")

    relation.sum(:amount).should eq(30.0)
    relation.avg(:amount).should eq(15.0)
    relation.average(:amount).should eq(15.0)
    relation.min(:amount).should eq(10_i64)
    relation.minimum(:amount).should eq(10_i64)
    relation.max(:amount).should eq(20_i64)
    relation.maximum(:amount).should eq(20_i64)
  end

  it "returns empty-relation calculation values" do
    relation = RelationCalculationModel.where(category: "missing")

    relation.sum(:amount).should eq(0.0)
    relation.avg(:amount).should be_nil
    relation.min(:amount).should be_nil
    relation.max(:amount).should be_nil
  end
end
