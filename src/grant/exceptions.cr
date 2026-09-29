module Grant
  # Raised by `save!`, `create!` and `update!` when the record could not be
  # persisted. Validation failures raise the `Grant::RecordInvalid` subclass.
  class RecordNotSaved < ErrorBase
    getter model : Grant::Base

    def initialize(class_name : String, @model : Grant::Base, cause : ::Exception? = nil)
      super("Could not process #{class_name}: #{RecordNotSaved.reason_for(model)}", cause)
    end

    # The translated database error behind the failure, when the save stopped
    # at a constraint or other statement error. It lets callers tell a
    # `Grant::RecordNotUnique` from a callback abort without parsing text.
    def statement_error : Grant::StatementInvalid?
      cause.as?(Grant::StatementInvalid)
    end

    # The first recorded error, or a fixed sentence when a callback halted the
    # save without recording one.
    # :nodoc:
    def self.reason_for(model : Grant::Base) : String
      first_error = model.errors.first?
      first_error.try(&.message) || "the save was halted before the record was persisted"
    end
  end

  module Associations
    # Raised when destroying a record that still has dependent records and the
    # association was declared with `dependent: :restrict_with_exception`.
    #
    # Mirrors ActiveRecord's `ActiveRecord::DeleteRestrictionError`.
    class RestrictError < ErrorBase
      def initialize(association_name : String)
        super("Cannot delete record because of dependent #{association_name}")
      end
    end
  end

  class RecordNotDestroyed < ErrorBase
    getter model : Grant::Base

    def initialize(class_name : String, @model : Grant::Base)
      super("Could not destroy #{class_name}: #{RecordNotSaved.reason_for(model)}")
    end
  end

  # Raised when attempting to update or destroy a record (or column) that has
  # been marked read-only — either because the record was flagged with
  # `#readonly!` / loaded as part of a read-only relation, or because the column
  # was declared with `attr_readonly`.
  #
  # Mirrors ActiveRecord's `ActiveRecord::ReadOnlyRecord`.
  class ReadOnlyRecordError < ErrorBase
    def initialize(message : String = "Record is marked as read only")
      super(message)
    end
  end
end
