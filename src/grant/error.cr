class Grant::Error
  property field, message

  # A machine-readable error code (e.g. `:blank`, `:too_short`, `:taken`)
  # alongside the human-readable `message`. Mirrors the symbol keys used in
  # ActiveRecord's `errors.details`. `nil` for errors added without a code.
  property type : Symbol?

  def initialize(@field : (String | Symbol | JSON::Any), @message : String? = "", @type : Symbol? = nil)
  end

  def to_json(builder : JSON::Builder)
    builder.object do
      builder.field "field", @field
      builder.field "message", @message
    end
  end

  def to_s(io)
    if field == :base
      io << message
    else
      io << field.to_s.capitalize << " " << message
    end
  end
end

class Grant::ConversionError < Grant::Error
end
