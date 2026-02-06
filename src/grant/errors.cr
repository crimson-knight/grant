require "./error"

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

  # Adds an error for the given field with the given message.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:base, "Record is invalid")
  # errors.add("email", "is already taken")
  # ```
  def add(field : (String | Symbol | JSON::Any), message : String? = "")
    @errors << Error.new(field, message)
  end

  # Appends an Error object to the collection.
  #
  # This maintains backward compatibility with the `errors << Error.new(...)` pattern.
  #
  # ```
  # errors << Grant::Error.new(:name, "can't be blank")
  # ```
  def <<(error : Error)
    @errors << error
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
    field_str = field.to_s
    @errors.select { |e| e.field.to_s == field_str }.compact_map(&.message)
  end

  # Returns an array of full error messages.
  #
  # Each message is formatted as "Field message" (e.g., "Name can't be blank").
  # For `:base` errors, only the message is returned without a field prefix.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:base, "Record is invalid")
  # errors.full_messages # => ["Name can't be blank", "Record is invalid"]
  # ```
  def full_messages : Array(String)
    @errors.map(&.to_s)
  end

  # Returns full error messages for a specific field.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:name, "is too short")
  # errors.full_messages_for(:name) # => ["Name can't be blank", "Name is too short"]
  # ```
  def full_messages_for(field : (String | Symbol)) : Array(String)
    field_str = field.to_s
    @errors.select { |e| e.field.to_s == field_str }.map(&.to_s)
  end

  # Returns all Error objects for a specific field.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:name, "is too short")
  # errors.where(:name).size # => 2
  # ```
  def where(field : (String | Symbol)) : Array(Error)
    field_str = field.to_s
    @errors.select { |e| e.field.to_s == field_str }
  end

  # Checks if an error with the given message exists for the field.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.of_type(:name, "can't be blank") # => true
  # errors.of_type(:name, "is too short")   # => false
  # ```
  def of_type(field : (String | Symbol), message : String) : Bool
    field_str = field.to_s
    @errors.any? { |e| e.field.to_s == field_str && e.message == message }
  end

  # Checks if a specific field has any errors.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.include?(:name)  # => true
  # errors.include?(:email) # => false
  # ```
  def include?(field : (String | Symbol)) : Bool
    field_str = field.to_s
    @errors.any? { |e| e.field.to_s == field_str }
  end

  # Returns unique field names that have errors.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:email, "is invalid")
  # errors.attribute_names # => ["name", "email"]
  # ```
  def attribute_names : Array(String)
    @errors.map { |e| e.field.to_s }.uniq
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
    @errors.each do |error|
      key = error.field.to_s
      result[key] ||= [] of Error
      result[key] << error
    end
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

  # Clears all errors.
  def clear
    @errors.clear
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

  # Returns a hash of field names to arrays of error messages.
  #
  # ```
  # errors.add(:name, "can't be blank")
  # errors.add(:name, "is too short")
  # errors.add(:email, "is invalid")
  # errors.to_hash # => {"name" => ["can't be blank", "is too short"], "email" => ["is invalid"]}
  # ```
  def to_hash : Hash(String, Array(String))
    result = {} of String => Array(String)
    @errors.each do |error|
      key = error.field.to_s
      result[key] ||= [] of String
      result[key] << (error.message || "")
    end
    result
  end

  # Serializes errors to JSON.
  #
  # ```
  # errors.to_json # => [{"field":"name","message":"can't be blank"}]
  # ```
  def to_json(builder : JSON::Builder)
    builder.array do
      @errors.each do |error|
        error.to_json(builder)
      end
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

  # Merge errors from another Errors collection into this one.
  #
  # ```
  # user.errors.merge!(other_record.errors)
  # ```
  def merge!(other : Errors)
    other.each { |error| @errors << error }
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
  def map(&block : Error -> U) : Array(U) forall U
    @errors.map { |e| yield e }
  end

  # Generate errors as JSON array.
  def to_json : String
    String.build do |str|
      builder = JSON::Builder.new(str)
      builder.document do
        to_json(builder)
      end
    end
  end
end
