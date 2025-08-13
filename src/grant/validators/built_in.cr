# Built-in validators for Grant ORM
#
# Provides Rails-style validation helpers for common validation patterns.
# All validators support :if and :unless conditional options.

module Grant::Validators::BuiltIn
  # Helper macro to add conditional validation support
  macro add_conditional_check(condition_if, condition_unless)
    should_validate = true
    
    {% if condition_if %}
      {% if condition_if.is_a?(SymbolLiteral) %}
        should_validate = record.{{condition_if.id}} if record.responds_to?({{condition_if}})
      {% else %}
        # Handle Proc case
        _condition = {{condition_if}}
        should_validate = case _condition
        when Proc
          _condition.as(Proc(typeof(record), Bool)).call(record)
        else
          true
        end
      {% end %}
    {% elsif condition_unless %}
      {% if condition_unless.is_a?(SymbolLiteral) %}
        should_validate = !record.{{condition_unless.id}} if record.responds_to?({{condition_unless}})
      {% else %}
        # Handle Proc case
        _condition = {{condition_unless}}
        should_validate = case _condition
        when Proc
          !_condition.as(Proc(typeof(record), Bool)).call(record)
        else
          true
        end
      {% end %}
    {% end %}
    
    next unless should_validate
  end
  
  # Validates that a numeric field meets specified criteria
  module Numericality
    macro validates_numericality_of(field, **options)
      {% 
        message_base = options[:message] || "is not a number"
        conditions = [] of String
        
        if gt = options[:greater_than]
          conditions << "greater than #{gt}"
        end
        if gte = options[:greater_than_or_equal_to]
          conditions << "greater than or equal to #{gte}"
        end
        if lt = options[:less_than]
          conditions << "less than #{lt}"
        end
        if lte = options[:less_than_or_equal_to]
          conditions << "less than or equal to #{lte}"
        end
        if eq = options[:equal_to]
          conditions << "equal to #{eq}"
        end
        if other = options[:other_than]
          conditions << "other than #{other}"
        end
        if options[:odd]
          conditions << "odd"
        end
        if options[:even]
          conditions << "even"
        end
        if options[:only_integer]
          conditions << "an integer"
        end
        
        full_message = conditions.empty? ? message_base : "must be #{conditions.join(" and ")}"
      %}
      
      validate :{{field}}, {{full_message}} do |record|
        add_conditional_check({{options[:if]}}, {{options[:unless]}})
        
        value = record.{{field}}
        
        # Allow nil if specified
        {% if options[:allow_nil] %}
          next true if value.nil?
        {% elsif options[:allow_blank] %}
          next true if value.nil? || value.to_s.blank?
        {% end %}
        
        # Ensure it's numeric
        next false unless value.is_a?(Number)
        
        # Check specific validations
        {% if options[:greater_than] %}
          next false unless value > {{options[:greater_than]}}
        {% end %}
        
        {% if options[:greater_than_or_equal_to] %}
          next false unless value >= {{options[:greater_than_or_equal_to]}}
        {% end %}
        
        {% if options[:less_than] %}
          next false unless value < {{options[:less_than]}}
        {% end %}
        
        {% if options[:less_than_or_equal_to] %}
          next false unless value <= {{options[:less_than_or_equal_to]}}
        {% end %}
        
        {% if options[:equal_to] %}
          next false unless value == {{options[:equal_to]}}
        {% end %}
        
        {% if options[:other_than] %}
          next false unless value != {{options[:other_than]}}
        {% end %}
        
        {% if options[:odd] %}
          next false unless value.to_i.odd?
        {% end %}
        
        {% if options[:even] %}
          next false unless value.to_i.even?
        {% end %}
        
        {% if options[:in] %}
          next false unless {{options[:in]}}.includes?(value)
        {% end %}
        
        {% if options[:only_integer] %}
          next false unless value == value.to_i
        {% end %}
        
        true
      end
    end
  end
  
  # Validates format using regular expressions
  module Format
    macro validates_format_of(field, **options)
      {% 
        with_pattern = options[:with]
        without_pattern = options[:without]
        message = options[:message] || "is invalid"
      %}
      
      validate :{{field}}, {{message}} do |record|
        add_conditional_check({{options[:if]}}, {{options[:unless]}})
        
        value = record.{{field}}
        
        {% if options[:allow_nil] %}
          next true if value.nil?
        {% elsif options[:allow_blank] %}
          next true if value.nil? || value.to_s.blank?
        {% end %}
        
        string_value = value.to_s
        
        {% if with_pattern %}
          next false unless string_value.matches?({{with_pattern}})
        {% end %}
        
        {% if without_pattern %}
          next false if string_value.matches?({{without_pattern}})
        {% end %}
        
        true
      end
    end
  end
  
  # Validates length of string/array fields
  module Length
    macro validates_length_of(field, **options)
      {% 
        conditions = [] of String
        
        if min = options[:minimum]
          conditions << "at least #{min} characters"
        end
        if max = options[:maximum]
          conditions << "at most #{max} characters"
        end
        if exact = options[:is]
          conditions << "exactly #{exact} characters"
        end
        if range = options[:in]
          conditions << "between #{range.begin} and #{range.end} characters"
        end
        
        message = options[:message] || (conditions.empty? ? "has incorrect length" : "must be #{conditions.join(" and ")}")
      %}
      
      validate :{{field}}, {{message}} do |record|
        add_conditional_check({{options[:if]}}, {{options[:unless]}})
        
        value = record.{{field}}
        
        {% if options[:allow_nil] %}
          next true if value.nil?
        {% elsif options[:allow_blank] %}
          next true if value.nil? || (value.responds_to?(:empty?) && value.empty?)
        {% end %}
        
        length = if value.responds_to?(:size)
          value.size
        else
          value.to_s.size
        end
        
        {% if options[:minimum] %}
          next false if length < {{options[:minimum]}}
        {% end %}
        
        {% if options[:maximum] %}
          next false if length > {{options[:maximum]}}
        {% end %}
        
        {% if options[:is] %}
          next false unless length == {{options[:is]}}
        {% end %}
        
        {% if options[:in] %}
          next false unless {{options[:in]}}.includes?(length)
        {% end %}
        
        true
      end
    end
    
    # Aliases
    macro validates_size_of(field, **options)
      validates_length_of({{field}}, {{**options}})
    end
  end
  
  # Validates confirmation fields match
  module Confirmation
    macro validates_confirmation_of(field, **options)
      {% 
        message = options[:message] || "doesn't match confirmation"
        confirmation_field = (field.stringify + "_confirmation").id
      %}
      
      # Create virtual attribute for confirmation
      property {{confirmation_field}} : String?
      
      validate :{{field}}, {{message}} do |record|
        add_conditional_check({{options[:if]}}, {{options[:unless]}})
        
        confirmation_value = record.{{confirmation_field}}
        next true if confirmation_value.nil?
        
        record.{{field}}.to_s == confirmation_value
      end
    end
  end
  
  # Validates acceptance of terms  
  module Acceptance
    macro validates_acceptance_of(field, **options)
      {% 
        message = options[:message] || "must be accepted"
        accept_values = options[:accept] || ["1", "true", "yes", "on"]
      %}
      
      # Create virtual attribute if it doesn't exist
      {% unless @type.instance_vars.any? { |ivar| ivar.name == field.id } %}
        property {{field}} : String?
      {% end %}
      
      validate :{{field}}, {{message}} do |record|
        add_conditional_check({{options[:if]}}, {{options[:unless]}})
        
        value = record.{{field}}
        
        case value
        when Nil
          {% unless options[:allow_nil] %}
            false
          {% else %}
            true
          {% end %}
        when Bool
          value == true
        else
          {{accept_values}}.includes?(value.to_s.downcase)
        end
      end
    end
  end
  
  # Validates associated records are valid
  module Associated
    macro validates_associated(*associations, **options)
      {% for association in associations %}
        {% message = options[:message] || "is invalid" %}
        
        validate :{{association}}, {{message}} do |record|
          add_conditional_check({{options[:if]}}, {{options[:unless]}})
          
          associated = record.{{association}}
          
          case associated
          when Nil
            true
          when Array
            associated.all? { |item| item.valid? }
          else
            associated.valid?
          end
        end
      {% end %}
    end
  end
  
  # Common format validators
  module CommonFormats
    EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
    URL_REGEX = /\Ahttps?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)\z/
    
    macro validates_email(field, **options)
      {% merged_options = {with: CommonFormats::EMAIL_REGEX, message: "is not a valid email"}.merge(options) %}
      validates_format_of({{field}}, {{**merged_options}})
    end
    
    macro validates_url(field, **options)
      {% merged_options = {with: CommonFormats::URL_REGEX, message: "is not a valid URL"}.merge(options) %}
      validates_format_of({{field}}, {{**merged_options}})
    end
  end
  
  # Validates inclusion/exclusion in a set
  module Inclusion
    macro validates_inclusion_of(field, **options)
      {% 
        in_values = options[:in]
        message = options[:message] || "is not included in the list"
      %}
      
      validate :{{field}}, {{message}} do |record|
        add_conditional_check({{options[:if]}}, {{options[:unless]}})
        
        value = record.{{field}}
        
        {% if options[:allow_nil] %}
          next true if value.nil?
        {% elsif options[:allow_blank] %}
          next true if value.nil? || value.to_s.blank?
        {% end %}
        
        {{in_values}}.includes?(value)
      end
    end
    
    macro validates_exclusion_of(field, **options)
      {% 
        in_values = options[:in]
        message = options[:message] || "is reserved"
      %}
      
      validate :{{field}}, {{message}} do |record|
        add_conditional_check({{options[:if]}}, {{options[:unless]}})
        
        value = record.{{field}}
        
        {% if options[:allow_nil] %}
          next true if value.nil?
        {% elsif options[:allow_blank] %}
          next true if value.nil? || value.to_s.blank?
        {% end %}
        
        !{{in_values}}.includes?(value)
      end
    end
  end
end

# Include all built-in validators in Grant::Base
abstract class Grant::Base
  extend Grant::Validators::BuiltIn::Numericality
  extend Grant::Validators::BuiltIn::Format
  extend Grant::Validators::BuiltIn::Length
  extend Grant::Validators::BuiltIn::Confirmation
  extend Grant::Validators::BuiltIn::Acceptance
  extend Grant::Validators::BuiltIn::Associated
  extend Grant::Validators::BuiltIn::CommonFormats
  extend Grant::Validators::BuiltIn::Inclusion
end