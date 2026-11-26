module Grant::SQLiteEngine::Query
  module Json
    # json.c's JsonCache: the last few JSON texts a statement's functions
    # parsed, with their JSONB. C keeps it for speed, and it shows in
    # results: an edit function (json_set, json_remove, json_patch, ...)
    # whose text result outgrew JsonString's static space stores that text
    # with the JSONB it edited, so a later function given the same text
    # reads the edited bytes (padded headers, raw text nodes) instead of a
    # new parse. jsonb() of such a text returns those bytes.
    #
    # One cache serves one run of a statement (C hangs it on the statement
    # as auxiliary data); `PreparedQuery#step` empties it when a run starts.
    class Cache
      # JSON_CACHE_SIZE.
      SIZE = 4

      record Entry, text : String, document : Document

      @list_of_entries = [] of Entry

      # Every statement run empties the cache, and almost every run finds it
      # empty already, so an empty cache is left as it is.
      def clear : Nil
        @list_of_entries.clear unless @list_of_entries.empty?
      end

      # jsonCacheSearch: the entry whose text is this very string, else the
      # oldest entry with equal text; the entry found becomes the newest.
      def search(text : String) : Document?
        index = @list_of_entries.index(&.text.same?(text))
        index ||= @list_of_entries.index { |entry| entry.text == text }
        return unless index
        entry = @list_of_entries.delete_at(index)
        @list_of_entries << entry
        entry.document
      end

      # jsonCacheInsert: a full cache drops its oldest entry.
      def insert(text : String, document : Document) : Nil
        @list_of_entries.shift if @list_of_entries.size >= SIZE
        @list_of_entries << Entry.new(text, document)
      end
    end

    # jsonParseFuncArg: NULL gives nil, a text argument the cache knows is
    # read from it, a BLOB that is JSONB is used as is, and anything else
    # is parsed as JSON text and remembered. Raises "malformed JSON".
    def self.parse_argument(value : Value, cache : Cache) : Document?
      return if value.nil?
      parse_argument?(value, cache) || raise malformed
    end

    # The same with JSON_KEEPERROR: nil for text that is not JSON (and for
    # NULL), instead of the error.
    def self.parse_argument?(value : Value, cache : Cache) : Document?
      return if value.nil?
      if value.is_a?(String) && (cached = cache.search(value))
        return cached
      end
      if value.is_a?(Bytes) && (document = jsonb_argument(value))
        return document
      end
      text = ValueSemantics.text(value)
      return if text.nil? || text.empty?
      parser = Parser.new(text.to_slice)
      blob = parser.convert || return
      document = Document.new(blob, parser.non_standard?, text)
      cache.insert(text, document)
      document
    end

    # jsonParseFuncArg with JSON_EDITABLE: a private copy of the JSONB.
    def self.parse_editable_argument(value : Value, cache : Cache) : Editor?
      document = parse_argument(value, cache) || return
      Editor.new(document.blob, document.non_standard?)
    end

    # jsonReturnParse: the edited JSONB itself for a jsonb_ function, else
    # its JSON text, which enters the cache with the edited JSONB when it
    # outgrew the static space (jsonReturnString).
    def self.return_edited(editor : Editor, binary : Bool, session : Session) : Value
      return editor.to_bytes if binary
      blob = editor.to_bytes
      document = Document.new(blob, editor.non_standard?)
      output = TextOutput.new
      document.render(0, output)
      raise malformed if output.malformed?
      text = output.to_s
      session.json_cache.insert(text, document) if output.grown?
      session.result_subtype = SUBTYPE
      text
    end

    # jsonReturnStringAsBlob: JSON text a function built, as JSONB.
    def self.text_to_blob(text : String) : Bytes
      Parser.new(text.to_slice).translate_only
    end

    # jsonAppendSqlValue: an SQL value as JSON. Text that came from a JSON
    # function (*subtype* is JSON_SUBTYPE) is JSON already; other text
    # becomes a string; a BLOB must be JSONB.
    def self.append_sql_value(output : TextOutput, value : Value, subtype : UInt8) : Nil
      if value.nil?
        output.write("null")
      elsif value.is_a?(Int64)
        output.write(value.to_s)
      elsif value.is_a?(Float64)
        output.write_formatted(real_text(value))
      elsif value.is_a?(String)
        if subtype == SUBTYPE
          output.write(value)
        else
          append_string(output, value.to_slice)
        end
      elsif document = jsonb_argument(value)
        document.render(0, output)
      elsif !output.malformed?
        output.holds_blob_error = true
      end
    end

    # The error a built text ends in: malformed JSONB among its values
    # first, then a BLOB that was not JSONB.
    def self.raise_error_of(output : TextOutput) : Nil
      raise malformed if output.malformed?
      raise SQLError.new("JSON cannot hold BLOB values") if output.holds_blob_error?
    end

    # "%!0.15g": an infinity prints as a number no double can hold.
    def self.real_text(value : Float64) : String
      return value > 0 ? "9.0e+999" : "-9.0e+999" if value.infinite?
      NumericText.real_text(value)
    end

    # jsonFunctionArgToBlob: an SQL value as the JSONB an edit inserts.
    def self.sql_value_to_blob(value : Value, subtype : UInt8) : Bytes
      if value.nil?
        Bytes[NULL]
      elsif value.is_a?(Int64)
        node(INT, value.to_s.to_slice)
      elsif value.is_a?(Float64)
        if value.infinite?
          node(FLOAT, (value > 0 ? "9e999" : "-9e999").to_slice)
        else
          node(FLOAT, NumericText.real_text(value).to_slice)
        end
      elsif value.is_a?(String)
        return node(TEXTRAW, value.to_slice) unless subtype == SUBTYPE
        Parser.new(value.to_slice).convert || raise malformed
      elsif jsonb_argument(value)
        value
      else
        raise SQLError.new("JSON cannot hold BLOB values")
      end
    end

    # One JSONB node: its header and payload (jsonBlobAppendNode).
    def self.node(type : UInt8, payload : Bytes) : Bytes
      list_of_header_bytes = header(type, payload.size)
      bytes = Bytes.new(list_of_header_bytes.size + payload.size)
      list_of_header_bytes.each_with_index { |byte, index| bytes[index] = byte }
      payload.copy_to(bytes + list_of_header_bytes.size)
      bytes
    end

    # A path argument as C reads it: the text up to its first NUL.
    def self.path_text(value : Value) : String?
      path = ValueSemantics.text(value) || return
      if nul = path.to_slice.index(0_u8)
        return String.new(path.to_slice[0, nul])
      end
      path
    end
  end
end
