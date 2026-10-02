require "json"

# One validation failure: which attribute failed, a machine-readable `type`
# (`:blank`, `:too_short`, `:taken`...), the `options` the failure carries
# (`count:`, `value:`), and a message.
#
# The message is built lazily. An error created with a type and no message
# (`errors.add(:name, :too_short, count: 3)`), with a Symbol message, or with
# a `Proc` message formats its text the first time `#message` is read and
# keeps it, so a failed validation on a hot path such as a bulk import pays for
# no string formatting until someone asks for one. A plain `String` message is
# used as given.
#
# ```
# error = Grant::Error.new(:first_name, :too_short, options: {:count => 3.as(Grant::Error::Value)})
# error.type         # => :too_short
# error.message      # => "is too short (minimum is 3 characters)"
# error.full_message # => "First name is too short (minimum is 3 characters)"
# error.detail       # => {:error => :too_short, :count => 3}
# ```
class Grant::Error
  # The values an error's options can carry. Anything else given to
  # `Grant::Error.value` is stored as its `to_s`.
  alias Value = (Bool | Int32 | Int64 | Float64 | String | Symbol | Array(String) | Range(Int32, Int32) | Range(Int64, Int64))?

  # The options of an error: the data a message template interpolates and
  # `errors.details` reports.
  alias Options = Hash(Symbol, Value)

  # A message computed from the record and the error's options, for
  # `message: ->(record : Post, data : Grant::Error::Options) { "..." }`.
  alias MessageProc = Proc(Grant::Base, Options, String)

  # What an error's message may be: text, a Symbol naming a translation key, a
  # `MessageProc`, or nothing (generate it from the error's type).
  alias Message = String | Symbol | MessageProc?

  # Converts *value* to something an error can carry.
  def self.value(value : Bool | String | Symbol?) : Value
    value
  end

  # :ditto:
  def self.value(value : Int32) : Value
    value
  end

  # :ditto:
  def self.value(value : Int64) : Value
    value
  end

  # :ditto:
  def self.value(value : Float64) : Value
    value
  end

  # :ditto:
  def self.value(value : Int) : Value
    value.to_i64
  end

  # :ditto:
  def self.value(value : Float) : Value
    value.to_f64
  end

  # :ditto:
  def self.value(value : Range(Int32, Int32) | Range(Int64, Int64)) : Value
    value
  end

  # :ditto:
  def self.value(value : Array(String)) : Value
    value
  end

  # :ditto:
  def self.value(value : Array) : Value
    value.map(&.to_s)
  end

  # :ditto:
  def self.value(value) : Value
    value.to_s
  end

  # Builds an `Options` hash from a NamedTuple, or nil when it is empty.
  def self.options_from(tuple : NamedTuple) : Options?
    return if tuple.size == 0
    result = Options.new
    tuple.each { |key, item| result[key] = value(item) }
    result
  end

  # Adapts a message Proc that takes a specific model class to the
  # `Grant::Base`-typed `MessageProc` an error stores.
  def self.wrap_message(message : String | Symbol?) : Message
    message
  end

  # :ditto:
  def self.wrap_message(message : Proc(T, Options, String)) : Message forall T
    ->(base : Grant::Base, data : Options) { message.call(base.as(T), data) }
  end

  # The attribute the error is on, as it was given (`:base` for errors on the
  # record as a whole).
  getter field : String | Symbol | JSON::Any

  # A machine-readable error code (e.g. `:blank`, `:too_short`, `:taken`)
  # alongside the human-readable `message`. Mirrors the symbol keys used in
  # ActiveRecord's `errors.details`. `nil` for errors added without a code.
  property type : Symbol?

  # The record the error was added to, used to find the model's translations
  # and the `MessageProc` argument. Set by `Grant::Errors`.
  property base : Grant::Base?

  @raw_message : Message
  @message : String?
  @full_message : String?
  @attribute : String?
  @options : Options?

  def initialize(@field : (String | Symbol | JSON::Any), message : String? = "", @type : Symbol? = nil)
    @raw_message = message
  end

  # Builds an error from a type: the message is generated from the type (and
  # the model's translations) when it is first read, unless *message* is given.
  def initialize(@field : (String | Symbol | JSON::Any), @type : Symbol, *, message : Message = nil, options : Options? = nil, base : Grant::Base? = nil)
    @raw_message = message || @type
    @options = options
    @base = base
  end

  # Builds an error with an explicit message (a String, a Symbol translation
  # key, a Proc or nil to generate it) and a possibly absent type.
  def initialize(@field : (String | Symbol | JSON::Any), message : Message, @type : Symbol?, *, options : Options?, base : Grant::Base?)
    @raw_message = message.nil? ? @type : message
    @options = options
    @base = base
  end

  def field=(field : (String | Symbol | JSON::Any))
    @field = field
    @attribute = nil
    @full_message = nil
  end

  # The attribute name as a String (`"base"` for errors on the record).
  def attribute : String
    @attribute ||= @field.to_s
  end

  # The original type of the error, before any message override.
  def raw_type : Symbol?
    @type
  end

  # The data the error carries (`count:`, `value:`...). Allocated on first
  # use. Treat the hash as read-only: validators can share one instance among
  # every error they raise.
  def options : Options
    @options ||= Options.new
  end

  # True when the error carries any options.
  def options? : Bool
    options = @options
    !options.nil? && !options.empty?
  end

  def message=(message : String?)
    @raw_message = message
    @message = nil
    @full_message = nil
  end

  # The error message, generated on first read for an error without literal
  # text and kept afterwards.
  def message : String?
    raw = @raw_message
    return raw if raw.is_a?(String)
    return if raw.nil?
    cached = @message
    return cached if cached
    @message = generate(raw)
  end

  # The message prefixed with the humanized attribute name, formatted through
  # the `errors.format` translation (`"%{attribute} %{message}"`). Errors on
  # `:base` return the message alone.
  #
  # ```
  # Grant::Error.new(:first_name, "can't be blank").full_message # => "First name can't be blank"
  # ```
  def full_message : String
    @full_message ||= begin
      text = message || ""
      if attribute == "base"
        text
      else
        Grant::I18n.full_message(human_attribute_name, text)
      end
    end
  end

  # The humanized attribute name: the model's `human_attribute_name` when the
  # error knows its record, otherwise the default humanization.
  def human_attribute_name : String
    base = @base
    if base
      base.class.human_attribute_name(attribute)
    else
      Grant::I18n.humanize(attribute)
    end
  end

  # The AR `errors.details` entry: the type plus the options.
  #
  # ```
  # error.detail # => {:error => :too_short, :count => 3}
  # ```
  def detail : Options
    result = Options.new
    result[:error] = @type || :invalid
    @options.try &.each { |key, value| result[key] = value }
    result
  end

  # True when the error is on *attribute* and, when given, has the type *type*
  # (a Symbol) or the message *type* (a String), and carries every one of
  # *options*.
  #
  # ```
  # error.match?(:name)                       # any error on name
  # error.match?(:name, :too_short)           # by type
  # error.match?(:name, :too_short, count: 3) # by type and options
  # ```
  def match?(attribute : String | Symbol, type : Symbol | String? = nil, **options) : Bool
    return false unless self.attribute == attribute.to_s
    return false unless type.nil? || type_matches?(type)
    return true if options.size == 0
    mine = @options
    return false unless mine
    options.each do |key, value|
      return false unless mine.has_key?(key) && mine[key] == Error.value(value)
    end
    true
  end

  # Like `match?`, but the error's options must be exactly *options*.
  def strict_match?(attribute : String | Symbol, type : Symbol | String, **options) : Bool
    return false unless self.attribute == attribute.to_s
    return false unless type_matches?(type)
    mine = @options
    return options.size == 0 if mine.nil? || mine.empty?
    return false unless mine.size == options.size
    options.each do |key, value|
      return false unless mine.has_key?(key) && mine[key] == Error.value(value)
    end
    true
  end

  # A copy that does not share state with this error, optionally moved to
  # another attribute. The options hash is duplicated; the message is
  # resolved on the copy, not carried over.
  def copy(attribute : String | Symbol? = nil) : Error
    copy = Error.new(attribute || @field, @raw_message, @type, options: @options.try(&.dup), base: @base)
    copy
  end

  def to_json(builder : JSON::Builder)
    builder.object do
      builder.field "field", @field
      builder.field "message", message
    end
  end

  def to_s(io)
    io << full_message
  end

  private def type_matches?(type : Symbol | String) : Bool
    if type.is_a?(Symbol)
      @type == type
    else
      message == type
    end
  end

  private def generate(raw : Symbol | MessageProc) : String
    base = @base
    if raw.is_a?(Symbol)
      Grant::I18n.generate_message(base, attribute, raw, @options)
    elsif base
      raw.call(base, options)
    else
      raise ArgumentError.new("A Proc message needs the record: add the error through the record's errors collection")
    end
  end
end

class Grant::ConversionError < Grant::Error
end
