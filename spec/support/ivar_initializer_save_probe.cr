# Saves a model the way a generated Amber V2 app does. Compiled and run by
# spec/grant/persistence/ivar_initializer_save_spec.cr in its own process,
# because the crash it guards against comes from how the whole program is
# compiled: the controller below is declared before the model (an app requires
# controllers before models) and builds the model in an instance variable
# initializer, as Amber's scaffold controllers do with `@pet = Pet.new`.
#
# The compiler types instance variable initializers before it reads class
# variable initializers. Typing `IvarInitializerPet.new` there gave the model
# its own copy of each `Grant::Base` class variable it reached, created without
# the initializer, so the copy stayed zeroed. The first `save` then locked a
# null mutex (`Invalid memory access ... at address 0x10`). A subclass of a
# model with a `default_scope` lost the scope the same way: its zeroed copy of
# the `true` flag read `false`.
require "../../src/grant"
require "../../src/adapter/sqlite"

database_path = ARGV[0]? || raise ArgumentError.new("usage: ivar_initializer_save_probe <sqlite database path>")
Grant::Connections << Grant::Adapter::Sqlite.new(name: "primary", url: "sqlite3:#{database_path}")

class IvarInitializerPetController
  @pet = IvarInitializerPet.new
  @puppy = IvarInitializerPuppy.new

  def create(name : String) : IvarInitializerPet
    pet = IvarInitializerPet.new
    pet.name = name
    pet.save!
    @pet = pet
  end
end

class IvarInitializerPet < Grant::Base
  connection primary
  table ivar_initializer_pets

  column id : Int64, primary: true
  column name : String
end

class IvarInitializerScopedPet < Grant::Base
  connection primary
  table ivar_initializer_scoped_pets

  column id : Int64, primary: true
  column adopted : Bool = false

  default_scope { where(adopted: false) }
end

class IvarInitializerPuppy < IvarInitializerScopedPet
end

IvarInitializerPet.adapter.open(&.exec("CREATE TABLE ivar_initializer_pets (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"))

pet = IvarInitializerPetController.new.create("Ruby")
puts "saved=#{pet.persisted?} id=#{pet.id}"
puts "found=#{IvarInitializerPet.find!(pet.id).name}"
puts "replica_lag_threshold=#{IvarInitializerPet.replica_lag_threshold}"
puts "subclass_default_scope=#{IvarInitializerPuppy._has_default_scope?}"
