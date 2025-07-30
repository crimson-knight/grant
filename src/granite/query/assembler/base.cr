# Base class for database-specific query assemblers
#
# This is the base interface for all query assemblers. Each database
# adapter (PostgreSQL, MySQL, SQLite) implements its own assembler
# to handle database-specific SQL generation.
module Granite::Query::Assembler
  abstract class Base(Model)
    getter query : Granite::Query::Builder(Model)
    @numbered_parameters : Array(Granite::Columns::Type)
    @aggregate_fields : Array(String)

    def initialize(@query : Granite::Query::Builder(Model))
      @numbered_parameters = [] of Granite::Columns::Type
      @aggregate_fields = [] of String
    end

    abstract def select : Granite::Query::Executor::List(Model)
    abstract def delete
    abstract def count : Granite::Query::Executor::Value(Model, Int64) | Granite::Query::Executor::MultiValue(Model, Int64)
    abstract def exists? : Granite::Query::Executor::Value(Model, Bool)
    abstract def first(n : Int32) : Granite::Query::Executor::List(Model)
    
    # Convenience methods support
    abstract def pluck_sql(fields : Array(String)) : String
    abstract def insert_all_sql(attributes : Array(Hash(String, Granite::Columns::Type)), 
                                returning : Array(Symbol)?, 
                                unique_by : Array(Symbol)?) : String
    abstract def upsert_all_sql(attributes : Array(Hash(String, Granite::Columns::Type)), 
                                returning : Array(Symbol)?, 
                                unique_by : Array(Symbol)?,
                                update_only : Array(Symbol)?) : String

    def where_clause(where_fields = @query.where_fields)
      clauses = where_fields.map do |clause|
        if stmt = clause[:stmt]?
          add_parameter(clause[:value])
          stmt
        else
          field = clause[:field]
          operator = clause[:operator]
          value = clause[:value]

          add_parameter(value)

          case operator
          when :eq
            "#{quote_identifier(field)} = ?"
          when :ne
            "#{quote_identifier(field)} != ?"
          when :gt
            "#{quote_identifier(field)} > ?"
          when :gte
            "#{quote_identifier(field)} >= ?"
          when :lt
            "#{quote_identifier(field)} < ?"
          when :lte
            "#{quote_identifier(field)} <= ?"
          when :in
            if value.is_a?(Array)
              placeholders = value.map { "?" }.join(", ")
              "#{quote_identifier(field)} IN (#{placeholders})"
            else
              "#{quote_identifier(field)} = ?"
            end
          when :like
            "#{quote_identifier(field)} LIKE ?"
          when :ilike
            "LOWER(#{quote_identifier(field)}) LIKE LOWER(?)"
          else
            raise "Unknown operator: #{operator}"
          end
        end
      end

      return "" if clauses.empty?

      # Handle joins between clauses
      result = clauses.first
      where_fields.each_with_index do |clause, index|
        next if index == 0
        join = clause[:join]
        result = "#{result} #{join.to_s.upcase} #{clauses[index]}"
      end

      result
    end

    def quote_identifier(name : String) : String
      raise NotImplementedError.new("Must be implemented by subclass")
    end

    def add_parameter(value)
      raise NotImplementedError.new("Must be implemented by subclass")
    end
  end
end