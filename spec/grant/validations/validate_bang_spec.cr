require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V01BangPost < Grant::Base
    connection {{ adapter_literal }}
    table v01_bang_posts

    column id : Int64, primary: true
    column title : String?
    column summary : String?

    validates_presence_of :title
    validates_presence_of :summary, on: :publish
  end
{% end %}

describe "validate!" do
  it "returns the record when it is valid" do
    post = V01BangPost.new
    post.title = "Hi"
    post.validate!.should be(post)
  end

  it "raises Grant::RecordInvalid with the full messages when invalid" do
    post = V01BangPost.new
    ex = expect_raises(Grant::RecordInvalid, "Validation failed: Title can't be blank") do
      post.validate!
    end
    ex.record.should be(post)
    post.errors.map(&.field.to_s).should eq(["title"])
  end

  it "is a Grant::RecordNotSaved and a Grant::ErrorBase" do
    expect_raises(Grant::RecordNotSaved) { V01BangPost.new.validate! }
    expect_raises(Grant::ErrorBase) { V01BangPost.new.validate! }
  end

  it "accepts a context" do
    post = V01BangPost.new
    post.title = "Hi"
    post.validate!.should be(post)
    expect_raises(Grant::RecordInvalid, /Summary can't be blank/) { post.validate!(:publish) }
    expect_raises(Grant::RecordInvalid, /Summary can't be blank/) { post.validate!(context: :publish) }
    post.summary = "s"
    post.validate!(:publish).should be(post)
    post.validate!([:create, :publish]).should be(post)
  end

  it "has a validate(context) alias returning Bool" do
    post = V01BangPost.new
    post.title = "Hi"
    post.validate.should be_true
    post.validate(:publish).should be_false
    post.validate(context: :publish).should be_false
    post.errors.map(&.field.to_s).should eq(["summary"])
  end
end
