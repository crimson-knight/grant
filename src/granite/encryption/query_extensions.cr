module Granite::Encryption
  # Extensions for querying encrypted attributes
  module QueryExtensions
    macro included
      # Helper method to convert query params with encrypted fields
      def self.encrypt_query_params(**attrs)
        encrypted_attrs = {} of Symbol => Granite::Columns::Type
        
        attrs.each do |key, value|
          key_str = key.to_s
          
          # Check if this is an encrypted attribute
          if encrypted_attr = @@encrypted_attributes[key_str]?
            # Only deterministic fields can be queried
            if encrypted_attr.deterministic
              encrypted_value = Granite::Encryption.encrypt(
                value.to_s,
                self.name,
                key_str,
                true # deterministic
              )
              encrypted_attrs[:"#{key}_encrypted"] = encrypted_value
            else
              raise ArgumentError.new("Cannot query non-deterministic encrypted field: #{key}")
            end
          else
            encrypted_attrs[key] = value
          end
        end
        
        encrypted_attrs
      end
      
      # Add where_encrypted helper
      def self.where_encrypted(**attrs)
        where(**encrypt_query_params(**attrs))
      end
      
      # Add find_by_encrypted helper
      def self.find_by_encrypted(**attrs)
        find_by(**encrypt_query_params(**attrs))
      end
    end
  end
  
  # Module for query builder extensions
  module QueryBuilderExtensions
    # Add encrypted attribute support to query builders
    macro included
      # Add where_encrypted for query builders
      def where_encrypted(**attrs)
        encrypted_attrs = {} of Symbol => Granite::Columns::Type
        
        attrs.each do |key, value|
          key_str = key.to_s
          
          # Check if the model has encrypted attributes
          if model_class.responds_to?(:encrypted_attributes)
            if encrypted_attr = model_class.encrypted_attributes[key_str]?
              if encrypted_attr.deterministic
                encrypted_value = Granite::Encryption.encrypt(
                  value.to_s,
                  model_class.name,
                  key_str,
                  true
                )
                encrypted_attrs[:"#{key}_encrypted"] = encrypted_value
              else
                raise ArgumentError.new("Cannot query non-deterministic encrypted field: #{key}")
              end
            else
              encrypted_attrs[key] = value
            end
          else
            encrypted_attrs[key] = value
          end
        end
        
        where(**encrypted_attrs)
      end
    end
  end
end