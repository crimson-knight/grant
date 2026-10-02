require "./index_definition"

# Declares indexes on a model, created by `Model.migrator.create`.
#
# ```
# class User < Grant::Base
#   column id : Int64, primary: true
#   column email : String
#   column deleted_at : Time?
#
#   index :email, unique: true, where: "deleted_at IS NULL"
#   index [:last_name, :first_name]
# end
# ```
#
# Options are those of `Grant::Schema::SchemaStatements#add_index`
# (`unique`, `name`, `where`, `using`, `order`, `opclass`, `include`,
# `length`, `if_not_exists`). Build costs and locks are those of `add_index`.
abstract class Grant::Base
  macro index(columns, **options)
    {% names = columns.is_a?(ArrayLiteral) ? columns : [columns] %}
    {% suffix = names.map(&.id.stringify.gsub(/[^A-Za-z0-9_]/, "_")).join("_") %}
    def self.__grant_index_{{suffix.id}}(table : ::String) : ::Grant::Schema::IndexDefinition
      ::Grant::Schema::IndexDefinition.build(table, {{columns}}{{", ".id if options.size > 0}}{{options.double_splat}})
    end
  end
end
