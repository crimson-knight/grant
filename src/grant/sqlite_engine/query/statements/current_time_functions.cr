module Grant::SQLiteEngine::Query
  # date(), time(), datetime(), julianday() and unixepoch() of the time
  # value 'now' with no modifiers (date.c), the form micrate's
  # `DEFAULT (datetime('now'))` uses. Every other call of the date and time
  # functions arrives with milestone G6 and raises UnsupportedSQL.
  class CurrentTimeExpr < Expr
    def initialize(@function_name : String)
    end

    # sqlite3StmtCurrentTime reads the clock in milliseconds.
    def evaluate(frame : Frame) : Value
      now = Time.utc
      case @function_name
      when "date"      then now.to_s("%Y-%m-%d")
      when "time"      then now.to_s("%H:%M:%S")
      when "datetime"  then now.to_s("%Y-%m-%d %H:%M:%S")
      when "unixepoch" then now.to_unix
      else
        # julianday: days since noon UTC, November 24, 4714 BC.
        now.to_unix_ms / 86_400_000.0 + 2_440_587.5
      end
    end

    def affinity : ExpressionAffinity
      ExpressionAffinity::None
    end
  end

  module ExpressionCompiler
    CURRENT_TIME_FUNCTIONS = %w[date time datetime julianday unixepoch]

    private def compile_function(call : SQL::FunctionCall, context : QueryContext) : Expr
      lower = call.name.value.downcase
      if CURRENT_TIME_FUNCTIONS.includes?(lower) && call.arguments.size == 1 && call.over.nil? && call.over_name.nil?
        argument = call.arguments[0]
        if argument.is_a?(SQL::Literal) && argument.kind.string? && SQL::Parser.dequote(argument.text).downcase == "now"
          return CurrentTimeExpr.new(lower)
        end
      end
      previous_def
    end
  end
end
