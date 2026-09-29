module Grant::Encryption
  # Extensions for querying encrypted attributes
  module QueryExtensions
    macro included
      # Add where_encrypted helper that handles encryption directly
      def self.where_encrypted(**attrs)
        # Build WHERE clause
        clauses = [] of String
        params = [] of Grant::Columns::Type

        attrs.each do |key, value|
          key_str = key.to_s

          # Check if this is an encrypted attribute
          if encrypted_attr = encrypted_attributes[key_str]?
            # Only deterministic fields can be queried
            if encrypted_attr.deterministic
              encrypted_value = encrypted_attr.query_value(value.to_s)
              clauses << "#{encrypted_attr.column_name} = ?"
              params << encrypted_value
            else
              raise ArgumentError.new("Cannot query non-deterministic encrypted field: #{key}")
            end
          else
            clauses << "#{key} = ?"
            params << value
          end
        end

        # Use the all method with WHERE clause
        all("WHERE #{clauses.join(" AND ")}", params)
      end

      # Add find_by_encrypted helper
      def self.find_by_encrypted(**attrs)
        where_encrypted(**attrs).first
      end
    end
  end
end

module Grant::Encryption
  # Turns the value of a predicate on an encrypted attribute into what the
  # storage column holds, once per statement. Called while the SQL is
  # assembled, so the comparison stays in the database.
  module QueryValue
    # *value* is nil, a single value or a list. Returns nil, the ciphertext,
    # or (a list, or a value that also matches its plaintext while
    # `support_unencrypted_data` is on) an array of stored forms.
    def self.rewrite(attribute : EncryptedAttribute, value : Grant::Columns::Type) : Grant::Columns::Type
      unless attribute.deterministic
        raise ArgumentError.new("Cannot query non-deterministic encrypted field: #{attribute.attribute_name}")
      end

      if value.nil?
        nil
      elsif value.is_a?(Array)
        stored = [] of String
        value.each do |item|
          raise ArgumentError.new("Encrypted field #{attribute.attribute_name.inspect} cannot be matched against nil inside a list") if item.nil?
          stored.concat(attribute.query_values(Serializer.dump(item)))
        end
        stored.as(Grant::Columns::Type)
      else
        stored = attribute.query_values(Serializer.dump(value))
        stored.size == 1 ? stored.first : stored.as(Grant::Columns::Type)
      end
    end
  end
end
