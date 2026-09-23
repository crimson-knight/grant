module Grant::Select
  struct Container
    property custom : String?
    getter table_name, fields

    def initialize(@custom = nil, @table_name = "", @fields = [] of String)
    end
  end

  macro included
    # Returns the model's custom SELECT statement, when it has declared one.
    # Query assemblers use this accessor while ordinary models inherit `nil`.
    def self.custom_select_statement : String?
      select_container.custom
    end
  end

  macro select_statement(text)
    @@select_container.custom = {{text.strip}}

    def self.select : String?
      custom_select_statement
    end
  end
end
