module Grant::Associations
  # Raised when a write to a `has_many :through` collection cannot be expressed
  # as join-row writes, for example when the source association on the join
  # model is not a `belongs_to`.
  #
  # Mirrors ActiveRecord's `HasManyThroughCantAssociateThroughHasOneOrManyReflection`.
  class ThroughWriteError < Grant::ErrorBase
  end

  # Raised when a collection writer that needs a persisted owner (`create`,
  # `create!`) is called on an owner that has not been saved.
  #
  # Mirrors ActiveRecord's `RecordNotSaved` with "You cannot call create unless
  # the parent is saved".
  class OwnerNotSaved < Grant::RecordNotSaved
    def initialize(owner : Grant::Base, association_name : String, action : String)
      super(owner.class.name, owner)
      @message = "You cannot call #{action} unless the parent is saved (#{owner.class.name}##{association_name})"
    end
  end

  # The join-table side of a `has_many :through` collection: the key the join
  # rows reference on the target, and the statements that write the join rows.
  # Every write is set-based, one statement per call. Built by
  # `Grant::AssociationCollection#through_writer`, which knows the join model.
  class ThroughWriter
    # The target attribute the join rows reference (usually the primary key).
    getter target_key : String

    def initialize(@target_key : String,
                   @insert : Proc(Grant::Columns::Type, Array(Grant::Columns::Type), Nil),
                   @remove : Proc(Grant::Columns::Type, Array(Grant::Columns::Type)?, Bool, Int64))
    end

    # Inserts one join row per key with a single multi-row INSERT.
    def insert(owner_key : Grant::Columns::Type, target_keys : Array(Grant::Columns::Type)) : Nil
      return if target_keys.empty?
      @insert.call(owner_key, target_keys)
    end

    # Deletes (or, with *destroy*, destroys) the owner's join rows, limited to
    # *target_keys* when given. Returns the number of rows removed.
    def remove(owner_key : Grant::Columns::Type, target_keys : Array(Grant::Columns::Type)?, destroy : Bool) : Int64
      return 0_i64 if target_keys && target_keys.empty?
      @remove.call(owner_key, target_keys, destroy)
    end
  end
end
