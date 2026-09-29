require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02dTicket < Grant::Base
    connection {{ adapter_literal }}
    table v02d_tickets

    column id : Int64, primary: true
    column code : String?
    column short_code : String?
    column long_code : String?
    column exact_code : String?
    column score : Int32?

    validates_length_of :code, minimum: 4
    validates_length_of :short_code, maximum: 2
    validates_length_of :long_code, is: 6
    validates_numericality_of :score, greater_than: 0, allow_nil: true
    validates_presence_of :exact_code
  end
{% end %}

describe "errors.details with options" do
  it "carries count: for length validators" do
    ticket = V02dTicket.new(code: "ab", short_code: "abcd", long_code: "abc", exact_code: "x")
    ticket.valid?.should be_false
    ticket.errors.details["code"].should eq([{:error => :too_short, :count => 4}])
    ticket.errors.details["short_code"].should eq([{:error => :too_long, :count => 2}])
    ticket.errors.details["long_code"].should eq([{:error => :wrong_length, :count => 6}])
  end

  it "carries count: and value: for numericality" do
    ticket = V02dTicket.new(code: "abcd", short_code: "a", long_code: "abcdef", exact_code: "x", score: -3)
    ticket.valid?.should be_false
    ticket.errors.details["score"].should eq([{:error => :greater_than, :count => 0, :value => -3}])
  end

  it "has no options for a plain presence failure" do
    ticket = V02dTicket.new(code: "abcd", short_code: "a", long_code: "abcdef", exact_code: nil)
    ticket.valid?.should be_false
    ticket.errors.details["exact_code"].should eq([{:error => :blank}])
  end

  it "merges the options given to errors.add into the detail" do
    errors = Grant::Errors.new
    errors.add(:age, "too low", type: :greater_than, count: 18, value: 3)
    errors.details["age"].should eq([{:error => :greater_than, :count => 18, :value => 3}])
    errors.first.options[:count].should eq(18)
    errors.first.detail.should eq({:error => :greater_than, :count => 18, :value => 3})
  end

  it "falls back to :invalid and stores options of many types" do
    errors = Grant::Errors.new
    errors.add(:name, "odd", flag: true, ratio: 1.5, names: ["a", "b"], range: 1..3)
    errors.details["name"].should eq([{:error => :invalid, :flag => true, :ratio => 1.5, :names => ["a", "b"], :range => (1..3)}])
  end

  it "builds details lazily and does not share hashes between calls" do
    errors = Grant::Errors.new
    errors.add(:name, :too_short, count: 3)
    first = errors.details
    first["name"].first[:count] = 99
    errors.details["name"].first[:count].should eq(3)
  end

  it "keeps details keyed by attribute name Strings" do
    errors = Grant::Errors.new
    errors.add(:name, :blank)
    errors.details.keys.should eq(["name"])
  end
end
