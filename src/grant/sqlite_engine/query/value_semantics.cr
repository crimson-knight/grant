module Grant::SQLiteEngine::Query
  # What SQLite does with a value inside an expression: comparison
  # (sqlite3MemCompare), the affinity a comparison applies
  # (sqlite3CompareAffinity, applyNumericAffinity), arithmetic (OP_Add and
  # its siblings), CAST (sqlite3VdbeMemCast), truth values and conversion to
  # text, each ported from SQLite 3.51.0's vdbe.c, vdbemem.c and expr.c.
  module ValueSemantics
    # Expression affinity as SQLite orders it: no affinity, then BLOB, TEXT,
    # NUMERIC, INTEGER, REAL. Comparisons treat BLOB as "no conversion".
    # A real that no integer equals, as a hash key (see `equality_key`).
    record RealKey, bits : UInt64

    alias EqualityKey = Value | RealKey

    enum ExpressionAffinity
      None
      Blob
      Text
      Numeric
      Integer
      Real
      # SQLITE_AFF_FLEXNUM: a compound subquery column whose first operand
      # is a CAST to a numeric type; text becomes a number, reals stay reals.
      FlexNum

      def self.from(affinity : Affinity) : ExpressionAffinity
        case affinity
        in .blob?    then Blob
        in .text?    then Text
        in .numeric? then Numeric
        in .integer? then Integer
        in .real?    then Real
        end
      end

      def numeric? : Bool
        self >= Numeric
      end

      # True above SQLITE_AFF_NONE.
      def any? : Bool
        self != None
      end
    end

    # sqlite3CompareAffinity of two operand affinities: the affinity a
    # comparison applies to both operands.
    def self.comparison_affinity(left : ExpressionAffinity, right : ExpressionAffinity) : ExpressionAffinity
      if left.any? && right.any?
        return ExpressionAffinity::Numeric if left.numeric? || right.numeric?
        return ExpressionAffinity::Blob
      end
      left.any? ? left : right
    end

    # The value converted as a comparison with *affinity* converts its
    # operand (the OP_Lt family, before sqlite3MemCompare). *other_is_text*
    # is whether either operand is text, which gates the TEXT conversion.
    @[AlwaysInline]
    def self.prepare_for_comparison(value : Value, affinity : ExpressionAffinity, either_is_text : Bool) : Value
      if affinity.numeric?
        return comparison_numeric(value) if value.is_a?(String)
      elsif affinity.text? && either_is_text
        return text_of_number(value) if value.is_a?(Int64) || value.is_a?(Float64)
      end
      value
    end

    # applyNumericAffinity(pRec, 0): text that is entirely a number becomes
    # that number; anything else is left alone.
    def self.comparison_numeric(text : String) : Value
      parse = NumericText.ato_f(text)
      return text if parse.kind <= 0
      if parse.kind == 1
        if integer = also_an_integer(text, parse.value)
          return integer
        end
      end
      parse.value
    end

    # alsoAnInt.
    private def self.also_an_integer(text : String, real : Float64) : Int64?
      integer = NumericText.real_to_i64(real)
      return integer if NumericText.real_same_as_int?(real, integer)
      parse = NumericText.atoi64(text)
      parse.code == 0 ? parse.value : nil
    end

    # applyNumericAffinity(pRec, 1), used when a value is stored in or cast
    # through a NUMERIC/INTEGER/REAL column or applyAffinity.
    def self.numeric_affinity(text : String) : Value
      parse = NumericText.ato_f(text)
      return text if parse.kind <= 0
      if parse.kind == 1
        if integer = also_an_integer(text, parse.value)
          return integer
        end
      end
      integer_affinity(parse.value)
    end

    # sqlite3VdbeIntegerAffinity for a REAL: whole values that fit strictly
    # inside the Int64 range become integers.
    def self.integer_affinity(real : Float64) : Value
      integer = NumericText.real_to_i64(real)
      return integer if real == integer.to_f64 && integer > Int64::MIN && integer < Int64::MAX
      real
    end

    # applyAffinity(pRec, affinity): the conversion a value undergoes when
    # an affinity is applied to it outside a comparison (column storage, the
    # affinity of `IN` set entries, CAST-free type coercion).
    def self.apply_affinity(value : Value, affinity : ExpressionAffinity) : Value
      if affinity.numeric?
        case value
        when Int64   then value
        when Float64 then affinity <= ExpressionAffinity::Real ? integer_affinity(value) : value
        when String  then numeric_affinity(value)
        else              value
        end
      elsif affinity.text?
        value.is_a?(Int64) || value.is_a?(Float64) ? text_of_number(value) : value
      else
        value
      end
    end

    # OP_Affinity and OP_MakeRecord: apply_affinity, and under REAL an
    # integer that needs more than six bytes becomes a real, so an index
    # probe or IN key compares as the stored real does.
    def self.apply_record_affinity(value : Value, affinity : ExpressionAffinity) : Value
      converted = apply_affinity(value, affinity)
      if affinity.real? && converted.is_a?(Int64) && !SIX_BYTE_INTEGERS.includes?(converted)
        converted.to_f64
      else
        converted
      end
    end

    SIX_BYTE_INTEGERS = -140737488355328_i64..140737488355327_i64

    # sqlite3MemCompare: NULL first, then numbers (integers and reals
    # compared exactly), then text by *collation*, then blobs by bytes.
    def self.compare(left : Value, right : Value, collation : Collation = Collation::Binary) : Int32
      if left.nil?
        return right.nil? ? 0 : -1
      end
      return 1 if right.nil?
      case left
      when Int64
        case right
        when Int64   then left <=> right
        when Float64 then int_float_compare(left, right)
        else              -1
        end
      when Float64
        case right
        when Int64   then -int_float_compare(right, left)
        when Float64 then left < right ? -1 : (left > right ? 1 : 0)
        else              -1
        end
      when String
        case right
        when Int64, Float64 then 1
        when String         then collation.compare(left, right)
        else                     -1
        end
      else
        case right
        when Bytes then Collation.compare_binary(left, right)
        else            1
        end
      end
    end

    # sqlite3IntFloatCompare.
    def self.int_float_compare(integer : Int64, real : Float64) : Int32
      return 1 if real.nan?
      return 1 if real < -9223372036854775808.0
      return -1 if real >= 9223372036854775808.0
      truncated = real.to_i64!
      return -1 if integer < truncated
      return 1 if integer > truncated
      as_real = integer.to_f64
      as_real < real ? -1 : (as_real > real ? 1 : 0)
    end

    # sqlite3VdbeIntValue.
    def self.integer_value(value : Value) : Int64
      case value
      when Int64   then value
      when Float64 then NumericText.real_to_i64(value)
      when String  then NumericText.atoi64(value).value
      when Bytes   then NumericText.atoi64(value).value
      else              0_i64
      end
    end

    # sqlite3VdbeRealValue.
    def self.real_value(value : Value) : Float64
      case value
      when Float64 then value
      when Int64   then value.to_f64
      when String  then NumericText.ato_f(value).value
      when Bytes   then NumericText.ato_f(value).value
      else              0.0
      end
    end

    # computeNumericType for text and blobs: the integer or real the
    # arithmetic operators use.
    def self.numeric_value(value : Value) : Int64 | Float64
      case value
      when Int64, Float64 then value
      when String         then numeric_of_bytes(value.to_slice)
      when Bytes          then numeric_of_bytes(value)
      else                     0_i64
      end
    end

    private def self.numeric_of_bytes(bytes : Bytes) : Int64 | Float64
      parse = NumericText.ato_f(bytes)
      if parse.kind <= 0
        if parse.kind == 0
          integer = NumericText.atoi64(bytes)
          return integer.value if integer.code <= 1
        end
        return parse.value
      elsif parse.kind == 1
        integer = NumericText.atoi64(bytes)
        return integer.value if integer.code == 0
      end
      parse.value
    end

    # sqlite3VdbeBooleanValue: nil for NULL.
    def self.truth(value : Value) : Bool?
      case value
      when Nil   then nil
      when Int64 then value != 0
      else            real_value(value) != 0.0
      end
    end

    # The text of a number, as SQLite renders it.
    def self.text_of_number(value : Int64 | Float64) : String
      value.is_a?(Int64) ? value.to_s : NumericText.real_text(value)
    end

    # sqlite3_value_text: nil stays nil.
    def self.text(value : Value) : String?
      case value
      when String  then value
      when Int64   then value.to_s
      when Float64 then NumericText.real_text(value)
      when Bytes   then String.new(value)
      else              nil
      end
    end

    # sqlite3_value_blob: the bytes of a value.
    def self.blob(value : Value) : Bytes?
      case value
      when Bytes  then value
      when String then value.to_slice
      when Nil    then nil
      else             text_of_number(value).to_slice
      end
    end

    enum Arithmetic
      Add
      Subtract
      Multiply
      Divide
      Remainder
    end

    # OP_Add, OP_Subtract, OP_Multiply, OP_Divide, OP_Remainder:
    # `left op right`.
    def self.arithmetic(operator : Arithmetic, left : Value, right : Value) : Value
      return nil if left.nil? || right.nil?
      if left.is_a?(Int64) && right.is_a?(Int64)
        return integer_arithmetic(operator, left, right)
      end
      left_number = numeric_value(left)
      right_number = numeric_value(right)
      if left_number.is_a?(Int64) && right_number.is_a?(Int64)
        return integer_arithmetic(operator, left_number, right_number)
      end
      real_arithmetic(operator, left, right)
    end

    private def self.integer_arithmetic(operator : Arithmetic, left : Int64, right : Int64) : Value
      case operator
      in .add?
        result = left &+ right
        return real_arithmetic(operator, left, right) if ((left ^ result) & (right ^ result)) < 0
        result
      in .subtract?
        result = left &- right
        return real_arithmetic(operator, left, right) if ((left ^ right) & (left ^ result)) < 0
        result
      in .multiply?
        product = left.to_i128 * right.to_i128
        return real_arithmetic(operator, left, right) if product > Int64::MAX || product < Int64::MIN
        product.to_i64
      in .divide?
        return nil if right == 0
        return real_arithmetic(operator, left, right) if right == -1 && left == Int64::MIN
        left.tdiv(right)
      in .remainder?
        return nil if right == 0
        divisor = right == -1 ? 1_i64 : right
        left.remainder(divisor)
      end
    end

    private def self.real_arithmetic(operator : Arithmetic, left : Value, right : Value) : Value
      left_real = real_value(left)
      right_real = real_value(right)
      result = case operator
               in .add?      then left_real + right_real
               in .subtract? then left_real - right_real
               in .multiply? then left_real * right_real
               in .divide?
                 return nil if right_real == 0.0
                 left_real / right_real
               in .remainder?
                 divisor = integer_value(right)
                 return nil if divisor == 0
                 divisor = 1_i64 if divisor == -1
                 integer_value(left).remainder(divisor).to_f64
               end
      result.nan? ? nil : result
    end

    enum Bitwise
      And
      Or
      ShiftLeft
      ShiftRight
    end

    # OP_BitAnd, OP_BitOr, OP_ShiftLeft, OP_ShiftRight.
    def self.bitwise(operator : Bitwise, left : Value, right : Value) : Value
      return nil if left.nil? || right.nil?
      value = integer_value(left)
      amount = integer_value(right)
      case operator
      in .and? then value & amount
      in .or?  then value | amount
      in .shift_left?, .shift_right?
        return value if amount == 0
        left_shift = operator.shift_left?
        if amount < 0
          left_shift = !left_shift
          amount = amount > -64 ? -amount : 64_i64
        end
        if amount >= 64
          return value >= 0 || left_shift ? 0_i64 : -1_i64
        end
        bits = value.to_u64!
        if left_shift
          bits = bits << amount
        else
          bits = bits >> amount
          bits |= UInt64::MAX << (64 - amount) if value < 0
        end
        bits.to_i64!
      end
    end

    # The four CAST targets plus TEXT.
    enum CastTarget
      Blob
      Text
      Numeric
      Integer
      Real

      # sqlite3AffinityType: the affinity of a declared type name.
      def self.for_type(type_name : String) : CastTarget
        case Affinity.from_declared_type(type_name)
        in .integer? then Integer
        in .text?    then Text
        in .blob?    then Blob
        in .real?    then Real
        in .numeric? then Numeric
        end
      end
    end

    # sqlite3VdbeMemCast.
    def self.cast(value : Value, target : CastTarget) : Value
      return nil if value.nil?
      case target
      in .blob?
        value.is_a?(Bytes) ? value : (blob(value) || Bytes.empty).dup
      in .text?
        text(value)
      in .integer?
        integer_value(value)
      in .real?
        real_value(value)
      in .numeric?
        numerify(value)
      end
    end

    # sqlite3VdbeMemNumerify.
    def self.numerify(value : Value) : Value
      case value
      when String then numerify_bytes(value.to_slice)
      when Bytes  then numerify_bytes(value)
      else             value
      end
    end

    private def self.numerify_bytes(bytes : Bytes) : Value
      parse = NumericText.ato_f(bytes)
      if parse.kind == 0 || parse.kind == 1
        integer = NumericText.atoi64(bytes)
        return integer.value if integer.code <= 1
      end
      rounded = NumericText.real_to_i64(parse.value)
      return rounded if NumericText.real_same_as_int?(parse.value, rounded)
      parse.value
    end

    # The storage class name `typeof()` reports.
    def self.type_name(value : Value) : String
      case value
      when Nil     then "null"
      when Int64   then "integer"
      when Float64 then "real"
      when String  then "text"
      else              "blob"
      end
    end

    # A key equal for two values exactly when sqlite3MemCompare with
    # *collation* returns 0 (NULL equal to NULL), for hashing. A whole real
    # inside the Int64 range becomes that integer; a real outside it becomes
    # a RealKey, since Crystal's == takes Int64::MAX and 2.0**63 as equal
    # where SQLite does not.
    def self.equality_key(value : Value, collation : Collation) : EqualityKey
      case value
      when Float64
        integer = value.to_i64! if value.finite? && value >= -9223372036854775808.0 && value < 9223372036854775808.0
        return integer if integer && integer.to_f64 == value && value.trunc == value
        return RealKey.new(value.unsafe_as(UInt64)) if value.abs >= 9007199254740992.0
        value == 0.0 ? 0_i64 : value
      when String
        collation.binary? ? value : collation.equality_key(value)
      else
        value
      end
    end
  end
end
