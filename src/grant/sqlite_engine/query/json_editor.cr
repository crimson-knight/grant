module Grant::SQLiteEngine::Query
  module Json
    # A JSONB value being edited in place, as json.c edits a JsonParse:
    # json_set, json_insert, json_replace and json_remove walk a path and
    # change the bytes there (jsonLookupStep with eEdit), json_patch merges
    # a patch into it (jsonMergePatch). The bytes that result are C's,
    # including the padded headers jsonBlobOverwrite writes when a value
    # shrinks by a few bytes.
    class Editor
      # JEDIT_DEL, JEDIT_REPL, JEDIT_INS and JEDIT_SET.
      enum Edit
        None
        Delete
        Replace
        Insert
        Set

        # eEdit >= JEDIT_INS: a missing element is created.
        def creates? : Bool
          insert? || set?
        end
      end

      getter size : Int32
      getter? non_standard : Bool
      # The bytes the last edits added (negative: removed) that enclosing
      # containers have not yet counted (JsonParse.delta).
      property delta = 0

      @bytes : Bytes
      @edit = Edit::None
      @insertion = Bytes.empty

      def initialize(source : Bytes, @non_standard : Bool = false)
        @bytes = Bytes.new(source.size + 64)
        source.copy_to(@bytes)
        @size = source.size
      end

      def to_bytes : Bytes
        @bytes[0, @size].dup
      end

      # One edit of the element *path* names (the path after its "$"):
      # the index found, or a Json::LOOKUP_ code.
      def apply(edit : Edit, path : Bytes0, insertion : Bytes = Bytes.empty) : Int32
        @edit = edit
        @insertion = insertion
        @delta = 0
        lookup(0, path, 1, 0)
      end

      # Replaces the whole value (json_set and json_replace at "$").
      def replace_all(insertion : Bytes) : Nil
        edit(0, @size, insertion, insertion.size)
      end

      private def payload_size(index : Int32) : {Int32, Int32}
        Json.payload_size(@bytes, index, @size, @delta)
      end

      private def type_at(index : Int32) : UInt8
        index < @bytes.size ? @bytes[index] & 0x0f : 0_u8
      end

      private def reserve(size : Int32) : Nil
        return if size <= @bytes.size
        larger = Bytes.new(Math.max(size + 64, @bytes.size * 2))
        @bytes[0, @size].copy_to(larger)
        @bytes = larger
      end

      # jsonBlobEdit: removes *delete_count* bytes at *at* and puts
      # *insert_count* bytes there, from *insertion* or left for the caller
      # to fill.
      private def edit(at : Int32, delete_count : Int32, insertion : Bytes?, insert_count : Int32) : Nil
        difference = insert_count - delete_count
        if difference < 0 && difference >= -8 && insertion && overwrite?(at, insertion[0, insert_count], -difference)
          return
        end
        if difference != 0
          reserve(@size + difference)
          tail = @size - (at + delete_count)
          @bytes[at + insert_count, tail].move_from(@bytes[at + delete_count, tail])
          @size += difference
          @delta += difference
        end
        if insertion && insert_count > 0
          insertion[0, insert_count].copy_to(@bytes[at, insert_count])
        end
      end

      # jsonBlobOverwrite: writes *insertion* with its size header widened
      # by *extra* bytes, so the value keeps the room of the one it
      # replaces. False when no header form is that much larger.
      private def overwrite?(at : Int32, insertion : Bytes, extra : Int32) : Bool
        first = insertion[0]
        return false if (first & 0x0f) <= FALSE
        case first >> 4
        when 12
          return false unless extra == 1 || extra == 3 || extra == 7
          new_header = extra + 2
          old_header = 2
        when 13
          return false unless extra == 2 || extra == 6
          new_header = extra + 3
          old_header = 3
        when 14
          return false unless extra == 4
          new_header = 9
          old_header = 5
        when 15
          return false
        else
          return false unless extra == 1 || extra == 2 || extra == 4 || extra == 8
          new_header = extra + 1
          old_header = 1
        end
        size_code = case new_header
                    when 2 then 0xc0_u8
                    when 3 then 0xd0_u8
                    when 5 then 0xe0_u8
                    else        0xf0_u8
                    end
        payload = insertion.size - old_header
        @bytes[at] = (first & 0x0f) | size_code
        insertion[old_header, payload].copy_to(@bytes[at + new_header, payload])
        remaining = payload.to_u32
        index = new_header
        loop do
          index -= 1
          @bytes[at + index] = (remaining & 0xff).to_u8
          break if index == 1
          remaining >>= 8
        end
        true
      end

      # jsonAfterEditSizeAdjust: counts the pending size change into the
      # container at *root*.
      private def after_edit_size_adjust(root : Int32) : Nil
        _header, size = Json.payload_size(@bytes, root, @bytes.size, @delta)
        @delta += change_payload_size(root, size + @delta)
      end

      # jsonBlobChangePayloadSize: rewrites the header at *index* for
      # *payload* bytes; returns the change in header size.
      private def change_payload_size(index : Int32, payload : Int32) : Int32
        extra = Json.header_size_of(@bytes[index]) - 1
        extra = 8 if extra > 4
        needed = if payload <= 11
                   0
                 elsif payload <= 0xff
                   1
                 elsif payload <= 0xffff
                   2
                 else
                   4
                 end
        difference = needed - extra
        if difference != 0
          reserve(@size + difference) if difference > 0
          tail = @size - (index + 1 + extra)
          @bytes[index + 1 + needed, tail].move_from(@bytes[index + 1 + extra, tail])
          @size += difference
        end
        type = @bytes[index] & 0x0f
        case needed
        when 0
          @bytes[index] = type | (payload << 4).to_u8!
        when 1
          @bytes[index] = type | 0xc0_u8
          @bytes[index + 1] = payload.to_u8!
        when 2
          @bytes[index] = type | 0xd0_u8
          @bytes[index + 1] = (payload >> 8).to_u8!
          @bytes[index + 2] = payload.to_u8!
        else
          @bytes[index] = type | 0xe0_u8
          @bytes[index + 1] = (payload >> 24).to_u8!
          @bytes[index + 2] = (payload >> 16).to_u8!
          @bytes[index + 3] = (payload >> 8).to_u8!
          @bytes[index + 4] = payload.to_u8!
        end
        difference
      end

      # jsonCreateEditSubstructure: what to insert for a path that goes on
      # past a missing element: the value itself at the path's end, else
      # new containers down to it. The lookup code and the bytes.
      private def create_edit_substructure(path : Bytes0, at : Int32) : {Int32, Bytes}
        return {0, @insertion} if path[at] == 0
        substructure = Editor.new(Bytes[path[at] == '.'.ord ? OBJECT : ARRAY])
        code = substructure.apply_from(@edit, path, at, @insertion)
        {code, substructure.to_bytes}
      end

      protected def apply_from(edit : Edit, path : Bytes0, at : Int32, insertion : Bytes) : Int32
        @edit = edit
        @insertion = insertion
        lookup(0, path, at, 0)
      end

      # jsonLookupStep with eEdit set.
      private def lookup(root : Int32, path : Bytes0, at : Int32, label : Int32) : Int32
        if path[at] == 0
          header, size = payload_size(root)
          size += header
          if @edit.delete?
            if label > 0
              size += root - label
              root = label
            end
            edit(root, size, nil, 0)
          elsif @edit.replace? || @edit.set?
            edit(root, size, @insertion, @insertion.size)
          end
          return root
        end
        if path[at] == '.'.ord
          raw_key = true
          root_type = type_at(root)
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
            raw_key = !path.bytes[key_start, key_size].includes?('\\'.ord.to_u8)
          else
            key_start = at
            i = 0
            while path[at + i] != 0 && path[at + i] != '.'.ord && path[at + i] != '['.ord
              i += 1
            end
            key_size = i
            return LOOKUP_PATHERROR if key_size == 0
          end
          return LOOKUP_NOTFOUND unless root_type == OBJECT
          header, size = payload_size(root)
          j = root + header
          finish = j + size
          key = path.bytes[key_start, key_size]
          while j < finish
            label_type = type_at(j)
            return LOOKUP_ERROR if label_type < TEXT || label_type > TEXTRAW
            header, size = payload_size(j)
            return LOOKUP_ERROR if header == 0
            k = j + header
            return LOOKUP_ERROR if k + size >= finish
            raw_label = label_type == TEXT || label_type == TEXTRAW
            if Json.labels_equal?(key, raw_key, @bytes[k, size], raw_label)
              value = k + size
              return LOOKUP_ERROR if type_at(value) > OBJECT
              header, size = payload_size(value)
              return LOOKUP_ERROR if header == 0 || value + header + size > finish
              code = lookup(value, path, at + i, j)
              after_edit_size_adjust(root) if @delta != 0
              return code
            end
            j = k + size
            return LOOKUP_ERROR if type_at(j) > OBJECT
            header, size = payload_size(j)
            return LOOKUP_ERROR if header == 0
            j += header + size
          end
          return LOOKUP_ERROR if j > finish
          if @edit.creates?
            list_of_header_bytes = Json.header(raw_key ? TEXTRAW : TEXT5, key_size)
            code, value_bytes = create_edit_substructure(path, at + i)
            if code >= 0
              edit(j, 0, nil, list_of_header_bytes.size + key_size + value_bytes.size)
              list_of_header_bytes.each_with_index { |byte, index| @bytes[j + index] = byte }
              k = j + list_of_header_bytes.size
              key.copy_to(@bytes[k, key_size])
              value_bytes.copy_to(@bytes[k + key_size, value_bytes.size])
              after_edit_size_adjust(root) if @delta != 0
            end
            return code
          end
        elsif path[at] == '['.ord
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
            k = array_count(root)
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
            if k == 0
              code = lookup(j, path, at + i + 1, 0)
              after_edit_size_adjust(root) if @delta != 0
              return code
            end
            k -= 1
            header, size = payload_size(j)
            return LOOKUP_ERROR if header == 0
            j += header + size
          end
          return LOOKUP_ERROR if j > finish
          return LOOKUP_NOTFOUND if k > 0
          if @edit.creates?
            code, value_bytes = create_edit_substructure(path, at + i + 1)
            edit(j, 0, value_bytes, value_bytes.size) if code >= 0
            after_edit_size_adjust(root) if @delta != 0
            return code
          end
        else
          return LOOKUP_PATHERROR
        end
        LOOKUP_NOTFOUND
      end

      # jsonbArrayCount.
      private def array_count(root : Int32) : UInt32
        header, size = payload_size(root)
        finish = root + header + size
        count = 0_u32
        index = root + header
        while header > 0 && index < finish
          header, size = payload_size(index)
          index += size + header
          count += 1
        end
        count
      end

      # jsonMergePatch (RFC 7396): merges the element at *patch_at* of
      # *patch* into the element at *target*. False when either is
      # malformed JSONB.
      def merge_patch(target : Int32, patch : Document, patch_at : Int32) : Bool
        if patch.type_at(patch_at) != OBJECT
          header, size = patch.payload_size(patch_at)
          patch_size = header + size
          header, size = payload_size(target)
          edit(target, header + size, patch.blob[patch_at, patch_size], patch_size)
          return true
        end
        if type_at(target) != OBJECT
          header, size = payload_size(target)
          edit(target + header, size, nil, 0)
          @bytes[target] = (@bytes[target] & 0xf0) | OBJECT
        end
        header, size = patch.payload_size(patch_at)
        return false if header == 0
        patch_cursor = patch_at + header
        patch_end = patch_cursor + size
        header, size = payload_size(target)
        return false if header == 0
        target_start = target + header
        target_end_before = target_start + size

        while patch_cursor < patch_end
          patch_label = patch_cursor
          patch_label_type = patch.type_at(patch_cursor)
          return false if patch_label_type < TEXT || patch_label_type > TEXTRAW
          patch_label_header, patch_label_size = patch.payload_size(patch_cursor)
          return false if patch_label_header == 0
          patch_value = patch_cursor + patch_label_header + patch_label_size
          return false if patch_value >= patch_end
          patch_value_header, patch_value_size = patch.payload_size(patch_value)
          return false if patch_value_header == 0
          patch_cursor = patch_value + patch_value_header + patch_value_size
          return false if patch_cursor > patch_end

          target_cursor = target_start
          target_end = target_end_before + @delta
          target_label = 0
          target_label_header = 0
          target_label_size = 0
          target_value = 0
          target_value_header = 0
          target_value_size = 0
          while target_cursor < target_end
            target_label = target_cursor
            target_label_type = type_at(target_cursor)
            return false if target_label_type < TEXT || target_label_type > TEXTRAW
            target_label_header, target_label_size = payload_size(target_cursor)
            return false if target_label_header == 0
            target_value = target_label + target_label_header + target_label_size
            return false if target_value >= target_end
            target_value_header, target_value_size = payload_size(target_value)
            return false if target_value_header == 0
            return false if target_value + target_value_header + target_value_size > target_end
            same = Json.labels_equal?(
              patch.blob[patch_label + patch_label_header, patch_label_size],
              patch_label_type == TEXT || patch_label_type == TEXTRAW,
              @bytes[target_label + target_label_header, target_label_size],
              target_label_type == TEXT || target_label_type == TEXTRAW)
            break if same
            target_cursor = target_value + target_value_header + target_value_size
          end
          patch_value_type = patch.type_at(patch_value)
          if target_cursor < target_end
            if patch_value_type == NULL
              edit(target_label, target_label_header + target_label_size + target_value_header + target_value_size, nil, 0)
            else
              saved_delta = @delta
              @delta = 0
              return false unless merge_patch(target_value, patch, patch_value)
              @delta += saved_delta
            end
          elsif patch_value_type > NULL
            label_bytes = patch_label_size + patch_label_header
            if patch_value_type != OBJECT
              value_bytes = patch_value_size + patch_value_header
              edit(target_end, 0, nil, value_bytes + label_bytes)
              patch.blob[patch_label, label_bytes].copy_to(@bytes[target_end, label_bytes])
              patch.blob[patch_value, value_bytes].copy_to(@bytes[target_end + label_bytes, value_bytes])
            else
              edit(target_end, 0, nil, label_bytes + 1)
              patch.blob[patch_label, label_bytes].copy_to(@bytes[target_end, label_bytes])
              @bytes[target_end + label_bytes] = NULL
              saved_delta = @delta
              @delta = 0
              return false unless merge_patch(target_end + label_bytes, patch, patch_value)
              @delta += saved_delta
            end
          end
        end
        after_edit_size_adjust(target) if @delta != 0
        true
      end
    end
  end
end
