require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  # No `include Grant::SignedId`: every model has it.
  class W6SignedPlain < Grant::Base
    connection {{ adapter_literal }}
    table w6_signed_plains

    column id : Int64, primary: true
    column name : String?
  end

  class W6SignedComposite < Grant::Base
    include Grant::CompositePrimaryKey

    connection {{ adapter_literal }}
    table w6_signed_composites

    column shop_id : Int64, primary: true, auto: false
    column order_id : Int64, primary: true, auto: false
    column note : String?
    composite_primary_key shop_id, order_id
  end
{% end %}

W6SignedPlain.migrator.drop_and_create
W6SignedComposite.migrator.drop_and_create

describe "Signed ids on every model" do
  before_each do
    Grant::SignedId.configure { |config| config.secret = "w6-signed-id-secret"; config.previous_secrets = [] of String }
    W6SignedPlain.clear
    W6SignedComposite.clear
  end

  after_each do
    Grant::SignedId.configure { |config| config.secret = nil; config.previous_secrets = [] of String }
  end

  it "signs and finds a model that never included Grant::SignedId" do
    record = W6SignedPlain.create!(name: "plain")
    token = record.signed_id(purpose: :reset, expires_in: 1.hour)
    W6SignedPlain.find_signed(token, purpose: :reset).not_nil!.id.should eq(record.id)
    W6SignedPlain.find_signed(token, purpose: :other).should be_nil
    W6SignedPlain.find_signed!(token, purpose: :reset).id.should eq(record.id)
    expect_raises(Grant::InvalidSignedId) { W6SignedPlain.find_signed!(token, purpose: :other) }
    expect_raises(Grant::InvalidSignedId) { W6SignedPlain.find_signed!("garbage", purpose: :reset) }
  end

  it "does not let a token cross models" do
    record = W6SignedPlain.create!(name: "plain")
    W6SignedComposite.find_signed(record.signed_id).should be_nil
  end

  describe "composite primary keys" do
    it "signs the whole key tuple and finds the row" do
      row = W6SignedComposite.create!(shop_id: 1_i64, order_id: 10_i64, note: "a")
      other = W6SignedComposite.create!(shop_id: 1_i64, order_id: 11_i64, note: "b")

      token = row.signed_id(purpose: :share)
      found = W6SignedComposite.find_signed(token, purpose: :share).not_nil!
      found.shop_id.should eq(1_i64)
      found.order_id.should eq(10_i64)
      found.note.should eq("a")
      W6SignedComposite.find_signed(other.signed_id(purpose: :share), purpose: :share).not_nil!.order_id.should eq(11_i64)
    end

    it "returns nil when the row is gone and raises from find_signed!" do
      row = W6SignedComposite.create!(shop_id: 2_i64, order_id: 20_i64)
      token = row.signed_id
      row.destroy
      W6SignedComposite.find_signed(token).should be_nil
      expect_raises(Grant::RecordNotFound) { W6SignedComposite.find_signed!(token) }
    end

    it "rejects a tampered or expired token" do
      row = W6SignedComposite.create!(shop_id: 3_i64, order_id: 30_i64)
      W6SignedComposite.find_signed(row.signed_id + "x").should be_nil
      W6SignedComposite.find_signed(row.signed_id(expires_at: Time.utc - 1.minute)).should be_nil
    end
  end
end
