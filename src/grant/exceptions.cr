module Grant
  class RecordNotSaved < ::Exception
    getter model : Grant::Base

    def initialize(class_name : String, @model : Grant::Base)
      super("Could not process #{class_name}: #{model.errors.first.message}")
    end
  end

  class RecordNotDestroyed < ::Exception
    getter model : Grant::Base

    def initialize(class_name : String, @model : Grant::Base)
      super("Could not destroy #{class_name}: #{model.errors.first.message}")
    end
  end
end
