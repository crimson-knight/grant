require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class T3AssociationOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_association_owners
    column id : Int64, primary: true
    column label : String
    has_many :children, class_name: T3AssociationChild, foreign_key: :t3_owner_id
  end

  class T3AssociationChild < Grant::Base
    connection {{ adapter_literal }}
    table t3_association_children
    column id : Int64, primary: true
    column t3_owner_id : Int64?
    column label : String
  end

  class T3ScopeOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_scope_owners
    column id : Int64, primary: true
    column label : String
    has_many :active_children, -> { where(active: true) },
      class_name: T3ScopeChild, foreign_key: :t3_scope_owner_id
    has_many :recent_children, -> { where(active: true).order(id: :desc).limit(1) },
      class_name: T3ScopeChild, foreign_key: :t3_scope_owner_id
  end

  class T3ScopeChild < Grant::Base
    connection {{ adapter_literal }}
    table t3_scope_children
    column id : Int64, primary: true
    column t3_scope_owner_id : Int64?
    column active : Bool
  end

  class T3PrimaryOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_primary_owners
    column id : Int64, primary: true
    column external_key : Int64
    has_many :children, class_name: T3PrimaryChild,
      foreign_key: :owner_key, primary_key: :external_key
  end

  class T3PrimaryChild < Grant::Base
    connection {{ adapter_literal }}
    table t3_primary_children
    column id : Int64, primary: true
    column owner_key : Int64?
  end

  class T3DependentOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_dependent_owners
    column id : Int64, primary: true
    column label : String
    has_many :children, class_name: T3DependentChild,
      foreign_key: :t3_dependent_owner_id, dependent: :destroy
  end

  class T3DependentChild < Grant::Base
    connection {{ adapter_literal }}
    table t3_dependent_children
    column id : Int64, primary: true
    column t3_dependent_owner_id : Int64?

    before_destroy do
      T3DependentOwner.find(t3_dependent_owner_id.not_nil!).should_not be_nil
    end
  end

  class T3CacheOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_cache_owners
    column id : Int64, primary: true
    column t3_cache_articles_count : Int32 = 0
  end

  class T3CacheArticle < Grant::Base
    connection {{ adapter_literal }}
    table t3_cache_articles
    column id : Int64, primary: true
    column owner_id : Int64?
    belongs_to owner : T3CacheOwner,
      foreign_key: owner_ref_id : Int64?, optional: true, counter_cache: true
  end

  class T3RequiredOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_required_owners
    column id : Int64, primary: true
  end

  class T3RequiredChild < Grant::Base
    connection {{ adapter_literal }}
    table t3_required_children
    column id : Int64, primary: true
    belongs_to :owner, class_name: T3RequiredOwner
  end

  class T3AutosaveOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_autosave_owners
    column id : Int64, primary: true
    column label : String
    has_many :children, class_name: T3AutosaveChild,
      foreign_key: :t3_autosave_owner_id, autosave: true
  end

  class T3AutosaveChild < Grant::Base
    connection {{ adapter_literal }}
    table t3_autosave_children
    column id : Int64, primary: true
    column t3_autosave_owner_id : Int64?
    column should_fail : Bool = false

    before_create do
      abort!("autosave child rejected") if should_fail
    end
  end

  class T3ScopedRecord < Grant::Base
    connection {{ adapter_literal }}
    table t3_scoped_records
    column id : Int64, primary: true
    column tenant_id : Int64
    default_scope { where(tenant_id: 1_i64) }
  end

  class T3ScopedComment < Grant::Base
    connection {{ adapter_literal }}
    table t3_scoped_comments
    column id : Int64, primary: true
    column tenant_id : Int64
    column record_id : Int64?
    belongs_to :record, class_name: T3ScopedRecord, optional: true
    default_scope { where(tenant_id: 1_i64) }
  end

  class T3EagerParent < Grant::Base
    connection {{ adapter_literal }}
    table t3_eager_parents
    column id : Int64, primary: true
    column label : String
    has_many :children, class_name: T3EagerChild, foreign_key: :t3_eager_parent_id
  end

  class T3EagerChild < Grant::Base
    connection {{ adapter_literal }}
    table t3_eager_children
    column id : Int64, primary: true
    column t3_eager_parent_id : Int64?
    column label : String
  end

  class T3PolyTarget < Grant::Base
    connection {{ adapter_literal }}
    table t3_poly_targets
    column id : Int64, primary: true
    column label : String
    has_many :comments, class_name: T3PolyComment, as: :commentable
  end

  class T3PolyOtherTarget < Grant::Base
    connection {{ adapter_literal }}
    table t3_poly_other_targets
    column id : Int64, primary: true
    column label : String
    has_many :comments, class_name: T3PolyComment, as: :commentable
  end

  class T3PolyComment < Grant::Base
    connection {{ adapter_literal }}
    table t3_poly_comments
    column id : Int64, primary: true
    column label : String
    belongs_to :commentable, polymorphic: true, optional: true
  end

  class T3ThroughOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_through_owners
    column id : Int64, primary: true
    column label : String
    has_many :taggings, class_name: T3Tagging, foreign_key: :t3_through_owner_id
    has_many :tags, class_name: T3Tag, through: :taggings,
      source: :tag, foreign_key: :t3_through_owner_id
  end

  class T3Tag < Grant::Base
    connection {{ adapter_literal }}
    table t3_tags
    column id : Int64, primary: true
    column label : String
  end

  class T3Tagging < Grant::Base
    connection {{ adapter_literal }}
    table t3_taggings
    column id : Int64, primary: true
    column t3_through_owner_id : Int64?
    column tag_ref_id : Int64?
    belongs_to :tag, class_name: T3Tag, foreign_key: :tag_ref_id, optional: true
  end

  class T3CounterOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_counter_owners
    column id : Int64, primary: true
    column comments_total : Int32 = 0
  end

  class T3CounterComment < Grant::Base
    connection {{ adapter_literal }}
    table t3_counter_comments
    column id : Int64, primary: true
    column owner_id : Int64?
    belongs_to :owner, class_name: T3CounterOwner,
      counter_cache: :comments_total, optional: true
  end

  class T3IdsOwner < Grant::Base
    connection {{ adapter_literal }}
    table t3_ids_owners
    column id : Int64, primary: true
    column label : String
    has_many :children, class_name: T3IdsChild, foreign_key: :t3_ids_owner_id
  end

  class T3IdsChild < Grant::Base
    connection {{ adapter_literal }}
    table t3_ids_children
    column id : Int64, primary: true
    column t3_ids_owner_id : Int64?
  end
{% end %}

