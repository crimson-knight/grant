module Grant
  class RecordNotSaved < ::Exception
    getter model : Grant::Base

    def initialize(class_name : String, @model : Grant::Base)
      super("Could not process #{class_name}: #{model.errors.first.message}")
    end
  end

  module Associations
    # Raised when destroying a record that still has dependent records and the
    # association was declared with `dependent: :restrict_with_exception`.
    #
    # Mirrors ActiveRecord's `ActiveRecord::DeleteRestrictionError`.
    class RestrictError < ::Exception
      def initialize(association_name : String)
        super("Cannot delete record because of dependent #{association_name}")
      end
    end
  end

  class RecordNotDestroyed < ::Exception
    getter model : Grant::Base

    def initialize(class_name : String, @model : Grant::Base)
      super("Could not destroy #{class_name}: #{model.errors.first.message}")
    end
  end

  # Raised when attempting to update or destroy a record (or column) that has
  # been marked read-only — either because the record was flagged with
  # `#readonly!` / loaded as part of a read-only relation, or because the column
  # was declared with `attr_readonly`.
  #
  # Mirrors ActiveRecord's `ActiveRecord::ReadOnlyRecord`.
  class ReadOnlyRecordError < ::Exception
    def initialize(message : String = "Record is marked as read only")
      super(message)
    end
  end
end
