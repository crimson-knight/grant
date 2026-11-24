module Grant::SQLiteEngine::Query
  # The scalar JSON functions of json.c (SQLite 3.51.0) that read JSON:
  # json(), json_extract() and its -> / ->> operators, json_type(),
  # json_valid(), json_array_length() and json_error_position().
  module JsonFunctions
    alias Definition = ScalarFunctions::Definition

    # How json_extract returns what it finds (JSON_JSON / JSON_SQL flags):
    # json_extract gives SQL values with containers as JSON text, -> always
    # JSON text, ->> always SQL values.
    enum ExtractMode
      Extract
      JsonText
      SqlValue
    end

    def self.list_of_definitions : Array(Definition)
      [
        definition("json", 1, 1) { |arguments, session| json(arguments[0], session) },
        definition("json_extract", 0, -1) { |arguments, session| extract(arguments, ExtractMode::Extract, session) },
        definition("->", 2, 2) { |arguments, session| extract(arguments, ExtractMode::JsonText, session) },
        definition("->>", 2, 2) { |arguments, session| extract(arguments, ExtractMode::SqlValue, session) },
        definition("json_type", 1, 2) { |arguments, session| type(arguments, session) },
        definition("json_valid", 1, 2) { |arguments, session| valid(arguments, session) },
        definition("json_array_length", 1, 2) { |arguments, session| array_length(arguments, session) },
        definition("json_error_position", 1, 1) { |arguments, _session| error_position(arguments[0]) },
      ]
    end

    # Every function gets the session: its JSON cache (jsonParseFuncArg),
    # and the result subtype a function sets as C calls
    # sqlite3_result_subtype.
    private def self.definition(name : String, minimum : Int32, maximum : Int32,
                                &implementation : Array(Value), Session -> Value) : Definition
      Definition.new(name, minimum, maximum, ->(arguments : Array(Value), context : ScalarFunctions::CallContext) { implementation.call(arguments, context.session) })
    end

    # json(X): the minified text of X (jsonRemoveFunc with no paths), with
    # JSON_SUBTYPE.
    def self.json(argument : Value, session : Session) : Value
      document = Json.parse_argument(argument, session.json_cache) || return
      session.result_subtype = Json::SUBTYPE
      document.text_at(0)
    end

    # jsonExtractFunc: JSON text results (every -> result, a json_extract
    # container, a json_extract of several paths) carry JSON_SUBTYPE.
    def self.extract(arguments : Array(Value), mode : ExtractMode, session : Session, binary : Bool = false) : Value
      return if arguments.size < 2
      document = Json.parse_argument(arguments[0], session.json_cache) || return
      many = arguments.size > 2
      output = Json::TextOutput.new
      output.write_byte('['.ord.to_u8) if many
      arguments[1..].each do |path_value|
        path = ValueSemantics.text(path_value)
        return unless path
        path_bytes = path.to_slice
        if nul = path_bytes.index(0_u8)
          path = String.new(path_bytes[0, nul])
        end
        found = if path.starts_with?('$')
                  document.lookup(0, Json::Bytes0.new(path.to_slice), 1)
                elsif !mode.extract?
                  document.lookup(0, Json::Bytes0.new(abbreviated_path(path, path_value).to_slice), 0)
                else
                  raise Json.bad_path(path)
                end
        if found >= 0 && found < document.size
          if many
            output.separate
            document.render(found, output)
          elsif mode.json_text?
            session.result_subtype = Json::SUBTYPE
            return document.text_at(found)
          else
            if mode.extract? && document.type_at(found) >= Json::ARRAY
              # jsonb_extract returns a container as its JSONB bytes.
              if binary
                header, size = document.payload_size(found)
                raise Json.malformed if header == 0
                return document.blob[found, header + size]
              end
              session.result_subtype = Json::SUBTYPE
            end
            return document.sql_value(found)
          end
        elsif found == Json::LOOKUP_NOTFOUND
          return unless many
          output.separate
          output.write("null")
        elsif found == Json::LOOKUP_ERROR
          raise Json.malformed
        else
          raise Json.bad_path(path)
        end
      end
      output.write_byte(']'.ord.to_u8)
      raise Json.malformed if output.malformed?
      return Json.text_to_blob(output.to_s) if binary
      session.result_subtype = Json::SUBTYPE
      output.to_s
    end

    # The -> and ->> operators' short paths: an integer is an array index
    # (negative counts from the end), a plain name an object key, "[..]"
    # stays as written, anything else a quoted key.
    private def self.abbreviated_path(path : String, value : Value) : String
      if value.is_a?(Int64)
        return "[#{path.starts_with?('-') ? "#" : ""}#{path}]"
      end
      if path.each_byte.all? { |byte| Json.alphanumeric?(byte) || byte == '_'.ord }
        return ".#{path}"
      end
      return path if path.starts_with?('[') && path.bytesize >= 3 && path.ends_with?(']')
      %(."#{path}")
    end

    # jsonTypeFunc.
    def self.type(arguments : Array(Value), session : Session) : Value
      document = Json.parse_argument(arguments[0], session.json_cache) || return
      index = 0
      if arguments.size == 2
        path = ValueSemantics.text(arguments[1]) || return
        raise Json.bad_path(path) unless path.starts_with?('$')
        index = document.lookup(0, Json::Bytes0.new(path.to_slice), 1)
        if index < 0
          return if index == Json::LOOKUP_NOTFOUND
          raise Json.bad_path(path) if index == Json::LOOKUP_PATHERROR
          raise Json.malformed
        end
      end
      Json::TYPE_NAMES[document.type_at(index)]? || ""
    end

    # jsonArrayLengthFunc.
    def self.array_length(arguments : Array(Value), session : Session) : Value
      document = Json.parse_argument(arguments[0], session.json_cache) || return
      index = 0
      if arguments.size == 2
        path = ValueSemantics.text(arguments[1]) || return
        lookup_path = path.starts_with?('$') ? path : "$@"
        index = document.lookup(0, Json::Bytes0.new(lookup_path.to_slice), 1)
        if index < 0
          return if index == Json::LOOKUP_NOTFOUND
          raise Json.bad_path(path) if index == Json::LOOKUP_PATHERROR
          raise Json.malformed
        end
      end
      document.type_at(index) == Json::ARRAY ? document.array_count(index).to_i64 : 0_i64
    end

    # jsonValidFunc.
    def self.valid(arguments : Array(Value), session : Session) : Value
      flags = 1_i64
      if arguments.size == 2
        given = ValueSemantics.integer_value(arguments[1])
        if given < 1 || given > 15
          raise SQLError.new("FLAGS parameter to json_valid() must be between 1 and 15")
        end
        flags = given & 0x0f
      end
      argument = arguments[0]
      return if argument.nil?
      if argument.is_a?(Bytes) && (document = Json.jsonb_argument(argument))
        return 1_i64 if (flags & 0x04) != 0
        return document.validity_check(0, document.size, 1) == 0 ? 1_i64 : 0_i64 if (flags & 0x08) != 0
        return 0_i64
      end
      return 0_i64 if (flags & 0x3) == 0
      document = Json.parse_argument?(argument, session.json_cache) || return 0_i64
      (flags & 0x02) != 0 || !document.non_standard? ? 1_i64 : 0_i64
    end

    # jsonErrorFunc: 0 for well-formed JSON, else the 1-based character
    # position of the first error.
    def self.error_position(argument : Value) : Value
      if argument.is_a?(Bytes) && (document = Json.jsonb_argument(argument))
        return document.validity_check(0, document.size, 1).to_i64
      end
      text = ValueSemantics.text(argument) || return
      parser = Json::Parser.new(text.to_slice)
      return 0_i64 if parser.convert
      position = 0_i64
      text.to_slice.each_with_index do |byte, index|
        break if index >= parser.error_at || byte == 0
        position += 1 if (byte & 0xc0) != 0x80
      end
      position + 1
    end
  end

  # json_each(JSON [, ROOT]) and json_tree(JSON [, ROOT]) as C's virtual
  # table cursor walks them (jsonEachFilter, jsonEachNext, jsonEachColumn):
  # key, value, type, atom, id, parent, fullkey, path, then the HIDDEN
  # columns json and root, then the cursor's rowid (jsonEachRowid: rows
  # counted from 0).
  class JsonEachProducer < Producer
    COLUMNS              = %w[key value type atom id parent fullkey path json root rowid]
    VISIBLE_COLUMN_COUNT =  8
    ROWID_COLUMN         = 10

    record Parent, head : Int32, value : Int32, finish : Int32, path_size : Int32, key : Int64

    @document : Json::Document? = nil
    @index = 0
    @finish = 0
    @root_size = 0
    @container_type = 0_u8
    @list_of_parents = [] of Parent
    @path = IO::Memory.new
    @row_number = 0

    def initialize(@list_of_arguments : Array(Expr), @recursive : Bool)
    end

    def open(frame : Frame) : Nil
      @document = nil
      @index = @finish = 0
      @list_of_parents.clear
      @path = IO::Memory.new
      @row_number = 0
      @container_type = 0_u8
      json_value = @list_of_arguments[0]?.try(&.evaluate(frame))
      root_value = @list_of_arguments[1]?.try(&.evaluate(frame))
      document = json_value.is_a?(Bytes) ? Json.jsonb_argument(json_value) : nil
      unless document
        text = ValueSemantics.text(json_value)
        return unless text
        parser = Json::Parser.new(text.to_slice)
        blob = parser.convert || raise Json.malformed
        document = Json::Document.new(blob, parser.non_standard?, text)
      end
      index = 0
      if @list_of_arguments.size >= 2
        root = ValueSemantics.text(root_value)
        return unless root
        raise Json.bad_path(root) unless root.starts_with?('$')
        @root_size = root.bytesize
        if root.bytesize > 1
          index = document.lookup(0, Json::Bytes0.new(root.to_slice), 1)
          if index < 0
            return if index == Json::LOOKUP_NOTFOUND
            raise Json.bad_path(root)
          end
          if document.label > 0
            @index = document.label
            @container_type = Json::OBJECT
          else
            @index = index
            @container_type = Json::ARRAY
          end
        end
        @path.write(root.to_slice)
      else
        @root_size = 1
        @path << '$'
      end
      @document = document
      header, size = document.payload_size(index)
      @finish = index + header + size
      if document.type_at(index) >= Json::ARRAY && !@recursive
        @index = index + header
        @container_type = document.type_at(index)
        @list_of_parents << Parent.new(@index, index, @finish, 0, 0_i64)
      end
    end

    def next_row(frame : Frame) : Array(Value)?
      document = @document || return
      return if @index >= @finish
      row = [key(document), value(document), type(document), atom(document), @index.to_i64, parent,
             full_key(document), String.new(@path.to_slice[0, path_length(document)]),
             document.source_text || document.blob, String.new(@path.to_slice[0, @root_size]), @row_number.to_i64] of Value
      advance(document)
      row
    end

    private def skip_label(document : Json::Document) : Int32
      return @index unless @container_type == Json::OBJECT
      header, size = document.payload_size(@index)
      @index + header + size
    end

    private def key(document : Json::Document) : Value
      if @list_of_parents.empty?
        return if @root_size == 1
        start = path_length(document)
        size = @root_size - start
        return if size <= 0
        path = @path.to_slice
        if path[start] == '['.ord
          return NumericText.atoi64(path[start + 1, size - 1]).value
        elsif path[start + 1]? == '"'.ord
          return String.new(path[start + 2, Math.max(size - 3, 0)])
        else
          return String.new(path[start + 1, size - 1])
        end
      end
      return document.sql_value(@index) if @container_type == Json::OBJECT
      @list_of_parents.last.key
    end

    private def value(document : Json::Document) : Value
      document.sql_value(skip_label(document))
    end

    private def type(document : Json::Document) : Value
      Json::TYPE_NAMES[document.type_at(skip_label(document))]? || ""
    end

    private def atom(document : Json::Document) : Value
      index = skip_label(document)
      document.type_at(index) < Json::ARRAY ? document.sql_value(index) : nil
    end

    private def parent : Value
      return unless @recursive
      @list_of_parents.last?.try(&.head.to_i64)
    end

    private def full_key(document : Json::Document) : Value
      base = @path.pos
      append_path_name(document) unless @list_of_parents.empty?
      text = String.new(@path.to_slice[0, @path.pos])
      @path.pos = base
      text
    end

    # The path is the bytes before the IO's position; later writes
    # overwrite what follows.
    private def truncate_path(size : Int64) : Nil
      @path.pos = size
    end

    # jsonAppendPathName: "[k]" in an array, ".name" or ."name" in an
    # object.
    private def append_path_name(document : Json::Document) : Nil
      if @container_type == Json::ARRAY
        @path << '[' << @list_of_parents.last.key << ']'
        return
      end
      header, size = document.payload_size(@index)
      label = document.blob[@index + header, size]
      quote = size == 0 || !Json.alpha?(label[0]) || !label.all? { |byte| Json.alphanumeric?(byte) }
      if quote
        @path << ".\""
        @path.write(label)
        @path << '"'
      else
        @path << '.'
        @path.write(label)
      end
    end

    # jsonEachPathLength: for json_tree's first row, the path of the root's
    # parent.
    private def path_length(document : Json::Document) : Int32
      n = @path.pos.to_i32
      path = @path.to_slice
      if @row_number == 0 && @recursive && n >= 2
        while n > 1
          n -= 1
          if path[n] == '['.ord || path[n] == '.'.ord
            prefix = path[0, n]
            found = document.lookup(0, Json::Bytes0.new(prefix), 1)
            next if found < 0
            header, _size = document.payload_size(found)
            break if found + header == @index
          end
        end
      end
      n
    end

    private def advance(document : Json::Document) : Nil
      if @recursive
        level_change = false
        index = skip_label(document)
        type = document.type_at(index)
        header, size = document.payload_size(index)
        if type == Json::OBJECT || type == Json::ARRAY
          level_change = true
          entry = Parent.new(@index, index, index + header + size, @path.pos.to_i32, -1_i64)
          append_path_name(document) if @container_type != 0 && !@list_of_parents.empty?
          @list_of_parents << entry
          @index = index + header
        else
          @index = index + header + size
        end
        while (last = @list_of_parents.last?) && @index >= last.finish
          @list_of_parents.pop
          truncate_path(last.path_size.to_i64)
          level_change = true
        end
        if level_change
          last = @list_of_parents.last?
          @container_type = last ? document.type_at(last.value) : 0_u8
        end
      else
        index = skip_label(document)
        header, size = document.payload_size(index)
        @index = index + header + size
      end
      if @container_type == Json::ARRAY && (last = @list_of_parents.last?)
        @list_of_parents[-1] = last.copy_with(key: last.key + 1)
      end
      @row_number += 1
    end
  end
end
