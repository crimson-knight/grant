require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6dOwner < Grant::Base
    connection {{ adapter_literal }}
    table w6d_owners
    column id : Int64, primary: true
    column name : String?
    has_many :w6d_published, -> { where(published: true) }, class_name: W6dPost, foreign_key: :w6d_owner_id, dependent: :destroy
    has_one :w6d_main_badge, -> { where(main: true) }, class_name: W6dBadge, foreign_key: :w6d_owner_id, dependent: :destroy
    has_many :w6d_links, class_name: W6dLink, foreign_key: :w6d_owner_id
    has_many :w6d_tags, class_name: W6dTag, through: :w6d_links, dependent: :destroy
  end

  class W6dNullifyOwner < Grant::Base
    connection {{ adapter_literal }}
    table w6d_nullify_owners
    column id : Int64, primary: true
    column name : String?
    has_many :w6d_published, -> { where(published: true) }, class_name: W6dPost, foreign_key: :w6d_nullify_owner_id, dependent: :nullify
  end

  class W6dDeleteOwner < Grant::Base
    connection {{ adapter_literal }}
    table w6d_delete_owners
    column id : Int64, primary: true
    column name : String?
    has_many :w6d_published, -> { where(published: true) }, class_name: W6dPost, foreign_key: :w6d_delete_owner_id, dependent: :delete_all
  end

  class W6dRestrictOwner < Grant::Base
    connection {{ adapter_literal }}
    table w6d_restrict_owners
    column id : Int64, primary: true
    column name : String?
    has_many :w6d_published, -> { where(published: true) }, class_name: W6dPost, foreign_key: :w6d_restrict_owner_id, dependent: :restrict_with_error
  end

  class W6dPost < Grant::Base
    connection {{ adapter_literal }}
    table w6d_posts
    column id : Int64, primary: true
    column title : String?
    column published : Bool = false
    column w6d_owner_id : Int64?
    column w6d_nullify_owner_id : Int64?
    column w6d_delete_owner_id : Int64?
    column w6d_restrict_owner_id : Int64?

    class_property destroyed_titles = [] of String?
    after_destroy { W6dPost.destroyed_titles << title }
  end

  class W6dBadge < Grant::Base
    connection {{ adapter_literal }}
    table w6d_badges
    column id : Int64, primary: true
    column label : String?
    column main : Bool = false
    column w6d_owner_id : Int64?
  end

  class W6dTag < Grant::Base
    connection {{ adapter_literal }}
    table w6d_tags
    column id : Int64, primary: true
    column label : String?
  end

  class W6dLink < Grant::Base
    connection {{ adapter_literal }}
    table w6d_links
    column id : Int64, primary: true
    column w6d_owner_id : Int64?
    column w6d_tag_id : Int64?
    belongs_to :w6d_owner, class_name: W6dOwner, foreign_key: :w6d_owner_id, optional: true
    belongs_to :w6d_tag, class_name: W6dTag, foreign_key: :w6d_tag_id, optional: true
  end
{% end %}

describe "dependent honors the association scope and through join rows" do
  before_all do
    W6dOwner.migrator.drop_and_create
    W6dNullifyOwner.migrator.drop_and_create
    W6dDeleteOwner.migrator.drop_and_create
    W6dRestrictOwner.migrator.drop_and_create
    W6dPost.migrator.drop_and_create
    W6dBadge.migrator.drop_and_create
    W6dTag.migrator.drop_and_create
    W6dLink.migrator.drop_and_create
  end

  before_each do
    W6dLink.clear
    W6dTag.clear
    W6dBadge.clear
    W6dPost.clear
    W6dOwner.clear
    W6dNullifyOwner.clear
    W6dDeleteOwner.clear
    W6dRestrictOwner.clear
    W6dPost.destroyed_titles.clear
  end

  it "dependent: :destroy on a scoped has_many destroys only the scoped rows" do
    owner = W6dOwner.create!(name: "o")
    W6dPost.create!(title: "pub1", published: true, w6d_owner_id: owner.id)
    W6dPost.create!(title: "pub2", published: true, w6d_owner_id: owner.id)
    draft = W6dPost.create!(title: "draft", published: false, w6d_owner_id: owner.id)

    owner.destroy

    W6dPost.destroyed_titles.compact.sort!.should eq(["pub1", "pub2"])
    W6dPost.count.should eq(1)
    W6dPost.find!(draft.id).w6d_owner_id.should eq(owner.id)
  end

  it "dependent: :nullify on a scoped has_many clears only the scoped rows" do
    owner = W6dNullifyOwner.create!(name: "o")
    pub = W6dPost.create!(title: "pub", published: true, w6d_nullify_owner_id: owner.id)
    draft = W6dPost.create!(title: "draft", published: false, w6d_nullify_owner_id: owner.id)

    owner.destroy

    W6dPost.find!(pub.id).w6d_nullify_owner_id.should be_nil
    W6dPost.find!(draft.id).w6d_nullify_owner_id.should eq(owner.id)
  end

  it "dependent: :delete_all on a scoped has_many deletes only the scoped rows" do
    owner = W6dDeleteOwner.create!(name: "o")
    W6dPost.create!(title: "pub", published: true, w6d_delete_owner_id: owner.id)
    draft = W6dPost.create!(title: "draft", published: false, w6d_delete_owner_id: owner.id)

    owner.destroy

    W6dPost.all.map(&.id).should eq([draft.id])
    W6dPost.destroyed_titles.should be_empty
  end

  it "restrict_with_error only blocks when scoped rows exist" do
    owner = W6dRestrictOwner.create!(name: "o")
    W6dPost.create!(title: "draft", published: false, w6d_restrict_owner_id: owner.id)

    owner.destroy.should be_true

    blocked = W6dRestrictOwner.create!(name: "o")
    W6dPost.create!(title: "pub", published: true, w6d_restrict_owner_id: blocked.id)
    blocked.destroy.should be_false
    W6dRestrictOwner.find(blocked.id).should_not be_nil
  end

  it "a scoped has_one with dependent: :destroy destroys only the scoped row" do
    owner = W6dOwner.create!(name: "o")
    other = W6dBadge.create!(label: "plain", main: false, w6d_owner_id: owner.id)
    main = W6dBadge.create!(label: "main", main: true, w6d_owner_id: owner.id)

    owner.destroy

    W6dBadge.find(main.id).should be_nil
    W6dBadge.find(other.id).should_not be_nil
  end

  it "dependent on has_many :through acts on the join rows and keeps the targets" do
    owner = W6dOwner.create!(name: "o")
    other = W6dOwner.create!(name: "other")
    tags = ["a", "b"].map { |label| W6dTag.create!(label: label) }
    tags.each { |tag| W6dLink.create!(w6d_owner_id: owner.id, w6d_tag_id: tag.id) }
    W6dLink.create!(w6d_owner_id: other.id, w6d_tag_id: tags.first.id)

    owner.destroy

    W6dTag.count.should eq(2)
    W6dLink.where(w6d_owner_id: owner.id).count.should eq(0)
    W6dLink.where(w6d_owner_id: other.id).count.should eq(1)
  end
end