describe "Grant Luna association regressions" do
  before_all do
    T3AssociationOwner.migrator.drop_and_create
    T3AssociationChild.migrator.drop_and_create
    T3ScopeOwner.migrator.drop_and_create
    T3ScopeChild.migrator.drop_and_create
    T3PrimaryOwner.migrator.drop_and_create
    T3PrimaryChild.migrator.drop_and_create
    T3DependentOwner.migrator.drop_and_create
    T3DependentChild.migrator.drop_and_create
    T3CacheOwner.migrator.drop_and_create
    T3CacheArticle.migrator.drop_and_create
    T3RequiredOwner.migrator.drop_and_create
    T3RequiredChild.migrator.drop_and_create
    T3AutosaveOwner.migrator.drop_and_create
    T3AutosaveChild.migrator.drop_and_create
    T3ScopedRecord.migrator.drop_and_create
    T3ScopedComment.migrator.drop_and_create
    T3EagerParent.migrator.drop_and_create
    T3EagerChild.migrator.drop_and_create
    T3PolyTarget.migrator.drop_and_create
    T3PolyOtherTarget.migrator.drop_and_create
    T3PolyComment.migrator.drop_and_create
    T3ThroughOwner.migrator.drop_and_create
    T3Tag.migrator.drop_and_create
    T3Tagging.migrator.drop_and_create
    T3CounterOwner.migrator.drop_and_create
    T3CounterComment.migrator.drop_and_create
    T3IdsOwner.migrator.drop_and_create
    T3IdsChild.migrator.drop_and_create
  end

  it "A-1 scopes collection find and find! to the owner" do
    owner_a = T3AssociationOwner.create!(label: "a")
    owner_b = T3AssociationOwner.create!(label: "b")
    child = T3AssociationChild.create!(t3_owner_id: owner_b.id, label: "b child")

    owner_a.children.find(child.id).should be_nil
    expect_raises(Grant::Querying::NotFound) { owner_a.children.find!(child.id) }
  end

  it "A-3 applies target default scopes during eager loading" do
    secret = T3ScopedRecord.create!(tenant_id: 2_i64)
    T3ScopedComment.create!(tenant_id: 1_i64, record_id: secret.id)

    comment = T3ScopedComment.includes(:record).select.first.not_nil!
    comment.association_loaded?(:record).should be_true
    comment.get_loaded_association(:record).should be_nil
  end

  it "A-4 keeps association scope predicates in delete_all" do
    owner = T3ScopeOwner.create!(label: "owner")
    active = T3ScopeChild.create!(t3_scope_owner_id: owner.id, active: true)
    inactive = T3ScopeChild.create!(t3_scope_owner_id: owner.id, active: false)

    owner.active_children.delete_all.should eq(1)
    T3ScopeChild.find(active.id).should be_nil
    T3ScopeChild.find(inactive.id).should_not be_nil
  end

  it "A-6 uses the configured owner key for lazy, eager, and built children" do
    owner = T3PrimaryOwner.create!(external_key: 777_i64)
    child = T3PrimaryChild.create!(owner_key: owner.external_key)

    owner.children.to_a.map(&.id).should eq([child.id])
    owner.children.build.owner_key.should eq(777_i64)
    T3PrimaryOwner.includes(:children).select.first.not_nil!.children.to_a.size.should eq(1)
  end

  it "A-7 destroys dependent records before the owner" do
    owner = T3DependentOwner.create!(label: "owner")
    T3DependentChild.create!(t3_dependent_owner_id: owner.id)

    owner.destroy!.should be_true
    T3DependentChild.all.to_a.should be_empty
  end

  it "A-8 joins eager-loaded associations so associated table conditions work" do
    owner = T3EagerParent.create!(label: "owner")
    T3EagerChild.create!(t3_eager_parent_id: owner.id, label: "match")
    T3EagerChild.create!(t3_eager_parent_id: owner.id, label: "match")

    relation = T3EagerParent.eager_load(:children).where("t3_eager_children.label = ?", "match")
    relation.raw_sql.should contain("LEFT JOIN")
    eager_parents = relation.select
    eager_parents.map(&.id).should eq([owner.id])
    eager_parents.first.not_nil!.association_loaded?(:children).should be_true
    eager_parents.first.not_nil!.children.size.should eq(2)

    through_owner = T3ThroughOwner.create!(label: "through eager owner")
    through_tag = T3Tag.create!(label: "through eager match")
    T3Tagging.create!(t3_through_owner_id: through_owner.id, tag_ref_id: through_tag.id)
    through_relation = T3ThroughOwner.eager_load(:tags).where("t3_tags.label = ?", "through eager match")
    through_relation.raw_sql.should contain("LEFT JOIN")
    through_relation.select.map(&.id).should eq([through_owner.id])
  end

  it "A-9 preserves where, order, and limit in association scopes and finders" do
    owner = T3ScopeOwner.create!(label: "owner")
    T3ScopeChild.create!(t3_scope_owner_id: owner.id, active: true)
    recent = T3ScopeChild.create!(t3_scope_owner_id: owner.id, active: true)
    hidden = T3ScopeChild.create!(t3_scope_owner_id: owner.id, active: false)

    owner.recent_children.to_a.map(&.id).should eq([recent.id])
    owner.recent_children.find_by(id: hidden.id).should be_nil
  end

  it "A-10 updates both counter rows when a custom foreign key changes" do
    owner_a = T3CacheOwner.create!(t3_cache_articles_count: 0)
    owner_b = T3CacheOwner.create!(t3_cache_articles_count: 0)
    article = T3CacheArticle.create!(owner_ref_id: owner_a.id)

    T3CacheOwner.find!(owner_a.id).t3_cache_articles_count.should eq(1)
    article.owner = owner_b
    article.save!
    T3CacheOwner.find!(owner_a.id).t3_cache_articles_count.should eq(0)
    T3CacheOwner.find!(owner_b.id).t3_cache_articles_count.should eq(1)
  end

  it "A-11 rejects a dangling required belongs_to foreign key" do
    child = T3RequiredChild.new(owner_id: 999_i64)

    child.valid?.should be_false
    child.save.should be_false
  end

  it "A-12 assigns the saved owner key before autosaving new children" do
    owner = T3AutosaveOwner.new(label: "owner")
    child = T3AutosaveChild.new
    owner.children = [child]

    owner.save!.should be_true
    child.reload.t3_autosave_owner_id.should eq(owner.id)

    rejected_owner = T3AutosaveOwner.new(label: "rejected owner")
    rejected_child = T3AutosaveChild.new(should_fail: true)
    rejected_owner.children = [rejected_child]
    expect_raises(Grant::RecordNotSaved) { rejected_owner.save! }
    T3AutosaveOwner.where(label: "rejected owner").select.should be_empty
    rejected_child.new_record?.should be_true
  end

  it "A-13 exposes persistent collection mutators on lazy and loaded proxies" do
    owner = T3AssociationOwner.create!(label: "owner")
    collection = owner.children

    collection.responds_to?(:<<).should be_true
    collection.responds_to?(:delete).should be_true
    collection.responds_to?(:destroy).should be_true
    collection.responds_to?(:clear).should be_true
    collection.responds_to?(:ids).should be_true
    collection.responds_to?(:exists?).should be_true

    if collection.responds_to?(:<<)
      appended = T3AssociationChild.new(label: "appended")
      collection << appended
      appended.persisted?.should be_true
      collection.ids.should contain(appended.id)
      collection.exists?(appended.id).should be_true

      collection.delete(appended)
      T3AssociationChild.find!(appended.id).t3_owner_id.should be_nil

      movable_owner = T3AssociationOwner.create!(label: "movable owner")
      movable = movable_owner.children.create!(label: "move child")
      collection << movable
      T3AssociationChild.find!(movable.id).t3_owner_id.should eq(owner.id)

      removable = collection.create!(label: "clear me")
      loaded = T3AssociationOwner.includes(:children).where(id: owner.id).select.first.not_nil!.children
      if loaded.responds_to?(:clear)
        loaded.clear
        T3AssociationChild.find!(removable.id).t3_owner_id.should be_nil
      else
        loaded.responds_to?(:clear).should be_true
      end

      destroyable = collection.create!(label: "destroy me")
      collection.destroy(destroyable).map(&.id).should eq([destroyable.id])
      T3AssociationChild.find(destroyable.id).should be_nil

      polymorphic_owner = T3PolyTarget.create!(label: "poly owner")
      polymorphic_collection = polymorphic_owner.comments
      polymorphic_collection.responds_to?(:<<).should be_true
      polymorphic_collection.responds_to?(:delete).should be_true
      polymorphic_collection.responds_to?(:destroy).should be_true
      polymorphic_collection.responds_to?(:clear).should be_true
      polymorphic_collection.responds_to?(:ids).should be_true
      polymorphic_collection.responds_to?(:exists?).should be_true
      if polymorphic_collection.responds_to?(:<<)
        poly_comment = T3PolyComment.new(label: "mutated poly comment")
        polymorphic_collection << poly_comment
        poly_comment.persisted?.should be_true
        polymorphic_collection.ids.should contain(poly_comment.id)
        polymorphic_collection.clear
        cleared_poly_comment = T3PolyComment.find!(poly_comment.id)
        cleared_poly_comment.commentable_id.should be_nil
        cleared_poly_comment.commentable_type.should be_nil
      end
    end
  end

  it "A-14 batches polymorphic and through eager loads" do
    target = T3PolyTarget.create!(label: "target")
    comment = T3PolyComment.new(label: "comment")
    comment.commentable = target
    comment.save!
    other_target = T3PolyOtherTarget.create!(label: "other target")
    other_comment = T3PolyComment.new(label: "other comment")
    other_comment.commentable = other_target
    other_comment.save!
    loaded_comments = T3PolyComment.where(label: ["comment", "other comment"]).includes(:commentable).order(id: :asc).select
    loaded_comments.size.should eq(2)
    loaded_comments.each { |loaded| loaded.association_loaded?(:commentable).should be_true }
    loaded_comments[0].get_loaded_association(:commentable).as(T3PolyTarget).id.should eq(target.id)
    loaded_comments[1].get_loaded_association(:commentable).as(T3PolyOtherTarget).id.should eq(other_target.id)

    owner = T3ThroughOwner.create!(label: "owner")
    tag = T3Tag.create!(label: "tag")
    T3Tagging.create!(t3_through_owner_id: owner.id, tag_ref_id: tag.id)
    owner.tags.to_a.map(&.id).should eq([tag.id])
    owner.tags.find(tag.id).not_nil!.id.should eq(tag.id)
    loaded_owner = T3ThroughOwner.includes(:tags).where(id: owner.id).select.first.not_nil!
    loaded_owner.association_loaded?(:tags).should be_true
    loaded_owner.tags.to_a.map(&.id).should eq([tag.id])

    nested_owner = T3ThroughOwner.includes(taggings: :tag).where(id: owner.id).select.first.not_nil!
    nested_owner.taggings.first.not_nil!.association_loaded?(:tag).should be_true
    nested_owner.taggings.first.not_nil!.tag.not_nil!.id.should eq(tag.id)
  end

  it "A-15 deletes through join rows without deleting target rows" do
    owner = T3ThroughOwner.create!(label: "owner")
    tag = T3Tag.create!(label: "retained")
    join = T3Tagging.create!(t3_through_owner_id: owner.id, tag_ref_id: tag.id)

    owner.tags.delete_all.should eq(1)
    T3Tagging.find(join.id).should be_nil
    T3Tag.find(tag.id).should_not be_nil
  end

  it "A-17 normalizes a symbol counter-cache column" do
    owner = T3CounterOwner.create!(comments_total: 0)

    T3CounterComment.create!(owner_id: owner.id)
    T3CounterOwner.find!(owner.id).comments_total.should eq(1)
  end

  it "A-19 provides strict loading on relations and records" do
    owner = T3AssociationOwner.create!(label: "strict")
    T3AssociationChild.create!(t3_owner_id: owner.id, label: "child")

    T3AssociationOwner.where(label: "strict").responds_to?(:strict_loading).should be_true
    owner.responds_to?(:strict_loading).should be_true

    strict_relation = T3AssociationOwner.where(label: "strict")
    if strict_relation.responds_to?(:strict_loading)
      strict_owner = strict_relation.strict_loading.where(id: owner.id).select.first.not_nil!
      violation = expect_raises(Exception) { strict_owner.children.to_a }
      violation.message.to_s.should contain("not preloaded")
      relation_violation = expect_raises(Exception) { strict_owner.children.where(label: "child").select }
      relation_violation.message.to_s.should contain("not preloaded")
    end
  end

  it "A-20 generates the singular children_ids method for an irregular plural" do
    owner = T3IdsOwner.create!(label: "owner")
    owner.responds_to?(:child_ids).should be_true
    child = owner.children.create!
    if owner.responds_to?(:child_ids)
      owner.child_ids.should eq([child.id])
      owner.child_ids = [] of Int64
      T3IdsChild.find!(child.id).t3_ids_owner_id.should be_nil
    end
    owner.responds_to?(:child_ids=).should be_true
  end
end
