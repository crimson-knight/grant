require "./error_taxonomy"

module Grant
  # Raised by a validator declared with `strict: true` (or `strict: SomeError`
  # for a custom class) instead of adding to `record.errors`. The message is the
  # full message, e.g. `"Name can't be blank"`.
  #
  # Mirrors `ActiveModel::StrictValidationFailed`.
  #
  # ```
  # class User < Grant::Base
  #   validates_presence_of :name, strict: true
  # end
  #
  # User.new.valid? # raises Grant::StrictValidationFailed
  # ```
  class StrictValidationFailed < ErrorBase
  end

  # Compile-time helper shared by every validator and callback macro that takes
  # `if:` / `unless:` / `on:`.
  #
  # Each condition may be a Symbol naming an instance method, a Proc/lambda that
  # receives the record, or an Array mixing both. `if:` terms are ANDed and
  # every `unless:` term must be false, so `if: [:a?, :b?], unless: [:c?]` reads
  # "a? and b? and not c?".
  module Conditions
    # Expands to a Bool expression that is true when the record passes every
    # condition. Expands to `true` when there are none.
    #
    # - *receiver* is the record expression (`record` inside a validator block)
    #   or `nil` for callbacks, where the record is `self`.
    # - *on_terms* names validation contexts (callbacks only); the expression
    #   checks the running validation context.
    # - *guarded* keeps the historical validator behavior where a Symbol that
    #   is not a public method of the record is ignored rather than a compile
    #   error.
    #
    # :nodoc:
    macro met?(receiver, if_terms, unless_terms, on_terms = nil, guarded = false)
      {%
        parts = [] of String
        recv = receiver.is_a?(NilLiteral) ? "" : receiver.id.stringify
        proc_recv = recv.empty? ? "self" : recv
        ifs = if_terms.is_a?(ArrayLiteral) ? if_terms : [if_terms]
        unlesses = unless_terms.is_a?(ArrayLiteral) ? unless_terms : [unless_terms]
        ons = on_terms.is_a?(ArrayLiteral) ? on_terms : [on_terms]

        ifs.each do |term|
          if term.is_a?(NilLiteral)
          elsif term.is_a?(SymbolLiteral)
            if recv.empty?
              parts << term.id.stringify
            elsif guarded
              parts << "(!#{recv.id}.responds_to?(#{term}) || #{recv.id}.#{term.id})"
            else
              parts << "#{recv.id}.#{term.id}"
            end
          else
            parts << "(#{term}).call(#{proc_recv.id})"
          end
        end

        unlesses.each do |term|
          if term.is_a?(NilLiteral)
          elsif term.is_a?(SymbolLiteral)
            if recv.empty?
              parts << "!#{term.id}"
            elsif guarded
              parts << "!(#{recv.id}.responds_to?(#{term}) && #{recv.id}.#{term.id})"
            else
              parts << "!#{recv.id}.#{term.id}"
            end
          else
            parts << "!(#{term}).call(#{proc_recv.id})"
          end
        end

        on_checks = [] of String
        ons.each do |term|
          if term.is_a?(NilLiteral)
          elsif term.is_a?(SymbolLiteral)
            on_checks << "__in_validation_context?(#{term})"
          else
            term.raise "on: expects a Symbol or an Array of Symbols"
          end
        end
        parts << "(#{on_checks.join(" || ").id})" unless on_checks.empty?
      %}
      {{ (parts.empty? ? "true" : parts.join(" && ")).id }}
    end
  end
end
