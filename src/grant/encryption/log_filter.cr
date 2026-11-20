module Grant::Encryption
  # Redacts bound values of encrypted and filtered columns from the SQL log,
  # so plaintext never reaches log output through a `WHERE email = ?` bind.
  #
  # The columns to redact are the storage columns of every encrypted attribute
  # plus any column matched by `Grant.settings.filter_attributes` or a model's
  # `filter_attributes`. The set is built per model when the model declares its
  # first `encrypts` and merged into one lookup, so logging does one hash
  # probe per bound column. The work happens inside the log block, which
  # Crystal only runs when the level is enabled.
  module LogFilter
    REDACTED = "[FILTERED]"

    @@models = [] of Grant::Base.class
    @@columns = Set(String).new
    @@global_signature = 0_u64
    @@stale = true
    @@mutex = Mutex.new

    # Registers *model* so its encrypted and filtered columns are redacted.
    def self.track(model : Grant::Base.class) : Nil
      @@mutex.synchronize do
        @@models << model unless @@models.includes?(model)
        @@stale = true
      end
    end

    # Whether values bound to column *name* are redacted.
    def self.filtered_column?(name : String) : Bool
      return true if columns.includes?(name)

      global = Grant.settings.filter_attributes
      !global.empty? && Grant::Attributes.filtered?(name, global)
    end

    # Whether any column can be filtered: a tracked model has an encrypted or
    # filtered column, or `Grant.settings.filter_attributes` names one. When
    # none can, `.redact` returns the binds without reading the statement.
    def self.filtering? : Bool
      !columns.empty? || !Grant.settings.filter_attributes.empty?
    end

    # Returns *params* with the values bound to filtered columns replaced by
    # `[FILTERED]`. Anything that is not a list of binds is returned as given.
    #
    # The `Array(T)` restriction makes a union of array types (the executor
    # logs several) dispatch per concrete array, so each call maps one element
    # type.
    def self.redact(query : String, params : Array(T)) forall T
      return params if params.empty? || !filtering?

      bound = bound_columns(query)
      return params if bound.empty?

      params.map_with_index do |value, index|
        column = bound[index]?
        column && filtered_column?(column) ? REDACTED : value
      end
    end

    # :ditto:
    def self.redact(query : String, params)
      params
    end

    # Forgets every tracked model. For specs.
    def self.reset : Nil
      @@mutex.synchronize do
        @@models.clear
        @@columns = Set(String).new
        @@stale = true
      end
    end

    private def self.columns : Set(String)
      @@mutex.synchronize do
        signature = Grant.settings.filter_attributes.hash
        if @@stale || signature != @@global_signature
          @@columns = build_columns
          @@global_signature = signature
          @@stale = false
        end
        @@columns
      end
    end

    private def self.build_columns : Set(String)
      set = Set(String).new
      @@models.each do |model|
        model.encrypted_attributes.each_value { |attribute| set << attribute.column_name }
        filters = model.filter_attributes
        model.fields.each { |field| set << field if Grant::Attributes.filtered?(field, filters) }
      end
      set
    end

    # Maps each bind position to the column it is compared with or inserted
    # into, for the statement shapes Grant writes.
    private def self.bound_columns(query : String) : Hash(Int32, String)
      bound = {} of Int32 => String
      question_marks = [] of Int32
      query.each_char_with_index { |char, offset| question_marks << offset if char == '?' }

      # `column <op> ?` / `column <op> $1`
      Grant::TextMatching.comparison_binds(query).each do |comparison|
        if index = placeholder_index(comparison.placeholder, question_marks)
          bound[index] = comparison.column
        end
      end

      # `column IN (?, ?)`
      Grant::TextMatching.in_list_binds(query).each do |list|
        list.placeholders.each do |placeholder|
          if index = placeholder_index(placeholder, question_marks)
            bound[index] = list.column
          end
        end
      end

      if insert = Grant::TextMatching.insert_binds(query)
        names = insert.column_list.split(',').map(&.strip.strip('"').strip('`'))
        insert.placeholders.each_with_index do |placeholder, position|
          if index = placeholder_index(placeholder, question_marks)
            bound[index] = names[position % names.size]
          end
        end
      end

      bound
    end

    private def self.placeholder_index(placeholder : Grant::TextMatching::Placeholder, question_marks : Array(Int32)) : Int32?
      if placeholder.text.starts_with?('$')
        placeholder.text[1..].to_i - 1
      else
        question_marks.index(placeholder.index)
      end
    end
  end
end
