# Models shared by the where-clause family specs (ranges, nested hashes,
# associated/missing, merge, or/and). Each spec file recreates the tables in
# `before_all` and empties them in `before_each`.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class WfAuthor < Grant::Base
    connection {{ adapter_literal }}
    table wf_authors

    column id : Int64, primary: true
    column name : String?
    column active : Bool?

    has_many :posts, class_name: WfPost, foreign_key: author_id
  end

  class WfPost < Grant::Base
    connection {{ adapter_literal }}
    table wf_posts

    column id : Int64, primary: true
    column title : String?
    column published : Bool?
    column score : Int32?

    belongs_to author : WfAuthor, foreign_key: author_id : Int64?, optional: true
    has_many :comments, as: :commentable, class_name: WfComment
    has_many :taggings, class_name: WfTagging, foreign_key: post_id
    has_many :tags, class_name: WfTag, through: :taggings, source: :tag
  end

  class WfComment < Grant::Base
    connection {{ adapter_literal }}
    table wf_comments

    column id : Int64, primary: true
    column body : String?

    belongs_to :commentable, polymorphic: true, optional: true
  end

  class WfTag < Grant::Base
    connection {{ adapter_literal }}
    table wf_tags

    column id : Int64, primary: true
    column label : String?
  end

  class WfTagging < Grant::Base
    connection {{ adapter_literal }}
    table wf_taggings

    column id : Int64, primary: true

    belongs_to post : WfPost, foreign_key: post_id : Int64?, optional: true
    belongs_to tag : WfTag, foreign_key: tag_id : Int64?, optional: true
  end

  # A second commentable, to prove the polymorphic type column is matched.
  class WfVideo < Grant::Base
    connection {{ adapter_literal }}
    table wf_videos

    column id : Int64, primary: true
    column title : String?

    has_many :comments, as: :commentable, class_name: WfComment
  end

  class WfMeasure < Grant::Base
    connection {{ adapter_literal }}
    table wf_measures

    column id : Int64, primary: true
    column label : String?
    column rank : Int32?
    column amount : Float64?
    column happened_at : Time?
  end
{% end %}

def wf_create_tables : Nil
  WfAuthor.migrator.drop_and_create
  WfPost.migrator.drop_and_create
  WfComment.migrator.drop_and_create
  WfTag.migrator.drop_and_create
  WfTagging.migrator.drop_and_create
  WfVideo.migrator.drop_and_create
  WfMeasure.migrator.drop_and_create
end

def wf_clear_tables : Nil
  WfTagging.clear
  WfComment.clear
  WfPost.clear
  WfTag.clear
  WfVideo.clear
  WfAuthor.clear
  WfMeasure.clear
end
