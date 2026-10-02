require "../../spec_helper"

class W6oeAuthor < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6oe_authors

  column id : Int64, primary: true
  column name : String?
  column deleted : Bool = false

  default_scope { where(deleted: false) }

  has_many :posts, class_name: W6oePost, foreign_key: author_id
end

class W6oePost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6oe_posts

  column id : Int64, primary: true
  column title : String?
  column author_id : Int64?

  belongs_to :author, class_name: W6oeAuthor, foreign_key: author_id, optional: true
end

describe "only and except with eager-loading components" do
  before_all do
    W6oeAuthor.migrator.drop_and_create
    W6oePost.migrator.drop_and_create
  end

  before_each do
    W6oePost.clear
    W6oeAuthor.unscoped.delete_all
    ann = W6oeAuthor.create!(name: "ann")
    bob = W6oeAuthor.create!(name: "bob")
    W6oeAuthor.create!(name: "gone", deleted: true)
    W6oePost.create!(title: "a1", author_id: ann.id)
    W6oePost.create!(title: "a2", author_id: ann.id)
    W6oePost.create!(title: "b1", author_id: bob.id)
  end

  describe "except" do
    it "drops :includes, :preload and :eager_load" do
      base = W6oeAuthor.includes(:posts).preload(:posts).eager_load(:posts)
      base.except(:includes).includes_associations.should be_empty
      base.except(:includes).preload_associations.should_not be_empty
      base.except(:preload).preload_associations.should be_empty
      base.except(:eager_load).eager_load_associations.should be_empty
      base.except(:includes, :preload, :eager_load).to_sql.should_not contain("JOIN")
    end

    it "loads without the dropped association, so reading it queries on demand" do
      authors = W6oeAuthor.includes(:posts).except(:includes).order(:id).select
      authors.each { |author| author.association_loaded?("posts").should be_false }
      loaded = W6oeAuthor.includes(:posts).order(:id).select
      loaded.each { |author| author.association_loaded?("posts").should be_true }
    end

    it "drops :strict_loading, :readonly, :annotate, :optimizer_hints and :create_with" do
      base = W6oeAuthor.strict_loading.readonly.annotate("zzmark").optimizer_hints("MAX_EXECUTION_TIME(5)").create_with(name: "z")
      trimmed = base.except(:strict_loading, :readonly, :annotate, :optimizer_hints, :create_with)
      trimmed.strict_loading?.should be_false
      trimmed.readonly?.should be_false
      trimmed.to_sql.should_not contain("zzmark")
      trimmed.to_sql.should_not contain("MAX_EXECUTION_TIME")
      trimmed.create_with_attributes.should be_empty
      base.strict_loading?.should be_true
      base.readonly?.should be_true
    end

    it "drops joins and left joins separately" do
      base = W6oeAuthor.joins(:posts).left_joins(:posts, as: "all_posts")
      base.except(:left_joins).to_sql.should contain("INNER JOIN")
      base.except(:left_joins).to_sql.should_not contain("LEFT JOIN")
      base.except(:joins).to_sql.should contain("LEFT JOIN")
      base.except(:joins).to_sql.should_not contain("INNER JOIN")
    end
  end

  describe "only" do
    it "keeps just the named components, eager-loading lists included" do
      base = W6oeAuthor.where(name: "ann").order(:name).includes(:posts).preload(:posts).strict_loading.limit(1)
      kept = base.only(:where, :includes)
      kept.where_fields.size.should eq(1)
      kept.includes_associations.should_not be_empty
      kept.preload_associations.should be_empty
      kept.order_fields.should be_empty
      kept.limit.should be_nil
      kept.strict_loading?.should be_false
    end

    it "only(:where) drops includes, preload, eager_load and strict_loading" do
      pure = W6oeAuthor.where(name: "ann").includes(:posts).preload(:posts).eager_load(:posts).strict_loading.only(:where)
      pure.includes_associations.should be_empty
      pure.preload_associations.should be_empty
      pure.eager_load_associations.should be_empty
      pure.strict_loading?.should be_false
      pure.to_sql.should_not contain("JOIN")
      pure.select.map(&.name).should eq(["ann"])
    end

    it "keeps :strict_loading when asked to" do
      W6oeAuthor.strict_loading.where(name: "ann").only(:strict_loading).strict_loading?.should be_true
    end

    it "accepts the aliases group_by and left_outer_joins" do
      base = W6oeAuthor.group_by(:name).left_joins(:posts, as: "p")
      base.only(:group_by).group_fields.should_not be_empty
      base.only(:group_by).to_sql.should_not contain("JOIN")
      base.only(:left_outer_joins).to_sql.should contain("LEFT JOIN")
    end

    it "rejects an unknown component" do
      expect_raises(ArgumentError, /unknown component/) { W6oeAuthor.all.only(:includes, :nonsense) }
      expect_raises(ArgumentError, /unknown component/) { W6oeAuthor.all.except(:nonsense) }
    end
  end

  describe "default scope" do
    it "stays in place, like unscope(:where): only/except never expose scoped-out rows" do
      W6oeAuthor.where(name: "gone").except(:where).select.map(&.name.to_s).sort!.should eq(["ann", "bob"])
      W6oeAuthor.where(name: "gone").only(:order).count.should eq(2)
      W6oeAuthor.where(name: "gone").only(:where).select.should be_empty
      W6oeAuthor.unscoped.where(name: "gone").only(:where).select.map(&.name).should eq(["gone"])
    end
  end

  describe "both adapters" do
    it "runs a relation trimmed of its eager loading" do
      names = W6oeAuthor.includes(:posts).where(name: "ann").except(:includes).select.map(&.name)
      names.should eq(["ann"])
    end
  end
end
