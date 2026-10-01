require "json"
require "uuid"
require "uuid/yaml"

module Grant::Type
  extend self

  # :nodoc:
  PRIMITIVES = {
    Int8    => ".read",
    Int16   => ".read",
    Int32   => ".read",
    Int64   => ".read",
    UInt8   => ".read",
    UInt16  => ".read",
    UInt32  => ".read",
    UInt64  => ".read",
    Float32 => ".read",
    Float64 => ".read",
    Bool    => ".read",
    String  => ".read",
  }

  # :nodoc:
  NUMERIC_TYPES = {
    Int8    => ".to_i8",
    Int16   => ".to_i16",
    Int32   => ".to_i",
    Int64   => ".to_i64",
    UInt8   => ".to_u8",
    UInt16  => ".to_u16",
    UInt32  => ".to_u32",
    UInt64  => ".to_u64",
    Float32 => ".to_f32",
    Float64 => ".to_f",
  }

  {% for type, method in PRIMITIVES %}
    # Converts a `DB::ResultSet` to `{{type}}`.
    def from_rs(result : DB::ResultSet, t : {{type}}.class) : {{type}}
      result{{method.id}} {{type}}
    end

    # Converts a `DB::ResultSet` to `{{type}}?`.
    def from_rs(result : DB::ResultSet, t : {{type}}?.class) : {{type}}?
      result{{method.id}} {{type}}?
    end

    # Converts an `DB::ResultSet` to `Array({{type}})`.
    def from_rs(result : DB::ResultSet, t : Array({{type}}).class) : Array({{type}})
      result{{method.id}} Array({{type}})
    end

    # Converts an `DB::ResultSet` to `Array({{type}})?`.
    def from_rs(result : DB::ResultSet, t : Array({{type}})?.class) : Array({{type}})?
      result{{method.id}} Array({{type}})?
    end
  {% end %}

  # Converts a `DB::ResultSet` to `Time`.
  def from_rs(result : DB::ResultSet, t : Time.class) : Time
    result.read(Time).in(Grant.settings.default_timezone)
  end

  # Converts a `DB::ResultSet` to `Time?`
  def from_rs(result : DB::ResultSet, t : Time?.class) : Time?
    result.read(Time?).try &.in(Grant.settings.default_timezone)
  end

  # Converts a `DB::ResultSet` to `Array(Time)` (PostgreSQL `timestamp[]`).
  def from_rs(result : DB::ResultSet, t : Array(Time).class) : Array(Time)
    zone = Grant.settings.default_timezone
    result.read(Array(Time)).map(&.in(zone))
  end

  # Converts a `DB::ResultSet` to `Array(Time)?`.
  def from_rs(result : DB::ResultSet, t : Array(Time)?.class) : Array(Time)?
    zone = Grant.settings.default_timezone
    result.read(Array(Time)?).try(&.map(&.in(zone)))
  end

  def from_rs(result : DB::ResultSet, t : Time.class, adapter : Grant::Adapter::Base) : Time
    adapter.read_time(result).in(Grant.settings.default_timezone)
  end

  def from_rs(result : DB::ResultSet, t : Time?.class, adapter : Grant::Adapter::Base) : Time?
    adapter.read_nullable_time(result).try &.in(Grant.settings.default_timezone)
  end

  def from_rs(result : DB::ResultSet, t : T.class, adapter : Grant::Adapter::Base) : T forall T
    from_rs(result, t)
  end

  def from_rs(result : DB::ResultSet, t : T?.class, adapter : Grant::Adapter::Base) : T? forall T
    from_rs(result, t)
  end

  # Converts a `DB::ResultSet` to `UUID`.
  def from_rs(result : DB::ResultSet, t : UUID.class) : UUID
    value = result.read(UUID | String | Bytes)
    case value
    when UUID
      value
    when String
      UUID.new(value)
    when Bytes
      UUID.new(value)
    else
      raise "Cannot convert #{value.class} to UUID"
    end
  end

  # Converts a `DB::ResultSet` to `UUID?`.
  def from_rs(result : DB::ResultSet, t : UUID?.class) : UUID?
    value = result.read(UUID? | String? | Bytes?)
    return nil if value.nil?

    case value
    when UUID
      value
    when String
      UUID.new(value)
    when Bytes
      UUID.new(value)
    else
      raise "Cannot convert #{value.class} to UUID"
    end
  end

  # Converts an `DB::ResultSet` to `Array(UUID)`.
  def from_rs(result : DB::ResultSet, t : Array(UUID).class) : Array(UUID)
    result.read(Array(::UUID))
  end

  # Converts an `DB::ResultSet` to `Array(UUID)?`.
  def from_rs(result : DB::ResultSet, t : Array(UUID)?.class) : Array(UUID)?
    result.read(Array(::UUID)?)
  end

  {% for type, method in NUMERIC_TYPES %}
    # Converts a `String` to `{{type}}`.
    def convert_type(value : String, t : {{type.id}}.class) : {{type.id}}
      value{{method.id}}
    end

    # Converts a `String` to `{{type}}?`.
    def convert_type(value : String, t : {{type.id}}?.class) : {{type.id}}?
      value{{method.id}}
    end
  {% end %}

  # Converts Rails-style enum symbols in mass-assignment payloads to the
  # corresponding native Crystal enum member.
  def convert_type(value : Symbol, type : T.class) : T forall T
    {% if T < Enum %}
      T.values.find { |candidate| candidate.to_s.underscore == value.to_s } ||
        raise ArgumentError.new("Unknown #{T} value #{value.inspect}")
    {% else %}
      raise ArgumentError.new("Cannot convert #{value.inspect} to #{T}")
    {% end %}
  end

  # Nilable enum columns accept the same symbolic member names as non-nilable
  # enum columns.
  def convert_type(value : Symbol, type : T?.class) : T? forall T
    {% if T < Enum %}
      T.values.find { |candidate| candidate.to_s.underscore == value.to_s } ||
        raise ArgumentError.new("Unknown #{T} value #{value.inspect}")
    {% else %}
      raise ArgumentError.new("Cannot convert #{value.inspect} to #{T}?")
    {% end %}
  end

  def convert_type(value, type)
    value
  end

  def convert_type(value, type : Bool?.class) : Bool
    ["1", "yes", "true", true, 1].includes?(value)
  end

  # Converts a value to UUID
  def convert_type(value : String, type : UUID.class) : UUID
    UUID.new(value)
  end

  # Converts a value to UUID?
  def convert_type(value : String, type : UUID?.class) : UUID?
    UUID.new(value)
  end

  def convert_type(value : Nil, type : UUID?.class) : UUID?
    nil
  end

  # Converts a JSON text to a `JSON::Any` document. Text that is not valid
  # JSON raises `ArgumentError`, which mass assignment reports as a
  # conversion error on the attribute.
  def convert_type(value : String, type : JSON::Any.class) : JSON::Any
    JSON.parse(value)
  rescue ex : JSON::ParseException
    raise ArgumentError.new("Invalid JSON: #{ex.message}")
  end

  # :ditto:
  def convert_type(value : String, type : JSON::Any?.class) : JSON::Any?
    convert_type(value, JSON::Any)
  end
end
