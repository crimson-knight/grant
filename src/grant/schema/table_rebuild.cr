require "./constraint_definition"

module Grant::Schema
  # Rewrites a SQLite table, for the changes `ALTER TABLE` cannot make: adding
  # or removing a foreign key, check or unique constraint, changing a column,
  # dropping a column that an index or key uses.
  #
  # It follows SQLite's documented procedure. The `CREATE TABLE` text in
  # `sqlite_master` is split into its column and constraint items and edited
  # as text, so everything Grant does not model (collations, generated
  # columns, conflict clauses) survives. Then the statements create the new
  # table, copy the rows, drop the old table, rename the new one and recreate
  # the indexes.
  #
  # Cost: the rewrite copies every row under a write lock, and dropping
  # indexes that mention a removed column means they are not recreated.
  # Triggers and views on the table are not recreated.
  #
  # ```
  # rebuild = Grant::Schema::TableRebuild.new("posts", create_sql, index_sqls)
  # rebuild.remove_column("score")
  # rebuild.statements # => ["PRAGMA foreign_keys = OFF", "BEGIN", ...]
  # ```
  class TableRebuild
    # One comma-separated item of the `CREATE TABLE` body.
    class Item
      getter kind : Symbol
      property name : ::String?
      property text : ::String

      # The item name, or an empty string for unnamed items. Column items always carry a name.
      def name_or_empty : ::String
        @name || ""
      end

      def initialize(@kind : Symbol, @name : ::String?, @text : ::String)
      end
    end

    getter table : ::String
    getter items : Array(Item)
    getter removed_columns = [] of ::String
    @suffix : ::String
    @original_columns : Array(::String)

    def initialize(@table : ::String, create_sql : ::String, @index_sqls : Array(::String) = [] of ::String)
      open = create_sql.index('(') || raise InvalidDefinition.new("Cannot read the definition of '#{@table}'")
      close = Scanner.matching_paren(create_sql, open) || raise InvalidDefinition.new("Cannot read the definition of '#{@table}'")
      @suffix = create_sql[(close + 1)..].strip
      @items = Scanner.split_items(create_sql[(open + 1)...close]).map { |text| classify(text) }
      @original_columns = column_items.map { |item| item.name_or_empty.downcase }
    end

    # Names of the column items, in order.
    def column_names : Array(::String)
      column_items.map { |item| item.name_or_empty }
    end

    def add_column(text : ::String) : Nil
      item = classify(text)
      raise InvalidDefinition.new("Column '#{item.name}' already exists in '#{@table}'") if find_column(item.name_or_empty)
      # Columns go before the table-level constraints.
      position = @items.index { |existing| existing.kind != :column } || @items.size
      @items.insert(position, item)
    end

    def remove_column(name : ::String) : Nil
      item = find_column(name) || raise InvalidDefinition.new("Column '#{name}' does not exist in '#{@table}'")
      @items.delete(item)
      @removed_columns << name
      @items.reject! do |other|
        next false if other.kind == :column
        next false unless Scanner.mentions?(other.text, name)
        if other.kind == :primary_key
          raise InvalidDefinition.new("Cannot remove '#{name}': it is part of the primary key of '#{@table}'")
        end
        true
      end
    end

    # Replaces the definition of column *name*; *block* gets the old text and
    # returns the new one.
    def change_column(name : ::String, & : ::String -> ::String) : Nil
      item = find_column(name) || raise InvalidDefinition.new("Column '#{name}' does not exist in '#{@table}'")
      item.text = yield item.text
      item.name = name
    end

    def add_constraint(text : ::String) : Nil
      @items << classify(text)
    end

    # Removes foreign keys matching *name*, or matching *columns*, including
    # `REFERENCES` clauses written on a column. Returns how many were removed.
    def remove_foreign_key(name : ::String? = nil, columns : Array(::String)? = nil) : Int32
      removed = 0
      @items.reject! do |item|
        next false unless item.kind == :foreign_key
        next false unless (name && item.name.try(&.downcase) == name.downcase) || (columns && Scanner.fk_columns(item.text) == columns.map(&.downcase))
        removed += 1
        true
      end
      if removed == 0 && (wanted = columns) && wanted.size == 1 && name.nil?
        column_items.each do |item|
          next unless item.name_or_empty.downcase == wanted.first.downcase
          stripped = Scanner.strip_references(item.text)
          if stripped != item.text
            item.text = stripped
            removed += 1
          end
        end
      end
      removed
    end

    def remove_check(name : ::String? = nil, expression : ::String? = nil) : Int32
      removed = 0
      @items.reject! do |item|
        next false unless item.kind == :check
        by_name = name && item.name.try(&.downcase) == name.downcase
        by_expression = expression && Scanner.normalize(Scanner.check_expression(item.text)) == Scanner.normalize(expression)
        next false unless by_name || by_expression
        removed += 1
        true
      end
      removed
    end

    def remove_unique(name : ::String? = nil, columns : Array(::String)? = nil) : Int32
      removed = 0
      @items.reject! do |item|
        next false unless item.kind == :unique
        by_name = name && item.name.try(&.downcase) == name.downcase
        by_columns = columns && Scanner.fk_columns(item.text) == columns.map(&.downcase)
        next false unless by_name || by_columns
        removed += 1
        true
      end
      removed
    end

    # The statements that rebuild the table, to run on one connection.
    # The first and last are `PRAGMA foreign_keys` and must always run.
    def statements : Array(::String)
      dialect = Dialect::Sqlite
      scratch = "__grant_rebuild_#{@table}"
      kept = column_names.map(&.downcase) & @original_columns
      quoted = kept.map { |column| dialect.quote(column_case(column)) }.join(", ")
      body = @items.map(&.text).join(",\n  ")
      create = "CREATE TABLE #{dialect.quote(scratch)} (\n  #{body}\n)"
      create += " #{@suffix}" unless @suffix.empty?
      result = [
        "PRAGMA foreign_keys = OFF",
        "BEGIN",
        create,
        "INSERT INTO #{dialect.quote(scratch)} (#{quoted}) SELECT #{quoted} FROM #{dialect.quote(@table)}",
        "DROP TABLE #{dialect.quote(@table)}",
        "ALTER TABLE #{dialect.quote(scratch)} RENAME TO #{dialect.quote(@table)}",
      ]
      @index_sqls.each do |sql|
        next if @removed_columns.any? { |column| Scanner.mentions?(sql, column) }
        result << sql
      end
      result << "COMMIT"
      result << "PRAGMA foreign_keys = ON"
      result
    end

    private def column_case(lowered : ::String) : ::String
      column_names.find { |name| name.downcase == lowered } || lowered
    end

    private def column_items : Array(Item)
      @items.select { |item| item.kind == :column }
    end

    private def find_column(name : ::String) : Item?
      column_items.find { |item| item.name_or_empty.downcase == name.downcase }
    end

    private def classify(text : ::String) : Item
      stripped = text.strip
      if match = stripped.match(/\A(?:CONSTRAINT\s+("(?:[^"]|"")+"|`[^`]+`|\[[^\]]+\]|\w+)\s+)?(PRIMARY\s+KEY|FOREIGN\s+KEY|CHECK|UNIQUE)\b/i)
        kind = case match[2].upcase.gsub(/\s+/, " ")
               when "PRIMARY KEY" then :primary_key
               when "FOREIGN KEY" then :foreign_key
               when "CHECK"       then :check
               else                    :unique
               end
        Item.new(kind, match[1]?.try { |name| Scanner.unquote(name) }, stripped)
      else
        Item.new(:column, Scanner.unquote(stripped[/\A("(?:[^"]|"")+"|`[^`]+`|\[[^\]]+\]|'[^']+'|[^\s]+)/]), stripped)
      end
    end

    # Text scanning helpers that respect quotes and nested parentheses.
    module Scanner
      def self.unquote(token : ::String) : ::String
        case token[0]?
        when '"'  then token[1...-1].gsub("\"\"", "\"")
        when '`'  then token[1...-1]
        when '['  then token[1...-1]
        when '\'' then token[1...-1]
        else           token
        end
      end

      # The index of the `)` that closes the `(` at *open*.
      def self.matching_paren(text : ::String, open : Int32) : Int32?
        depth = 0
        quote = nil.as(Char?)
        index = open
        while index < text.size
          char = text[index]
          if q = quote
            quote = nil if char == q || (q == '[' && char == ']')
          elsif char == '"' || char == '\'' || char == '`'
            quote = char
          elsif char == '['
            quote = '['
          elsif char == '('
            depth += 1
          elsif char == ')'
            depth -= 1
            return index if depth == 0
          end
          index += 1
        end
        nil
      end

      # Splits *body* at the commas that are not nested or quoted.
      def self.split_items(body : ::String) : Array(::String)
        items = [] of ::String
        depth = 0
        quote = nil.as(Char?)
        start = 0
        body.each_char_with_index do |char, index|
          if q = quote
            quote = nil if char == q || (q == '[' && char == ']')
          elsif char == '"' || char == '\'' || char == '`'
            quote = char
          elsif char == '['
            quote = '['
          elsif char == '('
            depth += 1
          elsif char == ')'
            depth -= 1
          elsif char == ',' && depth == 0
            items << body[start...index].strip
            start = index + 1
          end
        end
        last = body[start..].strip
        items << last unless last.empty?
        items
      end

      # True when *text* uses *name* as an identifier.
      def self.mentions?(text : ::String, name : ::String) : Bool
        escaped = Regex.escape(name)
        text.matches?(/(?<![\w])["`\[]?#{escaped}["`\]]?(?![\w])/i)
      end

      # Lowercase column names inside the first parenthesis pair of a
      # `FOREIGN KEY (...)` or `UNIQUE (...)` item.
      def self.fk_columns(text : ::String) : Array(::String)
        open = text.index('(') || return [] of ::String
        close = matching_paren(text, open) || return [] of ::String
        text[(open + 1)...close].split(',').map { |part| unquote(part.strip).downcase }
      end

      def self.check_expression(text : ::String) : ::String
        open = text.index('(') || return text
        close = matching_paren(text, open) || return text
        text[(open + 1)...close]
      end

      def self.normalize(expression : ::String) : ::String
        trimmed = expression.strip
        while trimmed.starts_with?('(') && matching_paren(trimmed, 0) == trimmed.size - 1
          trimmed = trimmed[1...-1].strip
        end
        trimmed.gsub(/\s+/, " ").downcase
      end

      def self.strip_references(text : ::String) : ::String
        text.sub(/\s+REFERENCES\s+(?:"(?:[^"]|"")+"|`[^`]+`|\w+)(?:\s*\([^)]*\))?(?:\s+ON\s+(?:DELETE|UPDATE)\s+(?:SET\s+NULL|SET\s+DEFAULT|CASCADE|RESTRICT|NO\s+ACTION))*(?:\s+(?:NOT\s+)?DEFERRABLE(?:\s+INITIALLY\s+(?:DEFERRED|IMMEDIATE))?)?/i, "")
      end

      # The `DEFAULT ...` clause of a column item, or nil.
      def self.default_clause(text : ::String) : ::String?
        match = text.match(/\sDEFAULT\s+/i) || return nil
        start = match.begin(0)
        index = match.end(0)
        return nil if index >= text.size
        char = text[index]
        stop = if char == '('
                 (matching_paren(text, index) || return nil) + 1
               elsif char == '\'' || char == '"'
                 close = text.index(char, index + 1) || return nil
                 close + 1
               else
                 rest = text[index..]
                 index + (rest.index(/[\s,]/) || rest.size)
               end
        text[start...stop].strip
      end
    end
  end
end
