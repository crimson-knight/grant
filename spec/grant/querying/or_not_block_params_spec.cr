require "../../spec_helper"

# Regression specs for: grouped or/not block forms drop parameter values
# Bug: or { } and not { } stored value: nil, leaving unbound ? placeholders
# in the assembled SQL, causing wrong results or SQL errors.
describe Grant::Query::BuilderMethods do
  describe "or { } block with parameterized conditions" do
    it "returns the correct rows when the block has a single where condition" do
      Review.clear
      r1 = Review.create(name: "alice", downvotes: 1)
      r2 = Review.create(name: "bob", downvotes: 2)
      _r3 = Review.create(name: "carol", downvotes: 3)

      # WHERE name = 'bob' OR (name = 'alice')
      found = Review.where(name: "bob").or { |q| q.where(name: "alice") }.select
      names = found.map(&.name)
      names.should contain("alice")
      names.should contain("bob")
      names.should_not contain("carol")
    end

    it "returns the correct rows when the block has multiple where conditions ANDed together" do
      Review.clear
      r1 = Review.create(name: "alice", downvotes: 30)
      _r2 = Review.create(name: "alice", downvotes: 99)
      _r3 = Review.create(name: "carol", downvotes: 30)

      # WHERE name = 'carol' OR (name = 'alice' AND downvotes = 30)
      found = Review.where(name: "carol").or { |q| q.where(name: "alice").where(downvotes: 30) }.select
      names = found.map(&.name)
      names.should contain("alice")
      names.should contain("carol")
      found.size.should eq 2
      # alice with downvotes=30, carol — NOT alice with downvotes=99
      found.none? { |r| r.name == "alice" && r.downvotes == 99 }.should be_true
    end

    it "chains where + or-block and returns only matching rows" do
      Review.clear
      r_alice = Review.create(name: "alice", downvotes: 5)
      r_bob   = Review.create(name: "bob",   downvotes: 10)
      _r_eve  = Review.create(name: "eve",   downvotes: 20)

      # WHERE downvotes = 5 OR (name = 'bob' AND downvotes = 10)
      found = Review.where(downvotes: 5).or { |q| q.where(name: "bob").where(downvotes: 10) }.select
      found.size.should eq 2
      ids = found.map(&.id)
      ids.should contain(r_alice.id)
      ids.should contain(r_bob.id)
    end
  end

  describe "not { } block with parameterized conditions" do
    it "excludes rows matching parameterized conditions inside the block" do
      Review.clear
      _r1 = Review.create(name: "banned",  downvotes: 0)
      r2  = Review.create(name: "good",    downvotes: 0)
      r3  = Review.create(name: "neutral", downvotes: 0)

      # WHERE downvotes >= 0 AND NOT (name = 'banned')
      found = Review.where.gteq(:downvotes, 0).not { |q| q.where(name: "banned") }.select
      names = found.map(&.name)
      names.should_not contain("banned")
      names.should contain("good")
      names.should contain("neutral")
    end

    it "excludes rows matching multiple ANDed parameterized conditions" do
      Review.clear
      _r1 = Review.create(name: "banned", downvotes: 5)
      r2  = Review.create(name: "banned", downvotes: 99)  # different downvotes — NOT excluded
      r3  = Review.create(name: "good",   downvotes: 5)   # different name — NOT excluded

      # WHERE downvotes >= 0 AND NOT (name = 'banned' AND downvotes = 5)
      found = Review.where.gteq(:downvotes, 0).not { |q| q.where(name: "banned").where(downvotes: 5) }.select
      ids = found.map(&.id)
      ids.should contain(r2.id)
      ids.should contain(r3.id)
      ids.should_not contain(_r1.id)
    end
  end

  describe "combined where + or-block + nested and" do
    it "assembles a three-part query and returns only the matching result set" do
      Review.clear
      r_a = Review.create(name: "alice", downvotes: 1)
      r_b = Review.create(name: "bob",   downvotes: 2)
      r_c = Review.create(name: "carol", downvotes: 3)
      _r_d = Review.create(name: "dave",  downvotes: 4)

      # WHERE name = 'alice' OR (name = 'bob' AND downvotes = 2) OR (name = 'carol' AND downvotes = 3)
      found = Review
        .where(name: "alice")
        .or { |q| q.where(name: "bob").where(downvotes: 2) }
        .or { |q| q.where(name: "carol").where(downvotes: 3) }
        .select

      ids = found.map(&.id)
      ids.should contain(r_a.id)
      ids.should contain(r_b.id)
      ids.should contain(r_c.id)
      ids.should_not contain(_r_d.id)
      found.size.should eq 3
    end
  end
end
