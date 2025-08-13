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
          if encrypted_attr = @@encrypted_attributes[key_str]?
            # Only deterministic fields can be queried
            if encrypted_attr.deterministic
              encrypted_value = Grant::Encryption.encrypt(
                value.to_s,
                self.name,
                key_str,
                true # deterministic
              )
              clauses << "#{key}_encrypted = ?"
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