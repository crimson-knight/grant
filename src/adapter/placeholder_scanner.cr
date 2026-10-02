# Single-pass rewriter for the `?` placeholders in a raw SQL fragment.
#
# A `?` inside a quoted string, quoted identifier, dollar-quoted body or
# comment is data and is left alone. `??` is the escape for a literal `?`
# outside those regions (for example PostgreSQL's JSONB existence operator).
# Everything else is copied through untouched, so PostgreSQL `::` casts and
# already numbered `$n` placeholders are unaffected.
module Grant::Adapter::PlaceholderScanner
  private QUOTE        = '\''.ord.to_u8
  private DOUBLE_QUOTE = '"'.ord.to_u8
  private QUESTION     = '?'.ord.to_u8
  private DASH         = '-'.ord.to_u8
  private SLASH        = '/'.ord.to_u8
  private STAR         = '*'.ord.to_u8
  private DOLLAR       = '$'.ord.to_u8
  private BACKSLASH    = '\\'.ord.to_u8
  private NEWLINE      = '\n'.ord.to_u8
  private UPPER_E      = 'E'.ord.to_u8
  private LOWER_E      = 'e'.ord.to_u8

  # Rewrites *clause*. With `numbered` true each placeholder becomes `$n`,
  # counting from *starting_index* + 1; otherwise placeholders stay `?` and
  # only `??` collapses to a literal `?`.
  def self.rewrite(clause : String, starting_index : Int32 = 0, numbered : Bool = true) : String
    return clause unless clause.includes?('?')
    return clause if !numbered && !clause.includes?("??")

    bytes = clause.to_slice
    size = bytes.size
    count = starting_index
    copied_to = 0
    index = 0

    result = String.build(size + 8) do |io|
      while index < size
        byte = bytes[index]
        case byte
        when QUOTE
          backslash_escapes = index > 0 && (bytes[index - 1] == UPPER_E || bytes[index - 1] == LOWER_E) &&
                              (index == 1 || !identifier_byte?(bytes[index - 2]))
          index = skip_quoted(bytes, index, QUOTE, backslash_escapes)
        when DOUBLE_QUOTE
          index = skip_quoted(bytes, index, DOUBLE_QUOTE, false)
        when DASH
          if index + 1 < size && bytes[index + 1] == DASH
            index += 2
            while index < size && bytes[index] != NEWLINE
              index += 1
            end
          else
            index += 1
          end
        when SLASH
          if index + 1 < size && bytes[index + 1] == STAR
            index = skip_block_comment(bytes, index)
          else
            index += 1
          end
        when DOLLAR
          index = skip_dollar_quoted(bytes, index)
        when QUESTION
          io.write(bytes[copied_to, index - copied_to])
          if index + 1 < size && bytes[index + 1] == QUESTION
            io << '?'
            index += 2
          else
            if numbered
              count += 1
              io << '$' << count
            else
              io << '?'
            end
            index += 1
          end
          copied_to = index
        else
          index += 1
        end
      end
      io.write(bytes[copied_to, size - copied_to])
    end

    result
  end

  private def self.identifier_byte?(byte : UInt8) : Bool
    (byte >= 'a'.ord && byte <= 'z'.ord) || (byte >= 'A'.ord && byte <= 'Z'.ord) ||
      (byte >= '0'.ord && byte <= '9'.ord) || byte == '_'.ord
  end

  # Returns the index just past the literal that opens at *start*. A doubled
  # delimiter stays inside the literal.
  private def self.skip_quoted(bytes : Bytes, start : Int32, delimiter : UInt8, backslash_escapes : Bool) : Int32
    index = start + 1
    size = bytes.size
    while index < size
      byte = bytes[index]
      if backslash_escapes && byte == BACKSLASH
        index += 2
      elsif byte == delimiter
        if index + 1 < size && bytes[index + 1] == delimiter
          index += 2
        else
          return index + 1
        end
      else
        index += 1
      end
    end
    size
  end

  private def self.skip_block_comment(bytes : Bytes, start : Int32) : Int32
    index = start + 2
    size = bytes.size
    depth = 1
    while index < size && depth > 0
      if bytes[index] == SLASH && index + 1 < size && bytes[index + 1] == STAR
        depth += 1
        index += 2
      elsif bytes[index] == STAR && index + 1 < size && bytes[index + 1] == SLASH
        depth -= 1
        index += 2
      else
        index += 1
      end
    end
    index
  end

  # A `$tag$ ... $tag$` body (the tag may be empty). `$1` is a parameter, not a
  # tag, because a tag cannot start with a digit.
  private def self.skip_dollar_quoted(bytes : Bytes, start : Int32) : Int32
    size = bytes.size
    tag_end = start + 1
    if tag_end < size && (identifier_byte?(bytes[tag_end]) && !(bytes[tag_end] >= '0'.ord && bytes[tag_end] <= '9'.ord))
      while tag_end < size && identifier_byte?(bytes[tag_end])
        tag_end += 1
      end
    end
    return start + 1 unless tag_end < size && bytes[tag_end] == DOLLAR

    tag = bytes[start, tag_end - start + 1]
    index = tag_end + 1
    while index + tag.size <= size
      return index + tag.size if bytes[index, tag.size] == tag
      index += 1
    end
    size
  end
end
