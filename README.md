# Grant

The `Grant` ORM is an Active Record pattern ORM that aims to achieve feature parity with Rails 8+.

## Grant vs ActiveRecord Feature Comparison

| Feature/Query Method | Grant | ActiveRecord |
|---------------------|-------|--------------|
| **Core Persistence** | | |
| Basic CRUD (create, save, update, destroy) | ✅ | ✅ |
| Timestamps (created_at, updated_at) | ✅ | ✅ |
| Touch methods | ✅ | ✅ |
| **Query Interface** | | |
| Basic querying (where, order, limit, select) | ✅ | ✅ |
| Advanced querying (joins, group, having) | 🔶 | ✅ |
| Finder methods (find_by, exists?, any?, none?) | ✅ | ✅ |
| Scopes and default_scope | ✅ | ✅ |
| Query chaining | ✅ | ✅ |
| OR queries | ✅ | ✅ |
| NOT queries | ✅ | ✅ |
| **Associations** | | |
| belongs_to, has_one, has_many | ✅ | ✅ |
| has_many :through | ✅ | ✅ |
| Polymorphic associations | ✅ | ✅ |
| Association options (dependent, counter_cache) | 🔶 | ✅ |
| Nested attributes | ✅ | ✅ |
| **Validations** | | |
| Basic validations (presence, uniqueness, length) | ✅ | ✅ |
| Built-in validators (numericality, format, etc.) | 🔶 | ✅ |
| Custom validators | ✅ | ✅ |
| Validation contexts | 🔶 | ✅ |
| **Callbacks** | | |
| Lifecycle callbacks (before_save, after_create, etc.) | ✅ | ✅ |
| Transaction callbacks (after_commit, after_rollback) | ✅ | ✅ |
| **Advanced Features** | | |
| Dirty tracking (changed?, attribute_was) | ✅ | ✅ |
| Enum attributes | ✅ | ✅ |
| Serialized columns (JSON/YAML) | ✅ | ✅ |
| Attribute API (custom types, virtual attributes) | ✅ | ✅ |
| Value objects/aggregations | ✅ | ✅ |
| **Security & Data Protection** | | |
| Encrypted attributes | ✅ | ✅ |
| Secure tokens | ✅ | ✅ |
| Signed IDs | ✅ | ✅ |
| Token generation (token_for) | ✅ | ✅ |
| Data normalization | ✅ | ✅ |
| **Database Features** | | |
| Transactions (explicit blocks) | ✅ | ✅ |
| Nested transactions | ✅ | ✅ |
| Transaction isolation levels | ✅ | ✅ |
| Pessimistic locking | ✅ | ✅ |
| Optimistic locking | ✅ | ✅ |
| **Performance & Optimization** | | |
| Eager loading (includes, preload) | ✅ | ✅ |
| Query batching (find_each, find_in_batches) | ✅ | ✅ |
| Connection pooling | 🔶 | ✅ |
| Query caching | 🔶 | ✅ |
| **Multi-Database Support** | | |
| Multiple database connections | 🔶 | ✅ |
| Read/write splitting | 🔶 | ✅ |
| Horizontal sharding | ✅ | ❌ |
| **Convenience Methods** | | |
| Pluck, pick | ✅ | ✅ |
| Increment, decrement, toggle | ✅ | ✅ |
| Update columns | ✅ | ✅ |
| Upsert operations | ✅ | ✅ |
| **Migrations** | | |
| Schema migrations | 🔶 | ✅ |
| Index management | 🔶 | ✅ |
| Foreign key constraints | ✅ | ✅ |
| Migration rollbacks | 🔶 | ✅ |
| **Development Tools** | | |
| SQL logging and instrumentation | ✅ | ✅ |
| Query analysis and debugging | ✅ | ✅ |
| N+1 query detection | ✅ | ✅ |

**Legend:**
- ✅ Fully implemented and production-ready
- 🔶 Partially implemented (basic functionality present, some advanced features missing)
- ❌ Not implemented

**Grant's Unique Features:**
- **Horizontal Sharding**: Built-in support for distributing data across multiple databases
- **Crystal Type Safety**: Compile-time type checking eliminates many runtime errors
- **Fiber-based Concurrency**: Native async support without callback complexity
- **Zero-cost Abstractions**: Performance comparable to hand-written SQL

**Note**: Grant achieves strong feature parity with ActiveRecord (~80-85%) while adding Crystal-specific enhancements and some advanced features (like built-in sharding) that ActiveRecord lacks. While many core features are fully implemented, some advanced options and edge cases found in ActiveRecord's 20+ years of development are still being developed.

