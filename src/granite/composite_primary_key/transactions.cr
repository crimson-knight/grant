module Granite::CompositePrimaryKey::Transactions
  # Transaction support for composite primary keys
  # Currently relies on the base implementation checking for multiple primary keys
  # The adapter methods update_with_where and delete_with_where are available for future use
  
  # TODO: In the future, we can override the private __create, __update, and __destroy methods
  # to use composite key specific logic. For now, the base implementation should handle it
  # by checking the number of primary key columns.
end