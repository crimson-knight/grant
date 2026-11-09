module Grant::PQ
  class ConnectionError < Exception
  end

  MAX_BIND_PARAMETER_COUNT = 65_535

  # Describes a Bind message whose parameter count exceeds PostgreSQL's limit.
  class TooManyParametersError < ConnectionError
    # Initializes the error with the supplied parameter count.
    #
    # *parameter_count* is the number of values supplied to a bound statement.
    #
    # ```
    # Grant::PQ::TooManyParametersError.new(65_536)
    # ```
    def initialize(parameter_count : Int32)
      super("PostgreSQL bind parameter limit is #{MAX_BIND_PARAMETER_COUNT}; got #{parameter_count}")
    end
  end

  class PQError < Exception
    getter fields : Array(Frame::ErrorResponse::Field)

    def initialize(@fields)
      super(field_message :message)
    end

    def field_message(name)
      field = fields.find { |f| f.name == name }
      field.message if field
    end
  end
end
