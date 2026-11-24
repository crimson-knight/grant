module Grant::SQLiteEngine::Query
  # SQLite's JSON support (json.c of SQLite 3.51.0): JSON text, JSON5
  # included, translates into the JSONB binary format, and every function
  # reads that format, so lookups, rendered text, the ids json_each reports
  # and the errors are C's. Ported: json(), json_extract() with -> and ->>,
  # json_type(), json_valid(), json_array_length(), json_error_position(),
  # and the json_each / json_tree table functions, with the JSON_SUBTYPE
  # their JSON text results carry (read by subtype()). The functions that
  # build or edit JSON are in json_write_functions.cr and
  # json_aggregates.cr, over the Editor of json_editor.cr and the parse
  # cache of json_cache.cr.
  module Json
    NULL    =  0_u8
    TRUE    =  1_u8
    FALSE   =  2_u8
    INT     =  3_u8
    INT5    =  4_u8
    FLOAT   =  5_u8
    FLOAT5  =  6_u8
    TEXT    =  7_u8
    TEXTJ   =  8_u8
    TEXT5   =  9_u8
    TEXTRAW = 10_u8
    ARRAY   = 11_u8
    OBJECT  = 12_u8

    # The subtype json.c gives JSON text results (JSON_SUBTYPE, "J").
    SUBTYPE = 74_u8

    TYPE_NAMES = {"null", "true", "false", "integer", "integer", "real", "real", "text", "text", "text", "text", "array", "object"}

    MAX_DEPTH    =        1000
    INVALID_CHAR = 0x99999_u32

    # jsonLookupStep's failures (JSON_LOOKUP_ERROR, _NOTFOUND, _PATHERROR).
    LOOKUP_ERROR     = -1
    LOOKUP_NOTFOUND  = -2
    LOOKUP_PATHERROR = -3

    # jsonIsOk: bytes that need no escape inside a JSON string.
    OK_BYTES = begin
      table = StaticArray(Bool, 256).new(true)
      (0...0x20).each { |byte| table[byte] = false }
      table['"'.ord] = false
      table['\''.ord] = false
      table['\\'.ord] = false
      table
    end

    MALFORMED = "malformed JSON"

    def self.malformed : SQLError
      SQLError.new(MALFORMED)
    end

    # jsonBadPathError: the path quoted as %Q quotes it.
    def self.bad_path(path : String) : SQLError
      SQLError.new("bad JSON path: '#{path.gsub('\'', "''")}'")
    end

    # sqlite3CtypeMap classes.
    def self.space?(byte : UInt8) : Bool
      byte == 0x09 || byte == 0x0a || byte == 0x0d || byte == 0x20
    end

    def self.digit?(byte : UInt8) : Bool
      byte >= 0x30 && byte <= 0x39
    end

    def self.hex_digit?(byte : UInt8) : Bool
      digit?(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    end

    def self.alpha?(byte : UInt8) : Bool
      (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
    end

    def self.alphanumeric?(byte : UInt8) : Bool
      alpha?(byte) || digit?(byte)
    end

    # sqlite3JsonId1 / sqlite3JsonId2: identifier bytes of a JSON5 label.
    def self.id_start?(byte : UInt8) : Bool
      alpha?(byte) || byte == '$'.ord || byte == '_'.ord || byte >= 0x80
    end

    def self.id_part?(byte : UInt8) : Bool
      id_start?(byte) || digit?(byte)
    end

    def self.hex_value(byte : UInt8) : UInt32
      return (byte - 0x30).to_u32 if digit?(byte)
      ((byte | 0x20) - 0x61 + 10).to_u32
    end

    # A NUL-terminated view of bytes, as C reads them: past the end reads 0.
    struct Bytes0
      getter bytes : Bytes

      def initialize(@bytes : Bytes)
      end

      @[AlwaysInline]
      def [](index : Int32) : UInt8
        index < @bytes.size && index >= 0 ? @bytes.unsafe_fetch(index) : 0_u8
      end

      # strncasecmp over *length* bytes.
      def matches_ignoring_case?(index : Int32, word : String, length : Int32 = word.bytesize) : Bool
        length.times do |offset|
          left = self[index + offset]
          right = offset < word.bytesize ? word.byte_at(offset) : 0_u8
          return false unless (left | 0x20) == (right | 0x20) || left == right
          return false if left == 0
        end
        true
      end

      def matches?(index : Int32, word : String) : Bool
        word.bytesize.times { |offset| return false unless self[index + offset] == word.byte_at(offset) }
        true
      end
    end

    # json5Whitespace: the bytes of JSON5 white space and comments at *index*.
    def self.json5_whitespace(z : Bytes0, index : Int32) : Int32
      n = 0
      loop do
        byte = z[index + n]
        case byte
        when 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20
          n += 1
        when '/'.ord
          if z[index + n + 1] == '*'.ord && z[index + n + 2] != 0
            j = n + 3
            while z[index + j] != '/'.ord || z[index + j - 1] != '*'.ord
              return n if z[index + j] == 0
              j += 1
            end
            n = j + 1
          elsif z[index + n + 1] == '/'.ord
            j = n + 2
            while (c = z[index + j]) != 0
              break if c == '\n'.ord || c == '\r'.ord
              if c == 0xe2 && z[index + j + 1] == 0x80 && (z[index + j + 2] == 0xa8 || z[index + j + 2] == 0xa9)
                j += 2
                break
              end
              j += 1
            end
            n = j
            n += 1 if z[index + n] != 0
          else
            return n
          end
        when 0xc2
          return n unless z[index + n + 1] == 0xa0
          n += 2
        when 0xe1
          return n unless z[index + n + 1] == 0x9a && z[index + n + 2] == 0x80
          n += 3
        when 0xe2
          second = z[index + n + 1]
          third = z[index + n + 2]
          if second == 0x80
            return n if third < 0x80
            return n unless third <= 0x8a || third == 0xa8 || third == 0xa9 || third == 0xaf
            n += 3
          elsif second == 0x81 && third == 0x9f
            n += 3
          else
            return n
          end
        when 0xe3
          return n unless z[index + n + 1] == 0x80 && z[index + n + 2] == 0x80
          n += 3
        when 0xef
          return n unless z[index + n + 1] == 0xbb && z[index + n + 2] == 0xbf
          n += 3
        else
          return n
        end
      end
    end

    # One JSONB value: the bytes, whether its text used JSON5 extensions,
    # the text it came from (nil for a JSONB argument), and where the last
    # lookup landed on an object's label (iLabel).
    class Document
      getter blob : Bytes
      getter? non_standard : Bool
      getter source_text : String?
      property label = 0

      def initialize(@blob : Bytes, @non_standard : Bool = false, @source_text : String? = nil)
      end

      def size : Int32
        @blob.size
      end

      def type_at(index : Int32) : UInt8
        @blob[index] & 0x0f
      end

      # jsonbPayloadSize: the header size (0 when malformed) and payload size.
      def payload_size(index : Int32) : {Int32, Int32}
        Json.payload_size(@blob, index, @blob.size, 0)
      end

      # jsonbArrayCount.
      def array_count(root : Int32) : Int32
        header, size = payload_size(root)
        finish = root + header + size
        count = 0
        index = root + header
        while header > 0 && index < finish
          header, size = payload_size(index)
          index += size + header
          count += 1
        end
        count
      end

      # jsonLookupStep without edits: the index of the element *path*
      # (after the "$") names, or a LOOKUP_ code.
      def lookup(root : Int32, path : Bytes0, at : Int32 = 0, label : Int32 = 0) : Int32
        if path[at] == 0
          @label = label
          return root
        end
        if path[at] == '.'.ord
          raw_key = true
          at += 1
          if path[at] == '"'.ord
            key_start = at + 1
            i = 1
            while path[at + i] != 0 && path[at + i] != '"'.ord
              i += 1 if path[at + i] == '\\'.ord && path[at + i + 1] != 0
              i += 1
            end
            key_size = i - 1
            return LOOKUP_PATHERROR if path[at + i] == 0
            i += 1
            raw_key = !path.bytes[key_start, Math.min(key_size, path.bytes.size - key_start)].includes?('\\'.ord.to_u8)
          else
            key_start = at
            i = 0
            while path[at + i] != 0 && path[at + i] != '.'.ord && path[at + i] != '['.ord
              i += 1
            end
            key_size = i
            return LOOKUP_PATHERROR if key_size == 0
          end
          return LOOKUP_NOTFOUND unless type_at(root) == OBJECT
          header, size = payload_size(root)
          j = root + header
          finish = j + size
          key = path.bytes[key_start, key_size]
          while j < finish
            x = type_at(j)
            return LOOKUP_ERROR if x < TEXT || x > TEXTRAW
            header, size = payload_size(j)
            return LOOKUP_ERROR if header == 0
            k = j + header
            return LOOKUP_ERROR if k + size >= finish
            raw_label = x == TEXT || x == TEXTRAW
            if Json.labels_equal?(key, raw_key, @blob[k, size], raw_label)
              value = k + size
              return LOOKUP_ERROR if type_at(value) > OBJECT
              header, size = payload_size(value)
              return LOOKUP_ERROR if header == 0 || value + header + size > finish
              return lookup(value, path, at + i, j)
            end
            j = k + size
            return LOOKUP_ERROR if type_at(j) > OBJECT
            header, size = payload_size(j)
            return LOOKUP_ERROR if header == 0
            j += header + size
          end
          return LOOKUP_ERROR if j > finish
          return LOOKUP_NOTFOUND
        end
        if path[at] == '['.ord
          return LOOKUP_NOTFOUND unless type_at(root) == ARRAY
          header, size = payload_size(root)
          k = 0_u32
          i = 1
          while Json.digit?(path[at + i])
            k = k &* 10 &+ (path[at + i] - 0x30)
            i += 1
          end
          if i < 2 || path[at + i] != ']'.ord
            return LOOKUP_PATHERROR unless path[at + 1] == '#'.ord
            k = array_count(root).to_u32
            i = 2
            if path[at + 2] == '-'.ord && Json.digit?(path[at + 3])
              back = 0_u32
              i = 3
              loop do
                back = back &* 10 &+ (path[at + i] - 0x30)
                i += 1
                break unless Json.digit?(path[at + i])
              end
              return LOOKUP_NOTFOUND if back > k
              k -= back
            end
            return LOOKUP_PATHERROR unless path[at + i] == ']'.ord
          end
          j = root + header
          finish = j + size
          while j < finish
            return lookup(j, path, at + i + 1, 0) if k == 0
            k -= 1
            header, size = payload_size(j)
            return LOOKUP_ERROR if header == 0
            j += header + size
          end
          return LOOKUP_ERROR if j > finish
          return LOOKUP_NOTFOUND
        end
        LOOKUP_PATHERROR
      end

      # jsonTranslateBlobToText of the element at *index*; returns the index
      # after it. Malformed JSONB sets the flag in *output*.
      def render(index : Int32, output : TextOutput) : Int32
        header, size = payload_size(index)
        if header == 0
          output.malformed = true
          return @blob.size + 1
        end
        payload = index + header
        case type_at(index)
        when NULL  then output.write("null"); return index + 1
        when TRUE  then output.write("true"); return index + 1
        when FALSE then output.write("false"); return index + 1
        when INT, FLOAT
          return malformed_at(index, header, size, output) if size == 0
          output.write(@blob[payload, size])
        when INT5
          return malformed_at(index, header, size, output) if size == 0
          text = @blob[payload, size]
          k = 2
          if text[0] == '-'.ord
            output.write_byte('-'.ord.to_u8)
            k += 1
          elsif text[0] == '+'.ord
            k += 1
          end
          value = 0_u64
          overflow = false
          while k < size
            unless Json.hex_digit?(text[k])
              output.malformed = true
              break
            end
            if (value >> 60) != 0
              overflow = true
            else
              value = value &* 16 &+ Json.hex_value(text[k])
            end
            k += 1
          end
          output.write_formatted(overflow ? "9.0e999" : value.to_s)
        when FLOAT5
          return malformed_at(index, header, size, output) if size == 0
          text = @blob[payload, size]
          k = 0
          if text[0] == '-'.ord
            output.write_byte('-'.ord.to_u8)
            k += 1
          end
          output.write_byte('0'.ord.to_u8) if text[k]? == '.'.ord
          while k < size
            output.write_byte(text[k])
            if text[k] == '.'.ord && (k + 1 == size || !Json.digit?(text[k + 1]))
              output.write_byte('0'.ord.to_u8)
            end
            k += 1
          end
        when TEXT, TEXTJ
          output.write_byte('"'.ord.to_u8)
          output.write(@blob[payload, size])
          output.write_byte('"'.ord.to_u8)
        when TEXT5
          render_text5(@blob[payload, size], output)
        when TEXTRAW
          Json.append_string(output, @blob[payload, size])
        when ARRAY
          output.write_byte('['.ord.to_u8)
          j = payload
          finish = j + size
          while j < finish && !output.malformed?
            j = render(j, output)
            output.write_byte(','.ord.to_u8)
          end
          output.malformed = true if j > finish
          output.trim_one if size > 0
          output.write_byte(']'.ord.to_u8)
        when OBJECT
          count = 0
          output.write_byte('{'.ord.to_u8)
          j = payload
          finish = j + size
          while j < finish && !output.malformed?
            j = render(j, output)
            output.write_byte((count & 1) == 1 ? ','.ord.to_u8 : ':'.ord.to_u8)
            count += 1
          end
          output.malformed = true if (count & 1) != 0 || j > finish
          output.trim_one if size > 0
          output.write_byte('}'.ord.to_u8)
        else
          output.malformed = true
        end
        payload + size
      end

      private def malformed_at(index : Int32, header : Int32, size : Int32, output : TextOutput) : Int32
        output.malformed = true
        index + header + size
      end

      private def render_text5(text : Bytes, output : TextOutput) : Nil
        output.write_byte('"'.ord.to_u8)
        position = 0
        remaining = text.size
        while remaining > 0
          k = 0
          while k < remaining && (OK_BYTES[text[position + k]] || text[position + k] == '\''.ord)
            k += 1
          end
          if k > 0
            output.write(text[position, k])
            break if k >= remaining
            position += k
            remaining -= k
          end
          byte = text[position]
          if byte == '"'.ord
            output.write("\\\"")
            position += 1
            remaining -= 1
            next
          end
          if byte <= 0x1f
            output.make_room(7)
            Json.append_control(output, byte)
            position += 1
            remaining -= 1
            next
          end
          if remaining < 2
            output.malformed = true
            break
          end
          case text[position + 1]
          when '\''.ord then output.write_byte('\''.ord.to_u8)
          when 'v'.ord  then output.write("\\u000b")
          when 'x'.ord
            if remaining < 4
              output.malformed = true
              remaining = 2
            else
              output.write("\\u00")
              output.write(text[position + 2, 2])
              position += 2
              remaining -= 2
            end
          when '0'.ord then output.write("\\u0000")
          when '\r'.ord
            if remaining > 2 && text[position + 2] == '\n'.ord
              position += 1
              remaining -= 1
            end
          when '\n'.ord
          when 0xe2
            if remaining < 4 || text[position + 2] != 0x80 || (text[position + 3] != 0xa8 && text[position + 3] != 0xa9)
              output.malformed = true
              remaining = 2
            else
              position += 2
              remaining -= 2
            end
          else
            output.write(text[position, 2])
          end
          position += 2
          remaining -= 2
        end
        output.write_byte('"'.ord.to_u8)
      end

      # The JSON text of the element at *index*, raising "malformed JSON".
      def text_at(index : Int32) : String
        output = TextOutput.new
        render(index, output)
        raise Json.malformed if output.malformed?
        output.to_s
      end

      # jsonReturnFromBlob: the SQL value of the element at *index*;
      # arrays and objects as JSON text.
      def sql_value(index : Int32) : Value
        header, size = payload_size(index)
        raise Json.malformed if header == 0
        payload = index + header
        case type_at(index)
        when NULL
          raise Json.malformed if size != 0
          nil
        when TRUE
          raise Json.malformed if size != 0
          1_i64
        when FALSE
          raise Json.malformed if size != 0
          0_i64
        when INT, INT5
          raise Json.malformed if size == 0
          negative = false
          start = payload
          length = size
          if @blob[start] == '-'.ord
            raise Json.malformed if length < 2
            start += 1
            length -= 1
            negative = true
          end
          text = @blob[start, length]
          code, value = Json.dec_or_hex_to_i64(text)
          if code == 0
            if value < 0
              real = value.unsafe_as(UInt64).to_f64
              return negative ? -real : real
            end
            return negative ? -value : value
          elsif code == 3 && negative
            return Int64::MIN
          elsif code == 1
            raise Json.malformed
          end
          to_real(@blob[payload, size])
        when FLOAT, FLOAT5
          raise Json.malformed if size == 0
          to_real(@blob[payload, size])
        when TEXT, TEXTRAW
          String.new(@blob[payload, size])
        when TEXTJ, TEXT5
          Json.unescape(@blob[payload, size])
        when ARRAY, OBJECT
          text_at(index)
        else
          raise Json.malformed
        end
      end

      # sqlite3AtoF over the text up to its first NUL (sqlite3DbStrNDup).
      private def to_real(text : Bytes) : Float64
        if nul = text.index(0_u8)
          text = text[0, nul]
        end
        parsed = NumericText.ato_f(text)
        raise Json.malformed if parsed.kind <= 0
        parsed.value
      end

      # jsonbValidityCheck: 0 when the element from *index* to *finish* is
      # well-formed JSONB, else the 1-based offset of the problem.
      def validity_check(index : Int32, finish : Int32, depth : Int32) : Int32
        return index + 1 if depth > MAX_DEPTH
        header, size = payload_size(index)
        return index + 1 if header == 0
        return index + 1 if index + header + size != finish
        z = @blob
        x = type_at(index)
        case x
        when NULL, TRUE, FALSE
          header + size == 1 ? 0 : index + 1
        when INT
          return index + 1 if size < 1
          j = index + header
          if z[j] == '-'.ord
            j += 1
            return index + 1 if size < 2
          end
          k = index + header + size
          while j < k
            return j + 1 unless Json.digit?(z[j])
            j += 1
          end
          0
        when INT5
          return index + 1 if size < 3
          j = index + header
          if z[j] == '-'.ord
            return index + 1 if size < 4
            j += 1
          end
          return index + 1 if z[j] != '0'.ord
          return j + 2 if z[j + 1] != 'x'.ord && z[j + 1] != 'X'.ord
          j += 2
          k = index + header + size
          while j < k
            return j + 1 unless Json.hex_digit?(z[j])
            j += 1
          end
          0
        when FLOAT, FLOAT5
          seen = 0
          return index + 1 if size < 2
          j = index + header
          k = j + size
          if z[j] == '-'.ord
            j += 1
            return index + 1 if size < 3
          end
          at = ->(position : Int32) { position < z.size ? z[position] : 0_u8 }
          if z[j] == '.'.ord
            return j + 1 if x == FLOAT
            return j + 1 unless Json.digit?(at.call(j + 1))
            j += 2
            seen = 1
          elsif z[j] == '0'.ord && x == FLOAT
            return j + 1 if j + 3 > k
            return j + 1 if at.call(j + 1) != '.'.ord && at.call(j + 1) != 'e'.ord && at.call(j + 1) != 'E'.ord
            j += 1
          end
          while j < k
            byte = z[j]
            if Json.digit?(byte)
              j += 1
              next
            end
            if byte == '.'.ord
              return j + 1 if seen > 0
              return j + 1 if x == FLOAT && (j == k - 1 || !Json.digit?(at.call(j + 1)))
              seen = 1
              j += 1
              next
            end
            if byte == 'e'.ord || byte == 'E'.ord
              return j + 1 if seen == 2
              return j + 1 if j == k - 1
              if at.call(j + 1) == '+'.ord || at.call(j + 1) == '-'.ord
                j += 1
                return j + 1 if j == k - 1
              end
              seen = 2
              j += 1
              next
            end
            return j + 1
          end
          seen == 0 ? index + 1 : 0
        when TEXT
          j = index + header
          k = j + size
          while j < k
            return j + 1 if !OK_BYTES[z[j]] && z[j] != '\''.ord
            j += 1
          end
          0
        when TEXTJ, TEXT5
          j = index + header
          k = j + size
          while j < k
            byte = z[j]
            if !OK_BYTES[byte] && byte != '\''.ord
              if byte == '"'.ord
                return j + 1 if x == TEXTJ
              elsif byte <= 0x1f
                return j + 1 if x == TEXTJ
              elsif byte != '\\'.ord || j + 1 >= k
                return j + 1
              elsif "\"\\/bfnrt".includes?(z[j + 1].chr)
                j += 1
              elsif z[j + 1] == 'u'.ord
                return j + 1 if j + 5 >= k
                return j + 1 unless (2..5).all? { |offset| Json.hex_digit?(z[j + offset]) }
                j += 1
              elsif x != TEXT5
                return j + 1
              else
                consumed, char = Json.unescape_one(z[j, k - j])
                return j + 1 if char == INVALID_CHAR
                j += consumed - 1
              end
            end
            j += 1
          end
          0
        when TEXTRAW
          0
        when ARRAY
          j = index + header
          k = j + size
          while j < k
            header, size = payload_size(j)
            return j + 1 if header == 0
            return j + 1 if j + header + size > k
            sub = validity_check(j, j + header + size, depth + 1)
            return sub if sub != 0
            j += header + size
          end
          0
        when OBJECT
          count = 0
          j = index + header
          k = j + size
          while j < k
            header, size = payload_size(j)
            return j + 1 if header == 0
            return j + 1 if j + header + size > k
            if count.even?
              label_type = type_at(j)
              return j + 1 if label_type < TEXT || label_type > TEXTRAW
            end
            sub = validity_check(j, j + header + size, depth + 1)
            return sub if sub != 0
            count += 1
            j += header + size
          end
          count.odd? ? j + 1 : 0
        else
          index + 1
        end
      end
    end

    # jsonbPayloadSize over the first *limit* bytes of *blob*: the header size
    # (0 when malformed) and payload size. *delta* is the size change of an
    # edit in progress, whose enclosing sizes are not yet adjusted.
    def self.payload_size(blob : Bytes, index : Int32, limit : Int32, delta : Int32) : {Int32, Int32}
      return {0, 0} if index >= limit
      x = blob[index] >> 4
      if x <= 11
        size = x.to_i64
        header = 1
      elsif x == 12
        return {0, 0} if index + 1 >= limit
        size = blob[index + 1].to_i64
        header = 2
      elsif x == 13
        return {0, 0} if index + 2 >= limit
        size = (blob[index + 1].to_i64 << 8) + blob[index + 2]
        header = 3
      elsif x == 14
        return {0, 0} if index + 4 >= limit
        size = (blob[index + 1].to_i64 << 24) + (blob[index + 2].to_i64 << 16) + (blob[index + 3].to_i64 << 8) + blob[index + 4]
        header = 5
      else
        return {0, 0} if index + 8 >= limit || (1..4).any? { |offset| blob[index + offset] != 0 }
        size = (blob[index + 5].to_i64 << 24) + (blob[index + 6].to_i64 << 16) + (blob[index + 7].to_i64 << 8) + blob[index + 8]
        header = 9
      end
      finish = index.to_i64 + size + header
      return {0, 0} if finish > limit && finish > limit.to_i64 - delta
      {header, size.to_i32}
    end

    # JsonString: JSON text being built, with its malformed flag.
    class TextOutput
      # The bytes JsonString holds in its own space before it allocates.
      STATIC_SIZE = 100

      property? malformed = false
      # JSTRING_ERR: a BLOB that is not JSONB was given as a value. C reports
      # it when the function returns, unless another error replaces it.
      property? holds_blob_error = false
      # Whether C would have moved the text out of JsonString.zSpace (bStatic
      # cleared): only such results enter the parse cache (jsonReturnString).
      getter? grown = false
      @io = IO::Memory.new

      # jsonAppendRaw / jsonAppendRawNZ.
      def write(text : String) : Nil
        @grown = true if @io.pos + text.bytesize >= STATIC_SIZE
        @io << text
      end

      def write(bytes : Bytes) : Nil
        @grown = true if @io.pos + bytes.size >= STATIC_SIZE
        @io.write(bytes)
      end

      # jsonAppendChar.
      def write_byte(byte : UInt8) : Nil
        @grown = true if @io.pos >= STATIC_SIZE
        @io.write_byte(byte)
      end

      # A direct store into the buffer, after the caller made room.
      def store_byte(byte : UInt8) : Nil
        @io.write_byte(byte)
      end

      def store(bytes : Bytes) : Nil
        @io.write(bytes)
      end

      # jsonStringGrow where C asks for room for *count* more bytes and the
      # text would pass *limit* (STATIC_SIZE, or one less for a >= test).
      def make_room(count : Int32, limit : Int32 = STATIC_SIZE) : Nil
        @grown = true if @io.pos + count > limit
      end

      # jsonPrintf(100, ...): always past the static space.
      def write_formatted(text : String) : Nil
        @grown = true
        @io << text
      end

      def size : Int64
        @io.pos.to_i64
      end

      def last_byte : UInt8?
        return if @io.pos == 0
        @io.to_slice[@io.pos - 1]
      end

      def trim_one : Nil
        @io.seek(-1, IO::Seek::Current) if @io.pos > 0
      end

      # jsonAppendSeparator.
      def separate : Nil
        last = last_byte
        return if last.nil? || last == '['.ord || last == '{'.ord
        write_byte(','.ord.to_u8)
      end

      def to_s : String
        String.new(@io.to_slice[0, @io.pos])
      end

      def truncate_to(size : Int64) : Nil
        @io.pos = size
      end
    end

    # jsonAppendControlChar.
    def self.append_control(output : TextOutput, byte : UInt8) : Nil
      special = case byte
                when 0x08 then 'b'
                when 0x09 then 't'
                when 0x0a then 'n'
                when 0x0c then 'f'
                when 0x0d then 'r'
                end
      if special
        output.store_byte('\\'.ord.to_u8)
        output.store_byte(special.ord.to_u8)
      else
        output.store("\\u00".to_slice)
        output.store_byte("0123456789abcdef".byte_at(byte >> 4))
        output.store_byte("0123456789abcdef".byte_at(byte & 0xf))
      end
    end

    # jsonAppendString: *text* as a JSON string literal, asking for room
    # where C does.
    def self.append_string(output : TextOutput, text : Bytes) : Nil
      output.make_room(text.size + 2, TextOutput::STATIC_SIZE - 1)
      output.store_byte('"'.ord.to_u8)
      text.each_with_index do |byte, index|
        if OK_BYTES[byte] || byte == '\''.ord
          output.store_byte(byte)
        elsif byte == '"'.ord || byte == '\\'.ord
          output.make_room(text.size - index + 3)
          output.store_byte('\\'.ord.to_u8)
          output.store_byte(byte)
        else
          output.make_room(text.size - index + 7)
          append_control(output, byte)
        end
      end
      output.store_byte('"'.ord.to_u8)
    end

    # jsonBytesToBypass: escaped line breaks a JSON5 string skips.
    def self.bytes_to_bypass(z : Bytes) : Int32
      i = 0
      n = z.size
      while i + 1 < n
        return i if z[i] != '\\'.ord
        if z[i + 1] == '\n'.ord
          i += 2
          next
        end
        if z[i + 1] == '\r'.ord
          i += (i + 2 < n && z[i + 2] == '\n'.ord) ? 3 : 2
          next
        end
        if z[i + 1] == 0xe2 && i + 3 < n && z[i + 2] == 0x80 && (z[i + 3] == 0xa8 || z[i + 3] == 0xa9)
          i += 4
          next
        end
        break
      end
      i
    end

    private def self.hex4(z : Bytes, at : Int32) : UInt32
      (0...4).reduce(0_u32) { |value, offset| (value << 4) | hex_value(z[at + offset]) }
    end

    # jsonUnescapeOneChar: the bytes an escape at the start of *z* spans
    # and the code point it stands for (INVALID_CHAR when it is bad).
    def self.unescape_one(z : Bytes) : {Int32, UInt32}
      n = z.size
      return {n, INVALID_CHAR} if n < 2
      case z[1]
      when 'u'.ord
        return {n, INVALID_CHAR} if n < 6
        v = hex4(z, 2)
        if (v & 0xfc00) == 0xd800 && n >= 12 && z[6] == '\\'.ord && z[7] == 'u'.ord
          low = hex4(z, 8)
          return {12, ((v & 0x3ff) << 10) + (low & 0x3ff) + 0x10000} if (low & 0xfc00) == 0xdc00
        end
        {6, v}
      when 'b'.ord then {2, 8_u32}
      when 'f'.ord then {2, 12_u32}
      when 'n'.ord then {2, 10_u32}
      when 'r'.ord then {2, 13_u32}
      when 't'.ord then {2, 9_u32}
      when 'v'.ord then {2, 11_u32}
      when '0'.ord
        {2, (n > 2 && digit?(z[2])) ? INVALID_CHAR : 0_u32}
      when '\''.ord, '"'.ord, '/'.ord, '\\'.ord
        {2, z[1].to_u32}
      when 'x'.ord
        return {n, INVALID_CHAR} if n < 4
        {4, (hex_value(z[2]) << 4) | hex_value(z[3])}
      when 0xe2, '\r'.ord, '\n'.ord
        skip = bytes_to_bypass(z)
        if skip == 0
          {n, INVALID_CHAR}
        elsif skip == n
          {n, 0_u32}
        elsif z[skip] == '\\'.ord
          consumed, char = unescape_one(z[skip, n - skip])
          {skip + consumed, char}
        else
          consumed, char = read_utf8_limited(z[skip, n - skip])
          {skip + consumed, char}
        end
      else
        {2, INVALID_CHAR}
      end
    end

    # sqlite3Utf8ReadLimited.
    def self.read_utf8_limited(z : Bytes) : {Int32, UInt32}
      n = Math.min(z.size, 4)
      c = z[0].to_u32
      i = 1
      if c >= 0xc0
        c = UTF8_TRANS1[c - 0xc0].to_u32
        while i < n && (z[i] & 0xc0) == 0x80
          c = (c << 6) + (z[i] & 0x3f)
          i += 1
        end
      end
      {i, c}
    end

    UTF8_TRANS1 = [
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
      0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x00, 0x01, 0x02, 0x03, 0x00, 0x01, 0x00, 0x00,
    ] of UInt8

    # The text of a TEXTJ / TEXT5 payload with its escapes decoded.
    def self.unescape(z : Bytes) : String
      output = IO::Memory.new(z.size)
      index = 0
      while index < z.size
        byte = z[index]
        if byte == '\\'.ord
          consumed, v = unescape_one(z[index, z.size - index])
          if v <= 0x7f
            output.write_byte(v.to_u8)
          elsif v <= 0x7ff
            output.write_byte((0xc0 | (v >> 6)).to_u8!)
            output.write_byte((0x80 | (v & 0x3f)).to_u8!)
          elsif v < 0x10000
            output.write_byte((0xe0 | (v >> 12)).to_u8!)
            output.write_byte((0x80 | ((v >> 6) & 0x3f)).to_u8!)
            output.write_byte((0x80 | (v & 0x3f)).to_u8!)
          elsif v == INVALID_CHAR
            # C silently drops an invalid escape.
          else
            output.write_byte((0xf0 | (v >> 18)).to_u8!)
            output.write_byte((0x80 | ((v >> 12) & 0x3f)).to_u8!)
            output.write_byte((0x80 | ((v >> 6) & 0x3f)).to_u8!)
            output.write_byte((0x80 | (v & 0x3f)).to_u8!)
          end
          index += consumed
        else
          output.write_byte(byte)
          index += 1
        end
      end
      String.new(output.to_slice)
    end

    # jsonLabelCompare: a path key and an object label, either of which
    # may hold escapes.
    def self.labels_equal?(left : Bytes, raw_left : Bool, right : Bytes, raw_right : Bool) : Bool
      return left == right if raw_left && raw_right
      left_at = 0
      right_at = 0
      loop do
        left_char, left_at = next_label_char(left, left_at, raw_left)
        right_char, right_at = next_label_char(right, right_at, raw_right)
        return false if left_char != right_char
        return true if left_char == 0
      end
    end

    private def self.next_label_char(text : Bytes, at : Int32, raw : Bool) : {UInt32, Int32}
      return {0_u32, at} if at >= text.size
      if raw || text[at] != '\\'.ord
        char = text[at].to_u32
        if char >= 0xc0
          size, char = read_utf8_limited(text[at, text.size - at])
          return {char, at + size}
        end
        return {char, at + 1}
      end
      consumed, char = unescape_one(text[at, text.size - at])
      {char, at + consumed}
    end

    # sqlite3DecOrHexToI64: the Atoi64 code and the value.
    def self.dec_or_hex_to_i64(text : Bytes) : {Int32, Int64}
      z = Bytes0.new(text)
      if z[0] == '0'.ord && (z[1] == 'x'.ord || z[1] == 'X'.ord)
        value = 0_u64
        i = 2
        while z[i] == '0'.ord
          i += 1
        end
        k = i
        while hex_digit?(z[k])
          value = value &* 16 &+ hex_value(z[k])
          k += 1
        end
        result = value.unsafe_as(Int64)
        return {2, result} if k - i > 16
        return {1, result} if z[k] != 0
        return {0, result}
      end
      n = 0
      while n < text.size && "+- \n\t0123456789".includes?(text[n].chr)
        n += 1
      end
      n += 1 if n < text.size
      parsed = NumericText.atoi64(text[0, Math.min(n, text.size)])
      {parsed.code, parsed.value}
    end

    # jsonArgIsJsonb.
    def self.jsonb_argument(bytes : Bytes) : Document?
      return if bytes.empty?
      document = Document.new(bytes)
      first = bytes[0]
      return if (first & 0x0f) > OBJECT
      header, size = document.payload_size(0)
      return unless header > 0 && size + header == bytes.size
      return unless (first & 0x0f) > FALSE || size == 0
      if size <= 7 && (first == 0x7b || first == 0x5b || digit?(first)) && document.validity_check(0, bytes.size, 1) != 0
        return
      end
      document
    end

    # jsonTranslateTextToBlob: JSON text to JSONB.
    class Parser
      getter? non_standard = false
      getter error_at = 0

      @z : Bytes0
      @blob = [] of UInt8
      @depth = 0

      def initialize(text : Bytes)
        @z = Bytes0.new(text)
      end

      # jsonConvertTextToBlob: the JSONB, or nil when the text is malformed.
      def convert : Bytes?
        z = @z
        i = translate(0)
        if i > 0
          while Json.space?(z[i])
            i += 1
          end
          if z[i] != 0
            i += Json.json5_whitespace(z, i)
            return if z[i] != 0
            @non_standard = true
          end
        end
        return if i <= 0
        Bytes.new(@blob.size) { |index| @blob.unsafe_fetch(index) }
      end

      # jsonReturnStringAsBlob: the JSONB of text the caller built, taken as
      # translated (no check of what follows the value).
      def translate_only : Bytes
        translate(0)
        Bytes.new(@blob.size) { |index| @blob.unsafe_fetch(index) }
      end

      private def append_node(type : UInt8, payload_size : Int32, payload : Bytes? = nil) : Nil
        Json.header(type, payload_size).each { |byte| @blob << byte }
        payload.try(&.each { |byte| @blob << byte })
      end

      private def append_text(type : UInt8, start : Int32, size : Int32) : Nil
        append_node(type, size, @z.bytes[start, size])
      end

      # jsonBlobChangePayloadSize: rewrites a container's header for its
      # final size (the smallest header that holds it).
      private def change_payload_size(at : Int32, size : Int32) : Nil
        old_header = Json.header_size_of(@blob[at])
        replacement = Json.header(@blob[at] & 0x0f, size)
        @blob[at, old_header] = replacement
      end

      private def strspn_spaces(at : Int32) : Int32
        n = 0
        while Json.space?(@z[at + n])
          n += 1
        end
        n
      end

      # One element at *i*: the index after it, or 0 at end of input, -1 on
      # a syntax error, -2 '}', -3 ']', -4 ',', -5 ':' (error_at holds the
      # position of the character seen).
      def translate(i : Int32) : Int32
        z = @z
        loop do
          case z[i]
          when '{'.ord
            this = @blob.size
            append_node(OBJECT, Math.max(z.bytes.size - i, 0))
            @depth += 1
            if @depth > MAX_DEPTH
              @error_at = i
              return -1
            end
            start = @blob.size
            j = i + 1
            loop do
              blob_at = @blob.size
              x = translate(j)
              if x <= 0
                if x == -2
                  j = @error_at
                  @non_standard = true if @blob.size != start
                  break
                end
                j += Json.json5_whitespace(z, j)
                op = TEXT
                escaped = z[j] == '\\'.ord && four_hex_u?(j + 1)
                if Json.id_start?(z[j]) || escaped
                  op = TEXTJ if escaped
                  k = j + 1
                  loop do
                    if Json.id_part?(z[k]) && Json.json5_whitespace(z, k) == 0
                      k += 1
                    elsif z[k] == '\\'.ord && four_hex_u?(k + 1)
                      op = TEXTJ
                      k += 1
                    else
                      break
                    end
                  end
                  append_text(op, j, k - j)
                  @non_standard = true
                  x = k
                else
                  @error_at = j if x != -1
                  return -1
                end
              end
              t = @blob[blob_at] & 0x0f
              if t < TEXT || t > TEXTRAW
                @error_at = j
                return -1
              end
              j = x
              if z[j] == ':'.ord
                j += 1
              else
                found_colon = false
                if Json.space?(z[j])
                  j += 1
                  while Json.space?(z[j])
                    j += 1
                  end
                  if z[j] == ':'.ord
                    j += 1
                    found_colon = true
                  end
                end
                unless found_colon
                  x = translate(j)
                  if x != -5
                    @error_at = j if x != -1
                    return -1
                  end
                  j = @error_at + 1
                end
              end
              x = translate(j)
              if x <= 0
                @error_at = j if x != -1
                return -1
              end
              j = x
              if z[j] == ','.ord
                j += 1
                next
              elsif z[j] == '}'.ord
                break
              else
                if Json.space?(z[j])
                  j += 1 + strspn_spaces(j + 1)
                  if z[j] == ','.ord
                    j += 1
                    next
                  elsif z[j] == '}'.ord
                    break
                  end
                end
                x = translate(j)
                if x == -4
                  j = @error_at + 1
                  next
                end
                if x == -2
                  j = @error_at
                  break
                end
              end
              @error_at = j
              return -1
            end
            fix_container(this, start)
            @depth -= 1
            return j + 1
          when '['.ord
            this = @blob.size
            append_node(ARRAY, Math.max(z.bytes.size - i, 0))
            start = @blob.size
            @depth += 1
            if @depth > MAX_DEPTH
              @error_at = i
              return -1
            end
            j = i + 1
            loop do
              x = translate(j)
              if x <= 0
                if x == -3
                  j = @error_at
                  @non_standard = true if @blob.size != start
                  break
                end
                @error_at = j if x != -1
                return -1
              end
              j = x
              if z[j] == ','.ord
                j += 1
                next
              elsif z[j] == ']'.ord
                break
              else
                if Json.space?(z[j])
                  j += 1 + strspn_spaces(j + 1)
                  if z[j] == ','.ord
                    j += 1
                    next
                  elsif z[j] == ']'.ord
                    break
                  end
                end
                x = translate(j)
                if x == -4
                  j = @error_at + 1
                  next
                end
                if x == -3
                  j = @error_at
                  break
                end
              end
              @error_at = j
              return -1
            end
            fix_container(this, start)
            @depth -= 1
            return j + 1
          when '\''.ord, '"'.ord
            return parse_string(i)
          when 't'.ord
            if z.matches?(i, "true") && !Json.alphanumeric?(z[i + 4])
              @blob << TRUE
              return i + 4
            end
            @error_at = i
            return -1
          when 'f'.ord
            if z.matches?(i, "false") && !Json.alphanumeric?(z[i + 5])
              @blob << FALSE
              return i + 5
            end
            @error_at = i
            return -1
          when '+'.ord, '.'.ord, '-'.ord, '0'.ord, '1'.ord, '2'.ord, '3'.ord, '4'.ord, '5'.ord, '6'.ord, '7'.ord, '8'.ord, '9'.ord
            return parse_number(i)
          when '}'.ord
            @error_at = i
            return -2
          when ']'.ord
            @error_at = i
            return -3
          when ','.ord
            @error_at = i
            return -4
          when ':'.ord
            @error_at = i
            return -5
          when 0
            return 0
          when 0x09, 0x0a, 0x0d, 0x20
            i += 1 + strspn_spaces(i + 1)
            next
          when 0x0b, 0x0c, '/'.ord, 0xc2, 0xe1, 0xe2, 0xe3, 0xef
            skip = Json.json5_whitespace(z, i)
            if skip > 0
              i += skip
              @non_standard = true
              next
            end
            @error_at = i
            return -1
          else
            if z[i] == 'n'.ord && z.matches?(i, "null") && !Json.alphanumeric?(z[i + 4])
              @blob << NULL
              return i + 4
            end
            return nan_or_infinity(i)
          end
        end
      end

      # The container header at *at* was written for the largest size; C
      # shrinks it to the final payload.
      private def fix_container(at : Int32, start : Int32) : Nil
        change_payload_size(at, @blob.size - start)
      end

      private def four_hex_u?(at : Int32) : Bool
        @z[at] == 'u'.ord && (1..4).all? { |offset| Json.hex_digit?(@z[at + offset]) }
      end

      private def nan_or_infinity(i : Int32) : Int32
        z = @z
        c = z[i]
        NAN_INF.each do |first, length, float, match|
          next unless c == first || c == (first ^ 0x20)
          next unless z.matches_ignoring_case?(i, match, length)
          next if Json.alphanumeric?(z[i + length])
          if float
            append_node(FLOAT, 5, "9e999".to_slice)
          else
            @blob << NULL
          end
          @non_standard = true
          return i + length
        end
        @error_at = i
        -1
      end

      NAN_INF = [
        {'i'.ord.to_u8, 3, true, "inf"},
        {'i'.ord.to_u8, 8, true, "infinity"},
        {'n'.ord.to_u8, 3, false, "NaN"},
        {'q'.ord.to_u8, 4, false, "QNaN"},
        {'s'.ord.to_u8, 4, false, "SNaN"},
      ]

      private def parse_string(i : Int32) : Int32
        z = @z
        delimiter = z[i]
        opcode = TEXT
        @non_standard = true if delimiter == '\''.ord
        j = i + 1
        loop do
          c = z[j]
          if OK_BYTES[c]
            j += 1
            next
          end
          if c == delimiter
            break
          elsif c == '\\'.ord
            j += 1
            c = z[j]
            if c == '"'.ord || c == '\\'.ord || c == '/'.ord || c == 'b'.ord || c == 'f'.ord ||
               c == 'n'.ord || c == 'r'.ord || c == 't'.ord || (c == 'u'.ord && (1..4).all? { |offset| Json.hex_digit?(z[j + offset]) })
              opcode = TEXTJ if opcode == TEXT
            elsif c == '\''.ord || c == 'v'.ord || c == '\n'.ord || (c == '0'.ord && !Json.digit?(z[j + 1])) ||
                  (c == 0xe2 && z[j + 1] == 0x80 && (z[j + 2] == 0xa8 || z[j + 2] == 0xa9)) ||
                  (c == 'x'.ord && Json.hex_digit?(z[j + 1]) && Json.hex_digit?(z[j + 2]))
              opcode = TEXT5
              @non_standard = true
            elsif c == '\r'.ord
              j += 1 if z[j + 1] == '\n'.ord
              opcode = TEXT5
              @non_standard = true
            else
              @error_at = j
              return -1
            end
          elsif c <= 0x1f
            if c == 0
              @error_at = j
              return -1
            end
            opcode = TEXT5
            @non_standard = true
          elsif c == '"'.ord
            opcode = TEXT5
          end
          j += 1
        end
        append_text(opcode, i + 1, j - 1 - i)
        j + 1
      end

      private def parse_number(i : Int32) : Int32
        z = @z
        t = 0
        c = z[i]
        case c
        when '+'.ord
          @non_standard = true
        when '.'.ord
          unless Json.digit?(z[i + 1])
            @error_at = i
            return -1
          end
          @non_standard = true
          t = 0x03
          return parse_number_2(i, t)
        end
        if c <= '0'.ord
          if c == '0'.ord
            if (z[i + 1] == 'x'.ord || z[i + 1] == 'X'.ord) && Json.hex_digit?(z[i + 2])
              @non_standard = true
              t = 0x01
              j = i + 3
              while Json.hex_digit?(z[j])
                j += 1
              end
              return finish_number(i, j, t)
            elsif Json.digit?(z[i + 1])
              @error_at = i + 1
              return -1
            end
          else
            unless Json.digit?(z[i + 1])
              if (z[i + 1] == 'I'.ord || z[i + 1] == 'i'.ord) && z.matches_ignoring_case?(i + 1, "inf", 3)
                @non_standard = true
                if c == '-'.ord
                  append_node(FLOAT, 6, "-9e999".to_slice)
                else
                  append_node(FLOAT, 5, "9e999".to_slice)
                end
                return i + (z.matches_ignoring_case?(i + 4, "inity", 5) ? 9 : 4)
              end
              if z[i + 1] == '.'.ord
                @non_standard = true
                t |= 0x01
                return parse_number_2(i, t)
              end
              @error_at = i
              return -1
            end
            if z[i + 1] == '0'.ord
              if Json.digit?(z[i + 2])
                @error_at = i + 1
                return -1
              elsif (z[i + 2] == 'x'.ord || z[i + 2] == 'X'.ord) && Json.hex_digit?(z[i + 3])
                @non_standard = true
                t |= 0x01
                j = i + 4
                while Json.hex_digit?(z[j])
                  j += 1
                end
                return finish_number(i, j, t)
              end
            end
          end
        end
        parse_number_2(i, t)
      end

      private def parse_number_2(i : Int32, t : Int32) : Int32
        z = @z
        seen_e = false
        j = i + 1
        loop do
          c = z[j]
          if Json.digit?(c)
            j += 1
            next
          end
          if c == '.'.ord
            if (t & 0x02) != 0
              @error_at = j
              return -1
            end
            t |= 0x02
            j += 1
            next
          end
          if c == 'e'.ord || c == 'E'.ord
            if z[j - 1] < '0'.ord
              if z[j - 1] == '.'.ord && j - 2 >= i && Json.digit?(z[j - 2])
                @non_standard = true
                t |= 0x01
              else
                @error_at = j
                return -1
              end
            end
            if seen_e
              @error_at = j
              return -1
            end
            t |= 0x02
            seen_e = true
            c = z[j + 1]
            if c == '+'.ord || c == '-'.ord
              j += 1
              c = z[j + 1]
            end
            if c < '0'.ord || c > '9'.ord
              @error_at = j
              return -1
            end
            j += 1
            next
          end
          break
        end
        if z[j - 1] < '0'.ord
          if z[j - 1] == '.'.ord && j - 2 >= i && Json.digit?(z[j - 2])
            @non_standard = true
            t |= 0x01
          else
            @error_at = j
            return -1
          end
        end
        finish_number(i, j, t)
      end

      private def finish_number(i : Int32, j : Int32, t : Int32) : Int32
        i += 1 if @z[i] == '+'.ord
        append_text((INT + t).to_u8, i, j - i)
        j
      end
    end

    # The header of a node of *type* with *size* payload bytes, as small
    # as it can be (jsonBlobAppendNode).
    def self.header(type : UInt8, size : Int32) : Array(UInt8)
      if size <= 11
        [type | (size << 4).to_u8]
      elsif size <= 0xff
        [type | 0xc0_u8, size.to_u8]
      elsif size <= 0xffff
        [type | 0xd0_u8, (size >> 8).to_u8!, size.to_u8!]
      else
        [type | 0xe0_u8, (size >> 24).to_u8!, (size >> 16).to_u8!, (size >> 8).to_u8!, size.to_u8!]
      end
    end

    def self.header_size_of(first : UInt8) : Int32
      case first >> 4
      when 0..11 then 1
      when 12    then 2
      when 13    then 3
      when 14    then 5
      else            9
      end
    end
  end
end
