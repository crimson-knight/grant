require "../../spec_helper"

class NrmQueryUser < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table nrm_query_users

  column id : Int64, primary: true
  column email : String?
  column note : String?

  normalizes :email, with: ->(value : String) { value.strip.downcase }
end

describe "normalized query conditions" do
  before_all do
    id_column = case CURRENT_ADAPTER
                when "pg"    then "BIGSERIAL PRIMARY KEY"
                when "mysql" then "BIGINT AUTO_INCREMENT PRIMARY KEY"
                else              "INTEGER PRIMARY KEY AUTOINCREMENT"
                end
    NrmQueryUser.exec("DROP TABLE IF EXISTS nrm_query_users")
    NrmQueryUser.exec("CREATE TABLE nrm_query_users (id #{id_column}, email VARCHAR(255), note VARCHAR(255))")
    NrmQueryUser.create!(email: "a@b.com", note: " Keep ")
  end

  it "find_by normalizes the search value" do
    NrmQueryUser.find_by(email: " A@B ".gsub("@B", "@B.COM")).try(&.email).should eq("a@b.com")
  end

  it "find_by! normalizes the search value" do
    NrmQueryUser.find_by!(email: "  A@B.com").email.should eq("a@b.com")
  end

  it "where normalizes equality values" do
    NrmQueryUser.where(email: " A@B.COM ").count.should eq(1)
  end

  it "chained find_by on a relation normalizes" do
    NrmQueryUser.where(note: " Keep ").find_by(email: "A@B.COM").should_not be_nil
  end

  it "leaves other columns untouched" do
    NrmQueryUser.where(note: "keep").count.should eq(0)
    NrmQueryUser.where(note: " Keep ").count.should eq(1)
  end

  it "keeps nil conditions as IS NULL" do
    NrmQueryUser.where(email: nil).count.should eq(0)
  end
end
