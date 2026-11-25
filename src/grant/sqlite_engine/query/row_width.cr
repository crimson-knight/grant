module Grant::SQLiteEngine::Query
  # C's row size estimates (estimateTableWidth, estimateIndexWidth), which
  # weigh an index scan's cost by how wide its entries are next to the
  # table's rows: rCostIdx = nOut + 1 + (15 * szIdxRow) / szTabRow.
  module RowWidth
    STANDARD_TYPES = {"ANY" => 1, "BLOB" => 5, "INT" => 1, "INTEGER" => 1, "REAL" => 1, "TEXT" => 5}

    # The 15 * szIdxRow / szTabRow term of an index scan's cost.
    def self.index_scan_weight(table : TableInfo, layout : IndexLayout) : Int32
      sizes = table.definition.list_of_columns.map { |column| column_size(column.declared_type) }
      table_width = sizes.sum
      table_width += 1 unless table.rowid_alias
      index_width = 0
      (layout.list_of_key_positions + layout.list_of_tail_positions).each do |position|
        index_width += position >= 0 && position < sizes.size ? sizes[position] : 1
      end
      index_width += 1 unless table.without_rowid?
      (15 * log_est(index_width.to_u64 * 4)) // log_est(table_width.to_u64 * 4)
    end

    # Column.szEst from the declared type (sqlite3AddColumn,
    # sqlite3AffinityType): 1 for about four bytes.
    def self.column_size(declared : String) : Int32
      type = declared.strip
      return 1 if type.empty?
      if type.size >= 3 && (standard = STANDARD_TYPES[SQL::Parser.dequote(type).upcase]?)
        return standard
      end
      lower = type.downcase
      hash = 0_u32
      text_or_blob = false
      numeric_or_real = true
      size_text = nil.as(String?)
      lower.each_char_with_index do |char, index|
        hash = (hash << 8) &+ char.ord.to_u32!
        rest = lower[(index + 1)..]
        if hash == 0x63686172_u32 # char
          text_or_blob = true
          numeric_or_real = false
          size_text = rest
        elsif hash == 0x636c6f62_u32 || hash == 0x74657874_u32 # clob, text
          text_or_blob = true
          numeric_or_real = false
        elsif hash == 0x626c6f62_u32 && numeric_or_real # blob
          text_or_blob = true
          numeric_or_real = false
          size_text = rest if rest.starts_with?('(')
        elsif (hash & 0x00FFFFFF_u32) == 0x00696e74_u32 # int
          text_or_blob = false
          break
        end
      end
      return 1 unless text_or_blob
      value = 16
      if digits = size_text
        number = TextScan.first_digits(digits)
        value = number ? (number.to_i? || 0) : 0
      end
      Math.min(value // 4 + 1, 255)
    end

    # sqlite3LogEst: about 10 * log2(x).
    def self.log_est(x : UInt64) : Int32
      steps = [0, 2, 3, 5, 6, 7, 8, 9]
      y = 40
      if x < 8
        return 0 if x < 2
        while x < 8
          y -= 10
          x <<= 1
        end
      else
        while x > 255
          y += 40
          x >>= 4
        end
        while x > 15
          y += 10
          x >>= 1
        end
      end
      steps[x & 7] + y - 10
    end
  end
end
