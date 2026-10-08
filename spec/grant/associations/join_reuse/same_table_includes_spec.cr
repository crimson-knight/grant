require "../../../spec_helper"
require "../../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class JoinReuseUser < Grant::Base
    connection {{ adapter_literal }}
    table join_reuse_users
    column id : Int64, primary: true
    column active : Bool
  end

  class JoinReusePost < Grant::Base
    connection {{ adapter_literal }}
    table join_reuse_posts
    column id : Int64, primary: true
    column title : String
    column author_id : Int64?
    column editor_id : Int64?
    belongs_to :author, class_name: JoinReuseUser, foreign_key: :author_id, optional: true
    belongs_to :editor, class_name: JoinReuseUser, foreign_key: :editor_id, optional: true
  end
{% end %}

describe "includes that filter on one shared association table" do
  before_all do
    JoinReusePost.migrator.drop_and_create
    JoinReuseUser.migrator.drop_and_create
  end

  before_each do
    JoinReusePost.clear
    JoinReuseUser.clear
  end

  it "adds one join when two included associations target that table" do
    active_author = JoinReuseUser.create!(active: true)
    inactive_editor = JoinReuseUser.create!(active: false)
    post = JoinReusePost.create!(title: "matching author", author_id: active_author.id, editor_id: inactive_editor.id)

    records = [] of JoinReusePost
    statements = StatementRecorder.statements do
      records = JoinReusePost.includes(:author, :editor)
        .where("join_reuse_users.active = ?", true)
        .to_a
    end

    select_sql = statements.find! { |sql| sql.lstrip.upcase.starts_with?("SELECT") && sql.includes?("join_reuse_posts") }
    select_sql.scan(/LEFT JOIN join_reuse_users\b/i).size.should eq(1)
    records.map(&.id).should eq([post.id])
  end
end
