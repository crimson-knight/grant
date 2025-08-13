require "./transactions"
require "./querying"

module Grant::Integrators
  include Transactions::ClassMethods
  include Querying

  def find_or_create_by(**args)
    find_by(**args) || create(**args)
  end

  def find_or_initialize_by(**args)
    find_by(**args) || new(**args)
  end
end
