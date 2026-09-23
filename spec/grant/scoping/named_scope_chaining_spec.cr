require "../../spec_helper"

{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}

  class NamedScopeChainModel < Grant::Base
    connection {{ adapter_literal }}
    table named_scope_chain_models

    column id : Int64, primary: true
    column status : String
    column published : Bool = false
    column deleted_at : Time?

    scope :published, ->(query : Grant::Query::Builder(NamedScopeChainModel)) { query.where(published: true) }
    scope :with_status, ->(query : Grant::Query::Builder(NamedScopeChainModel), status : String) { query.where(status: status) }
    scope :status_named, ->(status : String) { NamedScopeChainModel.where(status: status) }
    scope :recent, ->(query : Grant::Query::Builder(NamedScopeChainModel)) { query.order(id: :desc) }

    default_scope { where(deleted_at: nil) }
  end
{% end %}

describe "chainable named scopes" do
  before_all do
    NamedScopeChainModel.migrator.drop_and_create
  end

  before_each do
    NamedScopeChainModel.unscoped.delete_all
  end

  it "chains named scopes over the same relation and preserves the default scope" do
    visible = NamedScopeChainModel.create!(status: "active", published: true)
    NamedScopeChainModel.create!(status: "inactive", published: true)
    NamedScopeChainModel.create!(status: "active", published: true, deleted_at: Time.local)

    relation = NamedScopeChainModel.published.with_status("active")
    results = relation.all
    class_method_results = NamedScopeChainModel.published.status_named("active").all

    results.map(&.id).should eq([visible.id])
    class_method_results.map(&.id).should eq([visible.id])
  end

  it "chains a named scope after regular relation methods" do
    older = NamedScopeChainModel.create!(status: "active", published: true)
    newer = NamedScopeChainModel.create!(status: "active", published: true)

    results = NamedScopeChainModel.published.where(status: "active").recent.all

    results.map(&.id).should eq([newer.id, older.id])
  end
end
