module Granite::Normalization
  macro included
    before_validation :_run_normalizations
    
    # Generate instance method that calls all normalization methods
    private def _run_normalizations
      # Check if normalization should be skipped
      return if @_skip_normalization
      
      {% verbatim do %}
        {% for method in @type.methods %}
          {% if method.name.starts_with?("_normalize_") && method.visibility == :private %}
            {{ method.name.id }}
          {% end %}
        {% end %}
      {% end %}
    end
  end

  # DSL for adding normalization rules - available as a top-level macro
  macro normalizes(attribute, **options, &block)
    {% if block %}
      {% attribute_name = attribute.id %}
      {% method_name = "_normalize_#{attribute_name}".id %}
      
      # Generate normalization method
      private def {{ method_name }}
        {% if options[:if] %}
          return unless {{ options[:if].id }}
        {% end %}
        
        if value = self.{{ attribute_name }}
          if value.is_a?(String)
            normalized = begin
              {{ block.body }}
            end
            self.{{ attribute_name }} = normalized
          end
        end
      end
    {% else %}
      {% raise "normalizes requires a block" %}
    {% end %}
  end
end
