module Grant::SQLiteEngine::Query
  # The JSON functions of json.c (SQLite 3.51.0) that build or change JSON:
  # json_array, json_object and json_quote; json_set, json_insert,
  # json_replace, json_remove and json_patch; json_pretty; and the jsonb_
  # forms, which return the JSONB bytes C returns (jsonb, jsonb_array,
  # jsonb_object, jsonb_set, jsonb_insert, jsonb_replace, jsonb_remove,
  # jsonb_patch, jsonb_extract).
  module JsonWriteFunctions
    alias Definition = ScalarFunctions::Definition
    alias CallContext = ScalarFunctions::CallContext
    alias Edit = Json::Editor::Edit

    def self.list_of_definitions : Array(Definition)
      list = [
        define("json_quote", 1, 1, reads_subtypes: true) { |arguments, context| quote(arguments[0], subtype_of(context, 0), context.session) },
        define("json_patch", 2, 2) { |arguments, context| patch(arguments, false, context.session) },
        define("jsonb_patch", 2, 2) { |arguments, context| patch(arguments, true, context.session) },
        define("json_pretty", 1, 2) { |arguments, context| pretty(arguments, context.session) },
        define("jsonb", 1, 1) { |arguments, context| remove(arguments, true, context.session) },
        define("jsonb_extract", 0, -1) { |arguments, context| JsonFunctions.extract(arguments, JsonFunctions::ExtractMode::Extract, context.session, binary: true) },
      ]
      {false, true}.each do |binary|
        prefix = binary ? "jsonb" : "json"
        list << define("#{prefix}_array", 0, -1, reads_subtypes: true) { |arguments, context| array(arguments, context, binary) }
        list << define("#{prefix}_object", 0, -1, reads_subtypes: true) { |arguments, context| object(arguments, context, binary) }
        list << define("#{prefix}_set", 0, -1, reads_subtypes: true) { |arguments, context| insert_into(arguments, context, Edit::Set, "set", binary) }
        list << define("#{prefix}_insert", 0, -1, reads_subtypes: true) { |arguments, context| insert_into(arguments, context, Edit::Insert, "insert", binary) }
        list << define("#{prefix}_replace", 0, -1, reads_subtypes: true) { |arguments, context| insert_into(arguments, context, Edit::Replace, "replace", binary) }
        list << define("#{prefix}_remove", 0, -1) { |arguments, context| remove(arguments, binary, context.session) }
      end
      list
    end

    private def self.define(name : String, minimum : Int32, maximum : Int32, reads_subtypes : Bool = false,
                            &implementation : Array(Value), CallContext -> Value) : Definition
      Definition.new(name, minimum, maximum, implementation, reads_subtypes: reads_subtypes)
    end

    # sqlite3_value_subtype of argument *index*.
    private def self.subtype_of(context : CallContext, index : Int32) : UInt8
      list_of_subtypes = context.list_of_subtypes
      list_of_subtypes ? list_of_subtypes[index] : 0_u8
    end

    # Text a function built, as its result: JSON text with JSON_SUBTYPE, or
    # its JSONB (which C also marks with the subtype).
    private def self.built(output : Json::TextOutput, binary : Bool, session : Session) : Value
      Json.raise_error_of(output)
      session.result_subtype = Json::SUBTYPE
      binary ? Json.text_to_blob(output.to_s) : output.to_s
    end

    # jsonQuoteFunc.
    def self.quote(argument : Value, subtype : UInt8, session : Session) : Value
      output = Json::TextOutput.new
      Json.append_sql_value(output, argument, subtype)
      built(output, false, session)
    end

    # jsonArrayFunc.
    def self.array(arguments : Array(Value), context : CallContext, binary : Bool) : Value
      output = Json::TextOutput.new
      output.write_byte('['.ord.to_u8)
      arguments.each_with_index do |argument, index|
        output.separate
        Json.append_sql_value(output, argument, subtype_of(context, index))
      end
      output.write_byte(']'.ord.to_u8)
      built(output, binary, context.session)
    end

    # jsonObjectFunc.
    def self.object(arguments : Array(Value), context : CallContext, binary : Bool) : Value
      if arguments.size.odd?
        raise SQLError.new("json_object() requires an even number of arguments")
      end
      output = Json::TextOutput.new
      output.write_byte('{'.ord.to_u8)
      index = 0
      while index < arguments.size
        label = arguments[index]
        raise SQLError.new("json_object() labels must be TEXT") unless label.is_a?(String)
        output.separate
        Json.append_string(output, label.to_slice)
        output.write_byte(':'.ord.to_u8)
        Json.append_sql_value(output, arguments[index + 1], subtype_of(context, index + 1))
        index += 2
      end
      output.write_byte('}'.ord.to_u8)
      built(output, binary, context.session)
    end

    # jsonSetFunc and jsonReplaceFunc over jsonInsertIntoBlob: each PATH,
    # VALUE pair edits the JSON in turn.
    def self.insert_into(arguments : Array(Value), context : CallContext, edit : Edit, name : String, binary : Bool) : Value
      return if arguments.empty?
      raise SQLError.new("json_#{name}() needs an odd number of arguments") if arguments.size.even?
      session = context.session
      return remove(arguments, binary, session) if arguments.size == 1
      editor = Json.parse_editable_argument(arguments[0], session.json_cache) || return
      index = 1
      while index < arguments.size - 1
        path = Json.path_text(arguments[index])
        if path
          raise Json.bad_path(path) unless path.starts_with?('$')
          insertion = Json.sql_value_to_blob(arguments[index + 1], subtype_of(context, index + 1))
          code = 0
          if path.bytesize == 1
            editor.replace_all(insertion) unless edit.insert?
          else
            code = editor.apply(edit, Json::Bytes0.new(path.to_slice), insertion)
          end
          raise Json.malformed if code == Json::LOOKUP_ERROR
          raise Json.bad_path(path) if code == Json::LOOKUP_PATHERROR
        end
        index += 2
      end
      Json.return_edited(editor, binary, session)
    end

    # jsonRemoveFunc: json(X) and jsonb(X) with no path; with paths, the
    # JSON without the elements they name.
    def self.remove(arguments : Array(Value), binary : Bool, session : Session) : Value
      return if arguments.empty?
      if arguments.size == 1
        document = Json.parse_argument(arguments[0], session.json_cache) || return
        return document.blob if binary
        session.result_subtype = Json::SUBTYPE
        return document.text_at(0)
      end
      editor = Json.parse_editable_argument(arguments[0], session.json_cache) || return
      arguments.each(within: 1..) do |argument|
        path = Json.path_text(argument) || return
        raise Json.bad_path(path) unless path.starts_with?('$')
        return if path.bytesize == 1
        code = editor.apply(Edit::Delete, Json::Bytes0.new(path.to_slice))
        raise Json.bad_path(path) if code == Json::LOOKUP_PATHERROR
        raise Json.malformed if code == Json::LOOKUP_ERROR
      end
      Json.return_edited(editor, binary, session)
    end

    # jsonPatchFunc: RFC 7396 MergePatch of the second argument into the
    # first.
    def self.patch(arguments : Array(Value), binary : Bool, session : Session) : Value
      target = Json.parse_editable_argument(arguments[0], session.json_cache) || return
      patch = Json.parse_argument(arguments[1], session.json_cache) || return
      raise Json.malformed unless target.merge_patch(0, patch, 0)
      Json.return_edited(target, binary, session)
    end

    # jsonPrettyFunc: the JSON on indented lines; the indent is four spaces
    # unless the second argument gives another.
    def self.pretty(arguments : Array(Value), session : Session) : Value
      document = Json.parse_argument(arguments[0], session.json_cache) || return
      indent = (arguments.size == 2 ? Json.path_text(arguments[1]) : nil) || "    "
      output = Json::TextOutput.new
      pretty_text(document, 0, output, indent, 0)
      raise Json.malformed if output.malformed?
      output.to_s
    end

    # jsonTranslateBlobToPrettyText; returns the index after the element.
    private def self.pretty_text(document : Json::Document, index : Int32, output : Json::TextOutput, indent : String, depth : Int32) : Int32
      header, size = document.payload_size(index)
      if header == 0
        output.malformed = true
        return document.size + 1
      end
      type = document.type_at(index)
      return document.render(index, output) unless type == Json::ARRAY || type == Json::OBJECT
      at = index + header
      finish = at + size
      output.write_byte((type == Json::ARRAY ? '[' : '{').ord.to_u8)
      if at < finish
        output.write_byte('\n'.ord.to_u8)
        until output.malformed?
          (depth + 1).times { output.write(indent) }
          if type == Json::OBJECT
            at = document.render(at, output)
            if at > finish
              output.malformed = true
              break
            end
            output.write(": ")
          end
          at = pretty_text(document, at, output, indent, depth + 1)
          break if at >= finish
          output.write(",\n")
        end
        output.write_byte('\n'.ord.to_u8)
        depth.times { output.write(indent) }
      end
      output.write_byte((type == Json::ARRAY ? ']' : '}').ord.to_u8)
      finish
    end
  end

  # A call of a function that reads its arguments' subtypes
  # (sqlite3_value_subtype): json_array, json_object, json_quote, json_set
  # and the like embed text that came from a JSON function as JSON, and
  # other text as a string.
  class SubtypeReadingFunctionExpr < FunctionExpr
    def evaluate(frame : Frame) : Value
      value_with_subtype(frame)[0]
    end

    def value_with_subtype(frame : Frame) : {Value, UInt8}
      values = Array(Value).new(@arguments.size)
      list_of_subtypes = Array(UInt8).new(@arguments.size)
      @arguments.each do |argument|
        value, subtype = argument.value_with_subtype(frame)
        values << value
        list_of_subtypes << subtype
      end
      session = frame.session
      session.result_subtype = 0_u8
      value = @definition.implementation.call(values, ScalarFunctions::CallContext.new(@collation, session, list_of_subtypes))
      {value, value.nil? ? 0_u8 : session.result_subtype}
    end
  end
end
