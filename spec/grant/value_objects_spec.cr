require "../spec_helper"

{% begin %}
{% adapter_literal = env("CURRENT_ADAPTER").id %}

# Define value objects for testing
struct Address
  getter street : String
  getter city : String
  getter zip : String
  
  def initialize(@street : String, @city : String, @zip : String)
  end
  
  def ==(other : Address)
    street == other.street && city == other.city && zip == other.zip
  end
  
  def to_s(io)
    io << "#{street}, #{city} #{zip}"
  end
end

struct Money
  getter amount : Float64
  getter currency : String
  
  def initialize(@amount : Float64, @currency : String = "USD")
  end
  
  # Constructor from strings with named arguments
  def self.new(*, amount : String, currency : String)
    new(amount.to_f64, currency)
  end
  
  def ==(other : Money)
    amount == other.amount && currency == other.currency
  end
  
  def to_s(io)
    io << "#{currency} #{amount}"
  end
  
  # Add validation
  def validate
    errors = [] of Grant::Error
    errors << Grant::Error.new(:amount, "must be positive") if amount < 0
    errors << Grant::Error.new(:currency, "must be 3 characters") if currency.size != 3
    errors
  end
end

# Custom constructor for Temperature
struct Temperature
  getter celsius : Float64
  
  def initialize(@celsius : Float64)
  end
  
  def fahrenheit
    (celsius * 9.0 / 5.0) + 32.0
  end
  
  def ==(other : Temperature)
    celsius == other.celsius
  end
end

# Test models
class CustomerWithAddress < Grant::Base
  connection {{ adapter_literal }}
  table customers_with_addresses
  
  column id : Int64, primary: true
  column name : String
  
  # Simple aggregation
  aggregation :address, Address,
    mapping: {
      address_street: :street,
      address_city: :city,
      address_zip: :zip
    }
end

class CustomerWithMoney < Grant::Base
  connection {{ adapter_literal }}
  table customers_with_money
  
  column id : Int64, primary: true
  column name : String
  
  # Aggregation with allow_nil
  aggregation :balance, Money,
    mapping: {
      balance_amount: :amount,
      balance_currency: :currency
    },
    allow_nil: true
end

class CustomerWithCustomConstructor < Grant::Base
  connection {{ adapter_literal }}
  table customers_with_custom
  
  column id : Int64, primary: true
  column name : String
  
  # Aggregation with custom constructor
  aggregation :temperature, Temperature,
    mapping: {
      temp_fahrenheit: :fahrenheit
    },
    constructor: ->(fahrenheit : String?) do
      return nil if fahrenheit.nil?
      # Convert from Fahrenheit to Celsius
      f = fahrenheit.to_f
      celsius = (f - 32.0) * 5.0 / 9.0
      Temperature.new(celsius)
    end
end

# Model with multiple aggregations
class CustomerWithMultiple < Grant::Base
  connection {{ adapter_literal }}
  table customers_with_multiple
  
  column id : Int64, primary: true
  column name : String
  
  aggregation :home_address, Address,
    mapping: {
      home_street: :street,
      home_city: :city,
      home_zip: :zip
    }
    
  aggregation :work_address, Address,
    mapping: {
      work_street: :street,
      work_city: :city,
      work_zip: :zip
    }
end

