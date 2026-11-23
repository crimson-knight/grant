module Grant::SQLiteEngine
  # A stored SQLite value, by storage class: NULL, INTEGER, REAL, TEXT
  # (decoded to UTF-8) and BLOB.
  alias Value = Int64 | Float64 | String | Bytes?

  # Column affinity, from datatype3.html §3.
  enum Affinity
    Blob
    Text
    Numeric
    Integer
    Real

    # Returns the affinity of a declared column type, by the five rules of
    # datatype3.html §3.1, applied in order.
    def self.from_declared_type(declared_type : String) : Affinity
      upper = declared_type.upcase
      return Integer if upper.includes?("INT")
      return Text if upper.includes?("CHAR") || upper.includes?("CLOB") || upper.includes?("TEXT")
      return Blob if upper.includes?("BLOB") || upper.empty?
      return Real if upper.includes?("REAL") || upper.includes?("FLOA") || upper.includes?("DOUB")
      Numeric
    end

    # Converts a value as SQLite does when it stores it in a column of this
    # affinity (datatype3.html §3). Used for DEFAULT values of columns that a
    # record predates (ALTER TABLE ADD COLUMN).
    def apply(value : Value) : Value
      case self
      when Text
        return value.to_s if value.is_a?(Int64)
        return Affinity.real_to_text(value) if value.is_a?(Float64)
        value
      when Numeric, Integer
        Affinity.numeric_from(value)
      when Real
        converted = Affinity.numeric_from(value)
        converted.is_a?(Int64) ? converted.to_f64 : converted
      else
        value
      end
    end

    # SQLite renders a REAL as text with 15 significant digits, or as many
    # more as it takes to read back the same double, always with a decimal
    # point in the mantissa ("1.0e+20", "100.0").
    def self.real_to_text(value : Float64) : String
      return value > 0 ? "Inf" : "-Inf" if value.infinite?
      text = "%.15g" % value
      text = "%.16g" % value unless Affinity.parse_real_literal(text) == value
      text = "%.17g" % value unless Affinity.parse_real_literal(text) == value
      mantissa, separator, exponent = text.partition('e')
      mantissa = "#{mantissa}.0" unless mantissa.includes?('.')
      "#{mantissa}#{separator}#{exponent}"
    end

    protected def self.numeric_from(value : Value) : Value
      # sqlite3VdbeIntegerAffinity: a REAL that equals an INTEGER strictly
      # inside the Int64 range becomes that INTEGER.
      return StoredValue.whole_number(value) if value.is_a?(Float64)
      return value unless value.is_a?(String)
      trimmed = value.strip
      if integer = trimmed.to_i64?(whitespace: false, underscore: false, prefix: false, strict: true)
        return integer
      end
      if real = parse_real(trimmed)
        return numeric_from(real)
      end
      value
    end

    private def self.parse_real(text : String) : Float64?
      return if text.empty?
      return unless text.each_char.all? { |char| char.ascii_number? || char.in?('.', 'e', 'E', '+', '-') }
      Affinity.parse_real_literal(text)
    end

    # Parses a decimal real as SQLite does, where an exponent past the range
    # of a double gives infinity (or zero) instead of an error.
    def self.parse_real_literal(text : String) : Float64?
      if real = text.to_f64?(whitespace: false, strict: true)
        return real
      end
      match = text.match(/\A([+-]?)(\d+\.?\d*|\.\d+)[eE]([+-]?)\d+\z/)
      return unless match
      magnitude = match[3] == "-" ? 0.0 : Float64::INFINITY
      match[1] == "-" ? -magnitude : magnitude
    end
  end
end
