require "./error"
require "./i18n"

# A rich errors collection that wraps model validation errors.
#
# `Grant::Errors` provides an ActiveRecord-compatible API for working
# with validation errors. It implements `Enumerable(Error)` and
# `Iterable(Error)` for backward compatibility with code that treats
# errors as an array.
#
# ```
# user = User.new
# user.valid?
#
# user.errors.any?          # => true
# user.errors[:name]        # => ["can't be blank"]
# user.errors.full_messages # => ["Name can't be blank"]
# user.errors.add(:base, "Something went wrong")
# ```
class Grant::Errors
  include Enumerable(Error)
  include Iterable(Error)

  @errors = [] of Error

  # Errors by attribute name, built the first time an attribute is looked up
  # and kept in step by `add`; every other mutation drops it.
  @index : Hash(String, Array(Error))?

  # The record the errors belong to. Errors added here remember it so their
  # messages can use the model's translations.
  property base : Grant::Base?

  def initialize(@base : Grant::Base? = nil)
  end

  # Adds an error for the given field with the given message.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:base, "Record is invalid")
  # errors.add("email", "is already taken")
  # errors.add(:age, "is too low", type: :greater_than, count: 18)
  # ```
  def add(field : (String | Symbol | JSON::Any), message : String? = "", type : Symbol? = nil, **options)
    error = Error.new(field, message, type, options: Error.options_from(options), base: @base)
    push(error)
    error
  end

  # Adds an error generated from a type. The message is built from the
  # model's translations when it is first read, interpolating *options*.
  #
  # ```
  # errors.add(:name, :too_short, count: 3)
  # errors[:name]                                         # => ["is too short (minimum is 3 characters)"]
  # errors.add(:name, :invalid, message: :must_be_unique) # message from a translation key
  # errors.add(:name, :invalid, message: ->(record : Grant::Base, data : Grant::Error::Options) { "..." })
  # ```
  def add(field : (String | Symbol | JSON::Any), type : Symbol, message : Error::Message = nil, **options)
    error = Error.new(field, type, message: message, options: Error.options_from(options), base: @base)
    push(error)
    error
  end

  # Appends an Error object to the collection.
  #
  # This maintains backward compatibility with the `errors << Error.new(...)` pattern.
  #
  # ```
  # errors << Grant::Error.new(:name, "can't be blank")
  # ```
  def <<(error : Error)
    push(error)
    self
  end

  # Returns an array of error messages for the given field.
  #
  # Returns an empty array if the field has no errors.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:name, "is too short")
  # errors[:name]  # => ["can't be blank", "is too short"]
  # errors[:email] # => [] of String
  # ```
  def [](field : (String | Symbol)) : Array(String)
    messages_for(field)
  end

  # Access error by index.
  #
  # ```
  # errors[0]         # => first Error object
  # errors[0].message # => "can't be blank"
  # ```
  def [](index : Int32) : Error
    @errors[index]
  end

  # The messages of the errors on *field* (`errors[:name]`).
  def messages_for(field : (String | Symbol)) : Array(String)
    list = by_attribute[field.to_s]?
    return [] of String unless list
    list.compact_map(&.message)
  end

  # Returns an array of full error messages.
  #
  # Each message is the humanized attribute name followed by the message
  # (e.g., "First name can't be blank"). For `:base` errors, only the message
  # is returned without a field prefix.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:base, "Record is invalid")
  # errors.full_messages # => ["Name can't be blank", "Record is invalid"]
  # ```
  def full_messages : Array(String)
    @errors.map(&.full_message)
  end

  # Returns full error messages for a specific field.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:name, "is too short")
  # errors.full_messages_for(:name) # => ["Name can't be blank", "Name is too short"]
  # ```
  def full_messages_for(field : (String | Symbol)) : Array(String)
    list = by_attribute[field.to_s]?
    return [] of String unless list
    list.map(&.full_message)
  end

  # Formats *message* as a full message for *field*, the way `full_messages`
  # does (`errors.full_message(:name, "is bad") # => "Name is bad"`).
  def full_message(field : (String | Symbol), message : String) : String
    return message if field.to_s == "base"
    base = @base
    human = base ? base.class.human_attribute_name(field) : Grant::I18n.humanize(field.to_s)
    Grant::I18n.full_message(human, message)
  end

  # Builds the message an error of *type* on *field* would have, without
  # adding it.
  #
  # ```
  # errors.generate_message(:name, :too_short, count: 3) # => "is too short (minimum is 3 characters)"
  # ```
  def generate_message(field : (String | Symbol), type : Symbol = :invalid, **options) : String
    Grant::I18n.generate_message(@base, field.to_s, type, Error.options_from(options))
  end

  # Returns the errors on *field* that match the optional *type* (a Symbol, or
  # a String message) and *options*.
  #
  # ```
  # errors.add(:name, :too_short, count: 3)
  # errors.where(:name).size                  # => 1
  # errors.where(:name, :too_short, count: 3) # => [Error]
  # errors.where(:name, :blank)               # => []
  # ```
  def where(field : (String | Symbol), type : Symbol | String? = nil, **options) : Array(Error)
    list = by_attribute[field.to_s]?
    return [] of Error unless list
    return list.dup if type.nil? && options.size == 0
    list.select(&.match?(field, type, **options))
  end

  # True when *field* has an error of *type* carrying all of *options*.
  #
  # ```
  # errors.add(:name, :too_short, count: 3)
  # errors.of_type(:name, :too_short)           # => true
  # errors.of_type(:name, :too_short, count: 3) # => true
  # errors.of_type(:name, :blank)               # => false
  # ```
  def of_type(field : (String | Symbol), type : Symbol, **options) : Bool
    list = by_attribute[field.to_s]?
    return false unless list
    list.any?(&.match?(field, type, **options))
  end

  # True when *field* has an error with exactly the message *message* (the
  # type of an error added with a plain String is that String).
  def of_type(field : (String | Symbol), message : String) : Bool
    has_message?(field, message)
  end

  # :ditto:
  def of_type?(field : (String | Symbol), type : Symbol, **options) : Bool
    of_type(field, type, **options)
  end

  # True when *field* has an error with exactly the message *message*.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.has_message?(:name, "can't be blank") # => true
  # ```
  def has_message?(field : (String | Symbol), message : String) : Bool
    list = by_attribute[field.to_s]?
    return false unless list
    list.any? { |error| error.message == message }
  end

  # True when the exact error was added: *field* has an error of *type* whose
  # options are exactly *options*. A String *type* matches by message.
  def added?(field : (String | Symbol), type : Symbol = :invalid, **options) : Bool
    list = by_attribute[field.to_s]?
    return false unless list
    list.any?(&.strict_match?(field, type, **options))
  end

  # :ditto:
  def added?(field : (String | Symbol), message : String) : Bool
    has_message?(field, message)
  end

  # Checks if a specific field has any errors.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.include?(:name)  # => true
  # errors.include?(:email) # => false
  # ```
  def include?(field : (String | Symbol)) : Bool
    by_attribute.has_key?(field.to_s)
  end

  # Removes the errors on *field* that match the optional *type* and
  # *options*, and returns their messages.
  #
  # ```
  # errors.delete(:name)             # removes every error on name
  # errors.delete(:name, :too_short) # removes one type
  # ```
  def delete(field : (String | Symbol), type : Symbol | String? = nil, **options) : Array(String)
    removed = where(field, type, **options)
    return [] of String if removed.empty?
    messages = removed.compact_map(&.message)
    @errors.reject! { |error| removed.any?(&.same?(error)) }
    @index = nil
    messages
  end

  # Returns unique field names that have errors.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:email, "is invalid")
  # errors.attribute_names # => ["name", "email"]
  # ```
  def attribute_names : Array(String)
    by_attribute.keys
  end

  # Returns error details grouped by field name.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:name, "is too short")
  # errors.group_by_attribute # => {"name" => [Error(...), Error(...)]}
  # ```
  def group_by_attribute : Hash(String, Array(Error))
    result = {} of String => Array(Error)
    by_attribute.each { |key, list| result[key] = list.dup }
    result
  end

  # Yields each error to the block.
  #
  # Implements `Enumerable(Error)` for backward compatibility with
  # code that iterates over the errors array.
  def each(&)
    @errors.each { |error| yield error }
  end

  # Returns an iterator over the errors.
  #
  # Implements `Iterable(Error)`.
  def each : Iterator(Error)
    @errors.each
  end

  # The error objects, in the order they were added. This is the collection's
  # own array, not a copy: read it, do not mutate it (use `delete`, `clear`
  # or `uniq!`).
  def objects : Array(Error)
    @errors
  end

  # Returns true if there are any errors.
  def any? : Bool
    !@errors.empty?
  end

  # Returns true if any errors match the given pattern (using `===`).
  #
  # This supports the existing pattern `errors.any? ConversionError`
  # which uses Crystal's `===` matching (class case equality).
  #
  # ```
  # errors.any? Grant::ConversionError # => true/false
  # ```
  def any?(pattern) : Bool
    @errors.any?(pattern)
  end

  # Returns true if there are no errors.
  def empty? : Bool
    @errors.empty?
  end

  # Returns the number of errors.
  def size : Int32
    @errors.size
  end

  # Alias for `#size`.
  def count : Int32
    @errors.size
  end

  # The number of errors on *field*.
  def count(field : (String | Symbol)) : Int32
    by_attribute[field.to_s]?.try(&.size) || 0
  end

  # Returns the first error in the collection.
  #
  # Raises `Enumerable::EmptyError` if there are no errors.
  def first : Error
    @errors.first
  end

  # Returns the first error, or nil if there are no errors.
  def first? : Error?
    @errors.first?
  end

  # Returns the last error in the collection.
  def last : Error
    @errors.last
  end

  # Returns the last error, or nil if there are no errors.
  def last? : Error?
    @errors.last?
  end

  # Drops the errors added after the collection had *size* errors. A
  # validator that raises (`strict:`) uses it to leave nothing behind.
  #
  # :nodoc:
  def truncate_to(size : Int32) : Nil
    return if size >= @errors.size
    @errors.pop(@errors.size - size)
    @index = nil
  end

  # Clears all errors.
  def clear
    @errors.clear
    @index = nil
  end

  # Removes duplicate errors: the same attribute, type, options and message.
  # Keeps the first of each.
  def uniq! : self
    seen = Set(String).new
    kept = @errors.select do |error|
      seen.add?("#{error.attribute}\0#{error.type}\0#{error.message}\0#{error.options? ? error.options.inspect : ""}")
    end
    if kept.size != @errors.size
      @errors = kept
      @index = nil
    end
    self
  end

  # Returns a hash of field names to arrays of error messages. With
  # `full_messages: true` the messages are the full messages
  # (`"Name can't be blank"`).
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:name, "is too short")
  # errors.add(:email, "is invalid")
  # errors.to_hash                      # => {"name" => ["can't be blank", "is too short"], "email" => ["is invalid"]}
  # errors.to_hash(full_messages: true) # => {"name" => ["Name can't be blank", ...], ...}
  # ```
  def to_hash(full_messages : Bool = false) : Hash(String, Array(String))
    result = {} of String => Array(String)
    @errors.each do |error|
      key = error.attribute
      (result[key] ||= [] of String) << (full_messages ? error.full_message : (error.message || ""))
    end
    result
  end

  # The messages by attribute (`to_hash`).
  def messages : Hash(String, Array(String))
    to_hash
  end

  # The shape ActiveRecord serializes: `{"name" => ["can't be blank"]}`;
  # `full_messages: true` for the full messages.
  def as_json(full_messages : Bool = false) : Hash(String, Array(String))
    to_hash(full_messages)
  end

  # Returns machine-readable error details grouped by field name.
  #
  # Each field maps to an array of detail hashes. Every detail hash carries an
  # `:error` key holding the error's type code (e.g. `:blank`, `:too_short`,
  # `:taken`) and the options the error carries (`count:`, `value:`). Errors
  # added without an explicit type fall back to `:invalid`. This mirrors
  # ActiveRecord's `errors.details` and lets clients branch on a stable code
  # rather than parsing the human-readable message. The hashes are built when
  # asked for.
  #
  # ```
  # errors.add(:name, :too_short, count: 3)
  # errors.details # => {"name" => [{:error => :too_short, :count => 3}]}
  # ```
  def details : Hash(String, Array(Error::Options))
    result = {} of String => Array(Error::Options)
    @errors.each do |error|
      (result[error.attribute] ||= [] of Error::Options) << error.detail
    end
    result
  end

  # The details of the errors on *field*, looked up by Symbol or String.
  # `details` keys are Strings (an attribute name can arrive at run time, and
  # Crystal cannot create a Symbol from a String), so this is the way to ask
  # with the Symbol the model declares: `errors.details_for(:name)`.
  def details_for(field : (String | Symbol)) : Array(Error::Options)
    list = by_attribute[field.to_s]?
    return [] of Error::Options unless list
    list.map(&.detail)
  end

  # Serializes errors to JSON in ActiveRecord's shape: attribute names mapped to
  # their messages.
  #
  # ```
  # errors.to_json # => {"name":["can't be blank"]}
  # ```
  #
  # `to_json_list` keeps the older `[{"field":..., "message":...}]` shape.
  def to_json(builder : JSON::Builder)
    as_json.to_json(builder)
  end

  # The errors as a JSON array of `{"field", "message"}` objects, the shape
  # `to_json` produced before it followed ActiveRecord.
  def to_json_list(builder : JSON::Builder) : Nil
    builder.array do
      @errors.each do |error|
        error.to_json(builder)
      end
    end
  end

  # :ditto:
  def to_json_list : String
    String.build do |str|
      builder = JSON::Builder.new(str)
      builder.document { to_json_list(builder) }
    end
  end

  # Returns a string representation of all errors.
  def to_s(io : IO)
    io << full_messages.join(", ")
  end

  # Returns a string representation for inspection.
  def inspect(io : IO)
    io << "#<Grant::Errors"
    io << " count=" << size
    io << " messages=" << to_hash.inspect
    io << ">"
  end

  # Adds a copy of *error*, optionally moved to another *attribute*, so the
  # two collections do not share error objects.
  def import(error : Error, attribute : (String | Symbol)? = nil) : Error
    copy = error.copy(attribute)
    copy.base ||= @base
    push(copy)
    copy
  end

  # Merge errors from another Errors collection into this one, as copies.
  #
  # ```
  # user.errors.merge!(other_record.errors)
  # ```
  def merge!(other : Errors)
    other.to_a.each { |error| import(error) }
  end

  # Replaces this collection's errors with copies of *other*'s.
  def copy!(other : Errors) : self
    copies = other.to_a.map(&.copy)
    clear
    copies.each { |error| import(error) }
    self
  end

  # Returns a copy of the internal errors array.
  #
  # Useful for backward compatibility where an Array(Error) is expected.
  def to_a : Array(Error)
    @errors.dup
  end

  # Delegate `map` explicitly for backward compatibility.
  #
  # Since we include `Enumerable(Error)`, `map` is inherited,
  # but we override it to ensure it returns `Array(U)` properly.
  def map(& : Error -> U) : Array(U) forall U
    @errors.map { |e| yield e }
  end

  # Generate errors as a JSON object (see `to_json(builder)`).
  def to_json : String
    String.build do |str|
      builder = JSON::Builder.new(str)
      builder.document do
        to_json(builder)
      end
    end
  end

  private def push(error : Error) : Nil
    error.base ||= @base
    @errors << error
    @index.try do |index|
      (index[error.attribute] ||= [] of Error) << error
    end
  end

  private def by_attribute : Hash(String, Array(Error))
    @index ||= begin
      index = {} of String => Array(Error)
      @errors.each { |error| (index[error.attribute] ||= [] of Error) << error }
      index
    end
  end
end