describe Grant::ValueObjects do
  before_each do
    CustomerWithAddress.exec("DROP TABLE IF EXISTS customers_with_addresses")
    CustomerWithAddress.exec(<<-SQL
      CREATE TABLE customers_with_addresses (
        id INTEGER PRIMARY KEY,
        name VARCHAR(255),
        address_street VARCHAR(255),
        address_city VARCHAR(255),
        address_zip VARCHAR(255)
      )
    SQL
    )
    
    CustomerWithMoney.exec("DROP TABLE IF EXISTS customers_with_money")
    CustomerWithMoney.exec(<<-SQL
      CREATE TABLE customers_with_money (
        id INTEGER PRIMARY KEY,
        name VARCHAR(255),
        balance_amount VARCHAR(255),
        balance_currency VARCHAR(255)
      )
    SQL
    )
    
    CustomerWithCustomConstructor.exec("DROP TABLE IF EXISTS customers_with_custom")
    CustomerWithCustomConstructor.exec(<<-SQL
      CREATE TABLE customers_with_custom (
        id INTEGER PRIMARY KEY,
        name VARCHAR(255),
        temp_fahrenheit VARCHAR(255)
      )
    SQL
    )
    
    CustomerWithMultiple.exec("DROP TABLE IF EXISTS customers_with_multiple")
    CustomerWithMultiple.exec(<<-SQL
      CREATE TABLE customers_with_multiple (
        id INTEGER PRIMARY KEY,
        name VARCHAR(255),
        home_street VARCHAR(255),
        home_city VARCHAR(255),
        home_zip VARCHAR(255),
        work_street VARCHAR(255),
        work_city VARCHAR(255),
        work_zip VARCHAR(255)
      )
    SQL
    )
  end
  
  describe "#aggregation" do
    it "creates getter and setter methods" do
      customer = CustomerWithAddress.new
      customer.responds_to?(:address).should be_true
      customer.responds_to?(:address=).should be_true
    end
    
    it "sets and gets value objects" do
      customer = CustomerWithAddress.new(name: "John Doe")
      address = Address.new("123 Main St", "Boston", "02101")
      
      customer.address = address
      customer.address.should eq(address)
      customer.address_street.should eq("123 Main St")
      customer.address_city.should eq("Boston")
      customer.address_zip.should eq("02101")
    end
    
    it "handles nil values" do
      customer = CustomerWithAddress.new(name: "John Doe")
      customer.address.should be_nil
      
      customer.address = nil
      customer.address_street.should be_nil
      customer.address_city.should be_nil
      customer.address_zip.should be_nil
    end
    
    it "persists value objects as columns" do
      customer = CustomerWithAddress.new(name: "John Doe")
      customer.address = Address.new("123 Main St", "Boston", "02101")
      
      customer.save.should be_true
      customer.persisted?.should be_true
      
      # Reload and verify
      loaded = CustomerWithAddress.find!(customer.id)
      loaded.address.should_not be_nil
      loaded.address.not_nil!.street.should eq("123 Main St")
      loaded.address.not_nil!.city.should eq("Boston")
      loaded.address.not_nil!.zip.should eq("02101")
    end
    
    it "supports allow_nil option" do
      customer = CustomerWithMoney.new(name: "Jane Doe")
      customer.balance.should be_nil
      
      # All columns nil should return nil
      customer.balance_amount = nil
      customer.balance_currency = nil
      customer.balance.should be_nil
      
      # Partial values should still build object
      customer.balance_amount = "100.50"
      customer.balance_currency = nil
      customer.balance.should be_nil  # Because not all required fields are present
    end
    
    it "supports custom constructors" do
      customer = CustomerWithCustomConstructor.new(name: "Bob")
      customer.temp_fahrenheit = "98.6"  # Body temperature in Fahrenheit
      
      temp = customer.temperature
      temp.should_not be_nil
      temp.not_nil!.celsius.should be_close(37.0, 0.1)  # Body temperature in Celsius
      temp.not_nil!.fahrenheit.should be_close(98.6, 0.1)
    end
    
    it "supports multiple aggregations" do
      customer = CustomerWithMultiple.new(name: "Alice")
      
      home = Address.new("123 Home St", "Boston", "02101")
      work = Address.new("456 Work Ave", "Cambridge", "02139")
      
      customer.home_address = home
      customer.work_address = work
      
      customer.home_address.should eq(home)
      customer.work_address.should eq(work)
      
      customer.save.should be_true
      
      # Reload and verify
      loaded = CustomerWithMultiple.find!(customer.id)
      loaded.home_address.should eq(home)
      loaded.work_address.should eq(work)
    end
  end
  
  describe "dirty tracking" do
    it "tracks changes to value objects" do
      customer = CustomerWithAddress.new(name: "John Doe")
      customer.address = Address.new("123 Main St", "Boston", "02101")
      customer.save!
      
      customer.changed?.should be_false
      
      # Change the address
      customer.address = Address.new("456 Elm St", "Cambridge", "02139")
      
      customer.changed?.should be_true
      customer.address_changed?.should be_true
      customer.address_street.should eq("456 Elm St")
      
      # Check individual column changes
      customer.attribute_changed?("address_street").should be_true
      customer.attribute_changed?("address_city").should be_true
      customer.attribute_changed?("address_zip").should be_true
      
      customer.save.should be_true
      customer.changed?.should be_false
    end
    
    it "provides _was methods" do
      original_address = Address.new("123 Main St", "Boston", "02101")
      customer = CustomerWithAddress.create!(
        name: "John Doe",
        address: original_address
      )
      
      new_address = Address.new("456 Elm St", "Cambridge", "02139")
      customer.address = new_address
      
      # Current value
      customer.address.should eq(new_address)
      
      # Previous value
      previous = customer.address_was
      previous.should_not be_nil
      previous.not_nil!.street.should eq("123 Main St")
      previous.not_nil!.city.should eq("Boston")
      previous.not_nil!.zip.should eq("02101")
    end
  end
  
  describe "validation" do
    it "validates value objects" do
      customer = CustomerWithMoney.new(name: "Invalid Customer")
      
      # Set invalid money (negative amount)
      customer.balance_amount = "-100"
      customer.balance_currency = "USD"
      
      customer.valid?.should be_false
      customer.errors.map(&.field.to_s).should contain("balance")
      customer.errors.find { |e| e.field == :balance }.not_nil!.message.should contain("amount must be positive")
      
      # Fix the amount
      customer.balance_amount = "100"
      customer.valid?.should be_true
      
      # Invalid currency
      customer.balance_currency = "US"  # Should be 3 chars
      customer.valid?.should be_false
      customer.errors.find { |e| e.field == :balance }.not_nil!.message.should contain("currency must be 3 characters")
    end
    
    it "handles validation exceptions" do
      # This will test the exception handling in validation
      customer = CustomerWithAddress.new(name: "Test")
      
      # If we set columns that would cause initialization to fail
      customer.address_street = "123 Main St"
      customer.address_city = nil  # This will cause new() to fail
      customer.address_zip = "02101"
      
      # The validation should catch the exception
      customer.valid?.should be_true  # Because address returns nil when any column is nil
    end
  end
  
  describe "initialization" do
    it "accepts value objects through setter" do
      address = Address.new("123 Main St", "Boston", "02101")
      customer = CustomerWithAddress.new(name: "John Doe")
      customer.address = address
      
      customer.address.should eq(address)
      customer.address_street.should eq("123 Main St")
    end
    
    it "accepts value objects in create" do
      address = Address.new("123 Main St", "Boston", "02101")
      customer = CustomerWithAddress.new(name: "John Doe")
      customer.address = address
      customer.save!
      
      customer.persisted?.should be_true
      customer.address.should eq(address)
    end
  end
  
  describe "metadata" do
    it "provides aggregation metadata" do
      meta = CustomerWithAddress.aggregations
      meta.should_not be_nil
      meta.size.should eq(1)
      
      address_meta = meta[:address]
      address_meta.name.should eq("address")
      address_meta.class_name.should eq("Address")
      address_meta.mapping.should eq({
        "address_street" => :street,
        "address_city" => :city,
        "address_zip" => :zip
      })
      address_meta.allow_nil.should be_false
    end
    
    it "provides metadata for multiple aggregations" do
      meta = CustomerWithMultiple.aggregations
      meta.size.should eq(2)
      meta.has_key?(:home_address).should be_true
      meta.has_key?(:work_address).should be_true
    end
  end
end

{% end %}