module Grant::SQLiteEngine::Query
  # SQLite's built-in scalar functions (lang_corefunc.html), each ported
  # from func.c of SQLite 3.51.0. coalesce, ifnull, iif and the likely
  # family evaluate their arguments lazily, so the compiler builds them as
  # expressions (`expressions.cr`) instead.
  module ScalarFunctions
    # What a call can see beyond its arguments: the collation the call
    # resolved to (min, max and nullif compare with it) and the connection.
    record CallContext, collation : Collation, session : Session, list_of_subtypes : Array(UInt8)? = nil

    alias Implementation = Proc(Array(Value), CallContext, Value)

    # One function, for one range of argument counts (`maximum` -1 for any).
    record Definition, name : String, minimum : Int32, maximum : Int32, implementation : Implementation,
      needs_collation : Bool = false, reads_subtypes : Bool = false

    HEX_DIGITS = "0123456789ABCDEF"

    # The definition of *name* taking *count* arguments: nil when SQLite has
    # no function of that name, raising when the name exists with other
    # counts.
    def self.lookup(name : String, count : Int32) : Definition?
      list = DEFINITIONS[name.downcase]?
      return unless list
      found = list.find { |definition| count >= definition.minimum && (definition.maximum < 0 || count <= definition.maximum) }
      raise SQLError.new("wrong number of arguments to function #{name}()") unless found
      found
    end

    def self.known?(name : String) : Bool
      DEFINITIONS.has_key?(name.downcase)
    end

    private def self.text(value : Value) : String?
      ValueSemantics.text(value)
    end

    # The text of a value up to its first zero byte, as C string functions
    # see it.
    private def self.c_text(value : Value) : String?
      result = text(value)
      return unless result
      cut = result.byte_index(0_u8)
      cut ? result.byte_slice(0, cut) : result
    end

    # sqlite3_value_bytes: the size of the value as text (or blob).
    private def self.byte_size(value : Value) : Int32
      case value
      when Bytes  then value.size
      when String then value.bytesize
      when Nil    then 0
      else             ValueSemantics.text_of_number(value).bytesize
      end
    end

    private def self.character_count(bytes : Bytes) : Int32
      count = 0
      index = 0
      while index < bytes.size
        byte = bytes.unsafe_fetch(index)
        break if byte == 0
        index += 1
        if byte >= 0xc0
          while index < bytes.size && bytes.unsafe_fetch(index) & 0xc0 == 0x80
            index += 1
          end
        end
        count += 1
      end
      count
    end

    # SQLITE_SKIP_UTF8 from *index*.
    private def self.skip_character(bytes : Bytes, index : Int32) : Int32
      byte = bytes.unsafe_fetch(index)
      index += 1
      if byte >= 0xc0
        while index < bytes.size && bytes.unsafe_fetch(index) & 0xc0 == 0x80
          index += 1
        end
      end
      index
    end

    def self.substr(arguments : Array(Value)) : Value
      subject = arguments[0]
      start_value = arguments[1]
      start = ValueSemantics.integer_value(start_value)
      blob = subject.as?(Bytes)
      # sqlite3_value_blob returns a null pointer for an empty blob.
      return if blob && blob.empty?
      bytes = blob
      length = 0_i64
      unless bytes
        subject_text = c_text(subject)
        return unless subject_text
        bytes = subject_text.to_slice
        length = character_count(bytes).to_i64 if start < 0
      end
      length = bytes.size.to_i64 if blob
      if arguments.size == 3
        count = ValueSemantics.integer_value(arguments[2])
        return if count == 0 && arguments[2].nil?
      else
        count = Limits::MAX_VALUE_BYTES.to_i64
      end
      if start == 0
        return if start_value.nil?
      end
      if start < 0
        start += length
        if start < 0
          count = count < 0 ? 0_i64 : count + start
          start = 0_i64
        end
      elsif start > 0
        start -= 1
      elsif count > 0
        count -= 1
      end
      if count < 0
        if count < -start
          count = start
        else
          count = -count
        end
        start -= count
      end
      if blob
        if start >= length
          start = count = 0_i64
        elsif count > length - start
          count = length - start
        end
        return blob[start.to_i32, count.to_i32].dup
      end
      position = 0
      while position < bytes.size && start > 0
        position = skip_character(bytes, position)
        start -= 1
      end
      finish = position
      while finish < bytes.size && count > 0
        finish = skip_character(bytes, finish)
        count -= 1
      end
      String.new(bytes[position, finish - position])
    end

    def self.round(arguments : Array(Value)) : Value
      digits = 0_i64
      if arguments.size == 2
        return if arguments[1].nil?
        digits = ValueSemantics.integer_value(arguments[1]).clamp(0_i64, 30_i64)
      end
      return if arguments[0].nil?
      real = ValueSemantics.real_value(arguments[0])
      if real < -4503599627370496.0 || real > 4503599627370496.0
        real
      elsif digits == 0
        (real + (real < 0 ? -0.5 : 0.5)).to_i64!.to_f64
      else
        NumericText.ato_f(NumericText.format_float(real, NumericText::FloatFormat::Fixed, digits.to_i32, alternate_form_2: true)).value
      end
    end

    def self.abs(argument : Value) : Value
      case argument
      when Int64
        raise SQLError.new("integer overflow") if argument == Int64::MIN
        argument.abs
      when Nil
        nil
      else
        # absFunc: a negative real is negated, so -0.0 stays -0.0.
        real = ValueSemantics.real_value(argument)
        real < 0 ? -real : real
      end
    end

    def self.length(argument : Value) : Value
      case argument
      when Nil    then nil
      when String then character_count(argument.to_slice).to_i64
      else             byte_size(argument).to_i64
      end
    end

    def self.instr(haystack : Value, needle : Value) : Value
      return if haystack.nil? || needle.nil?
      if haystack.is_a?(Bytes) && needle.is_a?(Bytes)
        hay = haystack
        pin = needle
        is_text = false
      else
        hay = (text(haystack) || "").to_slice
        pin = (text(needle) || "").to_slice
        is_text = true
      end
      return 1_i64 if pin.empty?
      position = 1_i64
      offset = 0
      remaining = hay.size
      while pin.size <= remaining && hay[offset, pin.size] != pin
        position += 1
        loop do
          remaining -= 1
          offset += 1
          break unless is_text && offset < hay.size && hay[offset] & 0xc0 == 0x80
        end
      end
      pin.size > remaining ? 0_i64 : position
    end

    enum TrimSide
      Left  = 1
      Right = 2
      Both  = 3
    end

    def self.trim(arguments : Array(Value), side : TrimSide) : Value
      return if arguments[0].nil?
      input = text(arguments[0])
      return unless input
      if arguments.size == 1
        set = [" ".to_slice]
      else
        set_text = c_text(arguments[1])
        return unless set_text
        set = [] of Bytes
        set_bytes = set_text.to_slice
        index = 0
        while index < set_bytes.size
          finish = skip_character(set_bytes, index)
          set << set_bytes[index, finish - index]
          index = finish
        end
      end
      bytes = input.to_slice
      start = 0
      finish = bytes.size
      unless set.empty?
        if side.value & 1 != 0
          while finish > start
            match = set.find { |piece| piece.size <= finish - start && bytes[start, piece.size] == piece }
            break unless match
            start += match.size
          end
        end
        if side.value & 2 != 0
          while finish > start
            match = set.find { |piece| piece.size <= finish - start && bytes[finish - piece.size, piece.size] == piece }
            break unless match
            finish -= match.size
          end
        end
      end
      String.new(bytes[start, finish - start])
    end

    def self.replace(subject : Value, pattern : Value, replacement : Value) : Value
      subject_text = text(subject)
      return unless subject_text
      pattern_text = text(pattern)
      return unless pattern_text
      return subject_text if pattern_text.empty? || pattern_text.byte_at(0) == 0
      replacement_text = text(replacement)
      return unless replacement_text
      source = subject_text.to_slice
      needle = pattern_text.to_slice
      io = IO::Memory.new(source.size)
      index = 0
      last = source.size - needle.size
      while index <= last
        if source[index] == needle[0] && source[index, needle.size] == needle
          io.write(replacement_text.to_slice)
          index += needle.size
        else
          io.write_byte(source[index])
          index += 1
        end
      end
      io.write(source[index, source.size - index]) if index < source.size
      String.new(io.to_slice)
    end

    def self.hex(argument : Value) : Value
      bytes = ValueSemantics.blob(argument) || Bytes.empty
      String.build(bytes.size * 2) do |io|
        bytes.each do |byte|
          io << HEX_DIGITS[byte >> 4] << HEX_DIGITS[byte & 0xf]
        end
      end
    end

    # unhexFunc: the bytes the hex digit pairs of the first argument spell;
    # characters of the second argument may stand between pairs. NULL when
    # anything else appears or a pair is cut short.
    def self.unhex(arguments : Array(Value)) : Value
      digits = c_text(arguments[0])
      passed = arguments.size == 2 ? c_text(arguments[1]) : ""
      return if digits.nil? || passed.nil?
      list_of_bytes = [] of UInt8
      reader = Char::Reader.new(digits)
      while reader.has_next?
        high = reader.current_char
        reader.next_char
        unless high.hex?
          return unless passed.includes?(high)
          next
        end
        low = reader.has_next? ? reader.current_char : '\0'
        return unless low.hex?
        reader.next_char
        list_of_bytes << ((high.to_i(16) << 4) | low.to_i(16)).to_u8
      end
      Bytes.new(list_of_bytes.size) { |index| list_of_bytes[index] }
    end

    def self.quote(argument : Value) : Value
      case argument
      when Float64
        # quoteFunc's "%!0.15g" writes an infinity as 9.0e+999.
        return argument > 0 ? "9.0e+999" : "-9.0e+999" if argument.infinite?
        rendered = NumericText.format_float(argument, NumericText::FloatFormat::Generic, 15, alternate_form_2: true)
        if NumericText.ato_f(rendered).value != argument
          rendered = NumericText.format_float(argument, NumericText::FloatFormat::Exponential, 20, alternate_form_2: true)
        end
        rendered
      when Int64
        argument.to_s
      when Bytes
        "X'#{hex(argument)}'"
      when String
        # quoteFunc doubles each quote byte and copies every other byte as
        # it is (invalid UTF-8 included), stopping at a NUL.
        bytes = argument.to_slice
        cut = bytes.index(0_u8) || bytes.size
        String.build(cut + 2) do |io|
          io.write_byte(0x27_u8)
          bytes[0, cut].each do |byte|
            io.write_byte(byte)
            io.write_byte(byte) if byte == 0x27_u8
          end
          io.write_byte(0x27_u8)
        end
      else
        "NULL"
      end
    end

    def self.case_mapped(argument : Value, upper : Bool) : Value
      source = text(argument)
      return unless source
      bytes = source.to_slice
      mapped = Bytes.new(bytes.size) do |index|
        byte = bytes[index]
        if upper
          byte >= 0x61 && byte <= 0x7a ? byte - 32 : byte
        else
          byte >= 0x41 && byte <= 0x5a ? byte + 32 : byte
        end
      end
      String.new(mapped)
    end

    # minmaxFunc: NULL if any argument is NULL; ties go to the later
    # argument for min and the earlier for max.
    def self.min_max(arguments : Array(Value), collation : Collation, maximum : Bool) : Value
      return if arguments[0].nil?
      best = 0
      (1...arguments.size).each do |index|
        return if arguments[index].nil?
        comparison = ValueSemantics.compare(arguments[best], arguments[index], collation)
        if maximum ? comparison < 0 : comparison >= 0
          best = index
        end
      end
      arguments[best]
    end

    def self.concat(arguments : Array(Value), separator : String?) : Value
      String.build do |io|
        any = false
        arguments.each do |argument|
          next if argument.nil?
          piece = text(argument)
          next unless piece
          io << separator if any && separator && !separator.empty?
          io << piece
          any = true
        end
      end
    end

    def self.char(arguments : Array(Value)) : Value
      io = IO::Memory.new
      arguments.each do |argument|
        code = ValueSemantics.integer_value(argument)
        code = 0xfffd_i64 if code < 0 || code > 0x10ffff
        point = (code & 0x1fffff).to_u32
        if point < 0x80
          io.write_byte(point.to_u8)
        elsif point < 0x800
          io.write_byte((0xC0 + ((point >> 6) & 0x1F)).to_u8)
          io.write_byte((0x80 + (point & 0x3F)).to_u8)
        elsif point < 0x10000
          io.write_byte((0xE0 + ((point >> 12) & 0x0F)).to_u8)
          io.write_byte((0x80 + ((point >> 6) & 0x3F)).to_u8)
          io.write_byte((0x80 + (point & 0x3F)).to_u8)
        else
          io.write_byte((0xF0 + ((point >> 18) & 0x07)).to_u8)
          io.write_byte((0x80 + ((point >> 12) & 0x3F)).to_u8)
          io.write_byte((0x80 + ((point >> 6) & 0x3F)).to_u8)
          io.write_byte((0x80 + (point & 0x3F)).to_u8)
        end
      end
      String.new(io.to_slice)
    end

    def self.unicode(argument : Value) : Value
      source = text(argument)
      return if source.nil? || source.empty? || source.byte_at(0) == 0
      bytes = PatternMatch.terminated(source)
      first = bytes[0]
      return first.to_i64 if first < 0xc0
      code = PatternMatch.lead_bits(first)
      index = 1
      while bytes[index] & 0xc0 == 0x80
        code = (code << 6) + (0x3f_u32 & bytes[index])
        index += 1
      end
      code = 0xFFFD_u32 if code < 0x80 || code & 0xFFFFF800_u32 == 0xD800 || code & 0xFFFFFFFE_u32 == 0xFFFE
      code.to_i64
    end

    def self.sign(argument : Value) : Value
      numeric = argument.is_a?(String) ? ValueSemantics.comparison_numeric(argument) : argument
      return unless numeric.is_a?(Int64) || numeric.is_a?(Float64)
      real = ValueSemantics.real_value(numeric)
      real < 0.0 ? -1_i64 : (real > 0.0 ? 1_i64 : 0_i64)
    end

    # The LIKE and GLOB functions: like(pattern, text [, escape]).
    def self.like(arguments : Array(Value), glob : Bool) : Value
      pattern = arguments[0]
      if byte_size(pattern) > 50_000
        raise SQLError.new("LIKE or GLOB pattern too complex")
      end
      rules = glob ? PatternMatch::GLOB_RULES : PatternMatch::LIKE_RULES
      escape = rules.match_set
      if arguments.size == 3
        escape_text = text(arguments[2])
        return unless escape_text
        unless character_count(escape_text.to_slice) == 1 && escape_text.byte_index(0_u8).nil?
          raise SQLError.new("ESCAPE expression must be a single character")
        end
        escape = escape_text.char_at(0).ord.to_u32
        if escape == rules.match_all || escape == rules.match_one
          rules = Rules.copy_without(rules, escape)
        end
      end
      pattern_text = text(pattern)
      subject_text = text(arguments[1])
      return unless pattern_text && subject_text
      PatternMatch.match?(pattern_text, subject_text, rules, escape) ? 1_i64 : 0_i64
    end

    module Rules
      def self.copy_without(rules : PatternMatch::Rules, escape : UInt32) : PatternMatch::Rules
        PatternMatch::Rules.new(
          rules.match_all == escape ? 0_u32 : rules.match_all,
          rules.match_one == escape ? 0_u32 : rules.match_one,
          rules.match_set, rules.no_case)
      end
    end

    private def self.define(name : String, minimum : Int32, maximum : Int32, needs_collation : Bool = false,
                            &implementation : Array(Value), CallContext -> Value) : Definition
      Definition.new(name, minimum, maximum, implementation, needs_collation)
    end

    DEFINITIONS = begin
      list = [
        define("abs", 1, 1) { |arguments, _| abs(arguments[0]) },
        define("changes", 0, 0) { |_, context| context.session.changes },
        define("char", 0, -1) { |arguments, _| char(arguments) },
        define("concat", 1, -1) { |arguments, _| concat(arguments, nil) },
        define("concat_ws", 2, -1) do |arguments, _|
          separator = text(arguments[0])
          separator ? concat(arguments[1..], separator) : nil
        end,
        define("glob", 2, 2) { |arguments, _| like(arguments, glob: true) },
        define("hex", 1, 1) { |arguments, _| hex(arguments[0]) },
        define("unhex", 1, 2) { |arguments, _| unhex(arguments) },
        # The extension loader is off for SQL (SQLITE_LoadExtFunc is unset),
        # so loadExt reports sqlite3_load_extension's refusal.
        define("load_extension", 1, 2) { |_, _| raise SQLError.new("not authorized") },
        define("instr", 2, 2) { |arguments, _| instr(arguments[0], arguments[1]) },
        define("last_insert_rowid", 0, 0) { |_, context| context.session.last_insert_rowid },
        define("length", 1, 1) { |arguments, _| length(arguments[0]) },
        define("like", 2, 3) { |arguments, _| like(arguments, glob: false) },
        define("lower", 1, 1) { |arguments, _| case_mapped(arguments[0], upper: false) },
        define("ltrim", 1, 2) { |arguments, _| trim(arguments, TrimSide::Left) },
        define("max", 2, -1, needs_collation: true) { |arguments, context| min_max(arguments, context.collation, maximum: true) },
        define("min", 2, -1, needs_collation: true) { |arguments, context| min_max(arguments, context.collation, maximum: false) },
        define("nullif", 2, 2, needs_collation: true) do |arguments, context|
          ValueSemantics.compare(arguments[0], arguments[1], context.collation) != 0 ? arguments[0] : nil
        end,
        define("octet_length", 1, 1) { |arguments, _| arguments[0].nil? ? nil : byte_size(arguments[0]).to_i64 },
        define("quote", 1, 1) { |arguments, _| quote(arguments[0]) },
        define("random", 0, 0) { |_, _| Random::Secure.rand(Int64::MIN..Int64::MAX) },
        define("randomblob", 1, 1) do |arguments, _|
          size = ValueSemantics.integer_value(arguments[0]).clamp(1_i64, Limits::MAX_VALUE_BYTES.to_i64)
          Random::Secure.random_bytes(size.to_i32)
        end,
        define("replace", 3, 3) { |arguments, _| replace(arguments[0], arguments[1], arguments[2]) },
        define("round", 1, 2) { |arguments, _| round(arguments) },
        define("rtrim", 1, 2) { |arguments, _| trim(arguments, TrimSide::Right) },
        define("sign", 1, 1) { |arguments, _| sign(arguments[0]) },
        define("sqlite_version", 0, 0) { |_, _| Session::SQLITE_VERSION },
        define("substr", 2, 3) { |arguments, _| substr(arguments) },
        define("substring", 2, 3) { |arguments, _| substr(arguments) },
        define("total_changes", 0, 0) { |_, context| context.session.total_changes },
        define("trim", 1, 2) { |arguments, _| trim(arguments, TrimSide::Both) },
        define("typeof", 1, 1) { |arguments, _| ValueSemantics.type_name(arguments[0]) },
        define("unicode", 1, 1) { |arguments, _| unicode(arguments[0]) },
        define("upper", 1, 1) { |arguments, _| case_mapped(arguments[0], upper: true) },
        define("zeroblob", 1, 1) do |arguments, _|
          size = ValueSemantics.integer_value(arguments[0])
          raise SQLError.new("string or blob too big", SQLError::TOO_BIG) if size > Limits::MAX_VALUE_BYTES
          Bytes.new(Math.max(size, 0_i64).to_i32)
        end,
      ]
      list.concat(JsonFunctions.list_of_definitions)
      list.concat(JsonWriteFunctions.list_of_definitions)
      table = {} of String => Array(Definition)
      list.each { |definition| (table[definition.name] ||= [] of Definition) << definition }
      table
    end
  end
end
