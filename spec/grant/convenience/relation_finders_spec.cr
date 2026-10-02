require "../../spec_helper"
require "../../support/convenience_models"
require "../../support/association_query_counter"

describe "relation finders" do
  before_all { ConvenienceSpecSupport.reset_items }
  before_each do
    ConvItem.clear
    ConvItem.create!(name: "a", status: "draft", kind: "k1")
    ConvItem.create!(name: "b", status: "draft", kind: "k1")
    ConvItem.create!(name: "c", status: "live", kind: "k2")
  end

  it "find_by narrows the relation" do
    ConvItem.where(status: "draft").find_by(name: "b").not_nil!.name.should eq("b")
    ConvItem.where(status: "draft").find_by(name: "c").should be_nil
  end

  it "find_by matches nil as IS NULL and accepts a hash" do
    ConvItem.where(status: "draft").find_by(qty: nil).should_not be_nil
    ConvItem.where(status: "draft").find_by({"name" => "a"} of Symbol | String => Grant::Columns::Type).should_not be_nil
  end

  it "find_by! raises NotFound naming the criteria" do
    ConvItem.where(status: "draft").find_by!(name: "a").name.should eq("a")
    error = expect_raises(Grant::Querying::NotFound) { ConvItem.where(status: "draft").find_by!(name: "c") }
    error.message.to_s.should contain("name = c")
  end

  it "find_sole_by returns the only match and reads at most two rows" do
    ConvItem.where(status: "live").find_sole_by(name: "c").name.should eq("c")
    statements = [] of String
    expect_raises(Grant::Querying::NotUnique) do
      statements = AssociationQueryCounter.statements { ConvItem.where(kind: "k1").find_sole_by(status: "draft") }
      # statements is only assigned when no error is raised
    end
  end

  it "find_sole_by limits the query to two rows" do
    statements = AssociationQueryCounter.statements do
      begin
        ConvItem.where(kind: "k1").find_sole_by(status: "draft")
      rescue Grant::Querying::NotUnique
      end
    end
    statements.size.should eq(1)
    statements.first.should contain("LIMIT 2")
  end

  it "find_sole_by raises NotFound when nothing matches" do
    expect_raises(Grant::Querying::NotFound) { ConvItem.where(status: "live").find_sole_by(name: "a") }
  end

  it "works on named scopes" do
    ConvItem.drafts.find_by(name: "a").should_not be_nil
    ConvItem.drafts.find_by(name: "c").should be_nil
    ConvItem.drafts.find_by!(name: "b").name.should eq("b")
    ConvItem.drafts.find_sole_by(name: "a").name.should eq("a")
    ConvItem.drafts.find(ConvItem.find_by!(name: "a").id.not_nil!).should_not be_nil
  end

  it "does not change the receiver" do
    relation = ConvItem.where(status: "draft")
    relation.find_by(name: "a")
    relation.where_fields.size.should eq(1)
  end

  it "keeps the class-level finders working" do
    ConvItem.find_by(name: "a").not_nil!.name.should eq("a")
    ConvItem.find_sole_by(name: "c").name.should eq("c")
  end
end