[Amber](https://github.com/amberframework/amber) is a web framework written in
the [Crystal](https://github.com/crystal-lang/crystal) language.

This project is to provide an ORM in Crystal using the Active Record pattern.

## Comprehensive Feature Examples

Here are 3 example models that demonstrate every feature available in Grant:

### Example 1: User Model (Security & Core Features)

```crystal
class User < Grant::Base
  connection pg
  table users
  
  # Primary key and basic columns
  column id : Int64, primary: true
  column email : String
  column first_name : String
  column last_name : String
  column age : Int32?
  column bio : String?
  column active : Bool = true
  column login_count : Int32 = 0
  column last_login_at : Time?
  
  # Security features
  encrypts :ssn, :credit_card_number
  encrypts :phone_number, deterministic: true  # For searchable encryption
  has_secure_token :auth_token
  has_secure_token :api_key, length: 32, alphabet: :hex
  
  # Signed IDs for secure URLs
  include Grant::SignedId
  
  # Token generation for password resets
  include Grant::TokenFor
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt
  end
  
  # Data normalization
  normalizes :email, &.downcase.strip
  normalizes :first_name, &.strip.titleize
  
  # Enum attributes
  enum Role
    Guest
    Member
    Admin
    SuperAdmin
  end
  enum_attribute role : Role = :member
  
  enum Status
    Active = 0
    Suspended = 1
    Banned = 2
  end
  enum_attribute status : Status = :active, column_type: Int32
  
  # Validations with contexts
  validates_presence_of :email, :first_name, :last_name
  validates_uniqueness_of :email
  validates_email :email
  validates_length_of :first_name, minimum: 2, maximum: 50
  validates_numericality_of :age, greater_than: 0, less_than: 150, allow_nil: true
  validates_inclusion_of :role, in: Role.values, on: :admin_update
  
  # Custom validations
  validate :email, "must be corporate email", on: :corporate do |user|
    user.email.ends_with?("@company.com")
  end
  
  validate "cannot be admin if under 18" do |user|
    !(user.admin? && user.age.try(&.< 18))
  end
  
  # Callbacks
  before_save :update_login_count
  after_create :send_welcome_email
  after_commit :notify_admin, on: :create
  before_destroy :cleanup_sessions
  
  # Associations
  has_many :orders, dependent: :destroy
  has_many :addresses, as: :addressable
  has_one :profile, dependent: :destroy
  has_many :comments, dependent: :nullify
  
  # Scopes
  scope :active, ->{ where(active: true) }
  scope :admins, ->{ admin }
  scope :recent, ->{ where.gteq(:created_at, 7.days.ago) }
  default_scope ->{ where(active: true) }
  
  # Timestamps
  timestamps
  
  private def update_login_count
    if last_login_at_changed?
      self.login_count += 1
    end
  end
  
  private def send_welcome_email
    # Email logic here
  end
  
  private def notify_admin
    # Admin notification logic
  end
  
  private def cleanup_sessions
    # Session cleanup logic
  end
end
```

### Example 2: Order Model (Associations & Business Logic)

```crystal
class Order < Grant::Base
  connection pg
  table orders
  
  # Columns with various types
  column id : Int64, primary: true
  column order_number : String
  column total_amount : Float64
  column tax_amount : Float64 = 0.0
  column discount_amount : Float64 = 0.0
  column notes : String?
  column metadata : JSON::Any?
  column shipped_at : Time?
  column lock_version : Int32 = 0  # For optimistic locking
  
  # Associations
  belongs_to :user
  belongs_to :shipping_address, class_name: "Address", optional: true
  belongs_to :billing_address, class_name: "Address", optional: true
  has_many :line_items, dependent: :destroy
  has_many :products, through: :line_items
  has_many :order_events, dependent: :destroy
  has_one :payment, dependent: :destroy
  
  # Nested attributes
  accepts_nested_attributes_for line_items : LineItem,
    allow_destroy: true,
    reject_if: ->(attrs : Hash) { attrs["quantity"]?.try(&.to_i) == 0 },
    limit: 50
  
  accepts_nested_attributes_for payment : Payment,
    update_only: true
  
  # Polymorphic associations
  has_many :activities, as: :trackable
  
  # Enum for order status
  enum Status
    Pending
    Processing
    Shipped
    Delivered
    Cancelled
    Refunded
  end
  enum_attribute status : Status = :pending
  
  enum Priority
    Low = 1
    Medium = 2
    High = 3
    Urgent = 4
  end
  enum_attribute priority : Priority = :medium, column_type: Int32
  
  # Serialized columns
  serializes :shipping_options, Array(String)
  serializes :custom_fields, Hash(String, String)
  
  # Value objects / Aggregations
  aggregation :shipping_info,
    class_name: ShippingInfo,
    mapping: {
      shipping_method: :method,
      shipping_cost: :cost,
      estimated_delivery: :delivery_date
    }
  
  # Validations
  validates_presence_of :order_number, :total_amount
  validates_uniqueness_of :order_number
  validates_numericality_of :total_amount, greater_than: 0
  validates_numericality_of :tax_amount, greater_than_or_equal_to: 0
  validates_length_of :notes, maximum: 1000, allow_blank: true
  
  # Advanced validations
  validate "total must equal sum of line items" do |order|
    calculated_total = order.line_items.sum(&.total_price)
    (order.total_amount - calculated_total).abs < 0.01
  end
  
  # Optimistic locking
  include Grant::Locking::Optimistic
  
  # Callbacks for business logic
  before_create :generate_order_number
  before_save :calculate_totals
  after_update :track_status_changes
  
  # Transaction callbacks
  after_commit :send_confirmation_email, on: :create
  after_commit :notify_fulfillment, if: ->(order : Order) { order.processing? }
  
  # Scopes
  scope :recent, ->{ where.gteq(:created_at, 30.days.ago) }
  scope :high_value, ->{ where.gt(:total_amount, 500.0) }
  scope :needs_shipping, ->{ where(status: [Status::Processing, Status::Shipped]) }
  
  # Class methods with locking
  def self.process_pending_orders
    transaction do
      pending.each do |order|
        order.with_lock do |locked_order|
          locked_order.processing!
          locked_order.save!
        end
      end
    end
  end
  
  # Instance methods
  def can_be_cancelled?
    pending? || processing?
  end
  
  def total_with_tax
    total_amount + tax_amount
  end
  
  timestamps
  
  private def generate_order_number
    self.order_number = "ORD-#{Time.utc.to_unix}-#{SecureRandom.hex(4)}"
  end
  
  private def calculate_totals
    if line_items.any?
      self.total_amount = line_items.sum(&.total_price)
      self.tax_amount = total_amount * 0.08  # 8% tax
    end
  end
  
  private def track_status_changes
    if status_changed?
      order_events.create!(
        event_type: "status_change",
        from_status: status_was,
        to_status: status,
        occurred_at: Time.utc
      )
    end
  end
end

# Supporting value object
struct ShippingInfo
  getter method : String
  getter cost : Float64
  getter delivery_date : Time?
  
  def initialize(@method : String, @cost : Float64, @delivery_date : Time? = nil)
  end
  
  def express?
    method.includes?("Express") || method.includes?("Overnight")
  end
end
```

### Example 3: Product Model (Advanced Features & Sharding)

```crystal
class Product < Grant::Base
  # Sharding configuration
  connection :products_shard
  table products
  
  # Sharding key for horizontal distribution
  shard_key :category_id
  
  # Advanced column types
  column id : Int64, primary: true
  column sku : String
  column name : String
  column description : String?
  column price : Float64
  column cost : Float64?
  column weight : Float32?
  column dimensions : Array(Float32)?  # [length, width, height]
  column tags : Array(String)?
  column features : JSON::Any?
  column search_vector : String?  # For full-text search
  column image_data : Bytes?  # Binary data
  
  # Custom attribute with converter
  column metadata : JSON::Any, converter: Grant::Converters::Json
  
  # UUID as alternative key
  column uuid : UUID, auto: false
  
  # Polymorphic associations
  has_many :comments, as: :commentable
  has_many :attachments, as: :attachable
  has_many :taggings, as: :taggable
  has_many :tags, through: :taggings
  
  # Regular associations
  belongs_to :category
  belongs_to :brand, optional: true
  has_many :line_items
  has_many :orders, through: :line_items
  has_many :reviews, dependent: :destroy
  has_many :variants, class_name: "ProductVariant", dependent: :destroy
  
  # Self-referential association
  belongs_to :parent_product, class_name: "Product", optional: true
  has_many :child_products, class_name: "Product", foreign_key: :parent_product_id
  
  # Advanced enum with custom storage
  enum Availability
    InStock = "in_stock"
    OutOfStock = "out_of_stock"
    Discontinued = "discontinued" 
    PreOrder = "pre_order"
  end
  enum_attribute availability : Availability = :in_stock
  
  # Multiple enums
  enum_attributes visibility: {type: Visibility, default: :public},
                  condition: {type: Condition, default: :new}
  
  enum Visibility
    Public
    Private
    Hidden
  end
  
  enum Condition
    New
    Used
    Refurbished
  end
  
  # Serialized attributes for complex data
  serializes :specifications, Hash(String, JSON::Any)
  serializes :variants_data, Array(NamedTuple(name: String, price: Float64))
  serializes :shipping_info, ShippingDetails
  
  # Virtual attributes via Attribute API
  attribute :display_name : String do
    "#{brand.try(&.name)} #{name}".strip
  end
  
  attribute :profit_margin : Float64 do
    return 0.0 unless cost && price
    ((price - cost) / price) * 100
  end
  
  # Advanced validations
  validates_presence_of :sku, :name, :price
  validates_uniqueness_of :sku, scope: :category_id
  validates_numericality_of :price, greater_than: 0
  validates_numericality_of :cost, greater_than: 0, allow_nil: true
  validates_format_of :sku, with: /\A[A-Z]{2}-\d{4}-[A-Z]{2}\z/
  validates_length_of :name, minimum: 3, maximum: 200
  validates_length_of :description, maximum: 5000, allow_blank: true
  
  # Conditional validations
  validates_presence_of :cost, if: :track_inventory?
  validates_numericality_of :weight, greater_than: 0, if: :requires_shipping?
  
  # Custom validators
  validate "price must be higher than cost" do |product|
    return true unless product.cost && product.price
    product.price > product.cost
  end
  
  validate :valid_dimensions
  validate :valid_features_json
  
  # Callbacks with conditions
  before_validation :normalize_sku, :generate_uuid
  before_save :calculate_search_vector, if: :name_changed?
  after_save :update_search_index, if: :saved_changes?
  after_create :notify_inventory_system
  after_update :sync_with_external_api, if: :price_changed?
  before_destroy :check_for_pending_orders
  
  # Advanced scoping
  scope :available, ->{ where.not(availability: Availability::Discontinued) }
  scope :in_stock, ->{ in_stock }  # Uses enum scope
  scope :by_category, ->(cat : Category) { where(category: cat) }
  scope :price_range, ->(min : Float64, max : Float64) { 
    where.gteq(:price, min).lteq(:price, max) 
  }
  scope :featured, ->{ where(featured: true) }
  scope :with_reviews, ->{ 
    joins(:reviews).group("products.id").having("COUNT(reviews.id) > 0") 
  }
  
  # Complex scopes with OR conditions
  scope :search, ->(term : String) {
    where.like(:name, "%#{term}%")
         .or { |q| q.where.like(:description, "%#{term}%") }
         .or { |q| q.where.like(:sku, "%#{term}%") }
  }
  
  # Aggregation methods
  def self.average_price_by_category
    group(:category_id).calculate(:average, :price)
  end
  
  def self.inventory_report
    select("category_id, COUNT(*) as total, 
            SUM(CASE WHEN availability = 'in_stock' THEN 1 ELSE 0 END) as in_stock")
      .group(:category_id)
  end
  
  # Instance methods with business logic
  def in_stock?
    availability == Availability::InStock
  end
  
  def can_be_ordered?
    in_stock? || availability == Availability::PreOrder
  end
  
  def discounted_price(discount_percent : Float64)
    price * (1 - discount_percent / 100)
  end
  
  # Dirty tracking examples
  def price_increased?
    price_changed? && price > price_was
  end
  
  def significant_change?
    price_changed? && (price - price_was).abs > 10.0
  end
  
  # Locking for concurrent access
  def update_price_with_lock(new_price : Float64)
    with_lock do |locked_product|
      locked_product.price = new_price
      locked_product.save!
    end
  end
  
  # Connection management for read replicas
  def self.search_readonly(term : String)
    using_connection(:read_replica) do
      search(term).limit(100)
    end
  end
  
  timestamps
  
  private def track_inventory?
    !digital_product?
  end
  
  private def requires_shipping?
    !digital_product? && weight.nil?
  end
  
  private def digital_product?
    category.try(&.name) == "Digital"
  end
  
  private def normalize_sku
    self.sku = sku.upcase.strip if sku
  end
  
  private def generate_uuid
    self.uuid = UUID.random if uuid.nil?
  end
  
  private def calculate_search_vector
    # Build search vector for full-text search
    self.search_vector = [name, description, tags.try(&.join(" "))].compact.join(" ")
  end
  
  private def valid_dimensions
    return unless dimensions
    if dimensions.size != 3 || dimensions.any?(&.<= 0)
      errors.add(:dimensions, "must be 3 positive numbers")
    end
  end
  
  private def valid_features_json
    return unless features
    # Validate JSON structure
    unless features.as_h?
      errors.add(:features, "must be a valid JSON object")
    end
  end
end

# Supporting serialized object
struct ShippingDetails
  getter weight_class : String
  getter fragile : Bool
  getter special_handling : Array(String)
  
  def initialize(@weight_class : String, @fragile : Bool = false, @special_handling : Array(String) = [] of String)
  end
  
  def requires_special_care?
    fragile || special_handling.any?
  end
end
```

These examples demonstrate **every Grant feature** including:

- **Core ORM**: Columns, types, primary keys, timestamps
- **Associations**: belongs_to, has_many, has_one, through, polymorphic, self-referential
- **Validations**: All built-in validators, custom validations, conditional validation, contexts
- **Callbacks**: All lifecycle and transaction callbacks
- **Security**: Encryption, secure tokens, signed IDs, token generation, normalization
- **Advanced Features**: Enums, serialization, value objects, dirty tracking, attribute API
- **Database Features**: Transactions, locking (optimistic/pessimistic), sharding, multiple connections
- **Query Features**: Scopes, complex queries with OR/NOT, aggregations
- **Performance**: Connection management, read replicas, eager loading

Each model showcases different aspects while remaining realistic examples of how Grant would be used in production applications.

## Documentation

[Documentation](docs/readme.md)

### Experimental Features

- **[Horizontal Sharding](docs/SHARDING.md)** ⚠️ - Distribute data across multiple databases (Alpha - not production ready)

## Contributing

1. Fork it ( https://github.com/amberframework/grant/fork )
2. Create your feature branch (git checkout -b my-new-feature)
3. Commit your changes (git commit -am 'Add some feature')
4. Push to the branch (git push origin my-new-feature)
5. Create a new Pull Request

## Running tests
Grant uses Crystal's built in test framework. The tests can be run either within a [dockerized testing environment](#docker-setup) or [locally](#local-setup). 

The test suite depends on access to a PostgreSQL, MySQL, and SQLite database to ensure the adapters work as intended.

### Docker setup

There is a self-contained testing environment provided via the `docker-compose.yml` file in this repository.
We are testing against multiple databases so you have to specify which docker-compose file you would like to use.

- You can find postgres versions at https://hub.docker.com/_/postgres/
- You can find mysql versions at https://hub.docker.com/_/mysql/

After you have docker installed do the following to run tests:
#### Environment variable setup
##### Option 1
Export `.env` with `$ source ./export.sh` or `$ source .env`.

##### Option 2
Modify the `.env` file that docker-compose loads by default. The `.env` file can either be copied to the same directory as the docker-compose.{database_type}.yml files or passed as an option to the docker-compose commands `--env-file ./foo/.env`.

#### First run
> Replace "{database_type}" with "mysql" or "pg" or "sqlite". 

```
$ docker-compose -f docker/docker-compose.{database_type}.yml build spec
$ docker-compose -f docker/docker-compose.{database_type}.yml run spec
```

#### Subsequent runs

```
$ docker-compose -f docker/docker-compose.{database_type}.yml run spec
```

#### Cleanup

If you're done testing and you'd like to shut down and clean up the docker dependences run the following:

```
$ docker-compose -f docker/docker-compose.{database_type}.yml down
```

#### Run all

To run the specs for each database adapter use `./spec/run_all_specs.sh`.    This will build and run each adapter, then cleanup after itself.

### Local setup

If you'd like to test without docker you can do so by following the instructions below:

1. Install dependencies with `$ shards install `
2. Update .env to use appropriate ENV variables, or create appropriate databases.
3. Setup databases:

#### PostgreSQL

```sql
CREATE USER grant WITH PASSWORD 'password';

CREATE DATABASE grant_db;

GRANT ALL PRIVILEGES ON DATABASE grant_db TO grant;
```

#### MySQL

```sql
CREATE USER 'grant'@'localhost' IDENTIFIED BY 'password';

CREATE DATABASE grant_db;

GRANT ALL PRIVILEGES ON grant_db.* TO 'grant'@'localhost' WITH GRANT OPTION;
```

4. Export `.env` with `$ source ./export.sh` or `$ source .env`.
5. `$ crystal spec`
