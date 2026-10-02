# Models shared by the spec/grant/convenience specs.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class ConvItem < Grant::Base
    connection {{ adapter_literal }}
    table conv_items

    column id : Int64, primary: true
    column name : String
    column status : String?
    column kind : String?
    column qty : Int32?

    validate :name, "Name cannot be blank" do |item|
      !item.name.to_s.blank?
    end

    scope :drafts, ->(q : Grant::Query::Builder(ConvItem)) { q.where(status: "draft") }
    # Returns a plain builder carrying create_with defaults, which the named
    # scope merges into the relation it is called on.
    scope :kinded, -> { ConvItem.create_with(kind: "k").where(qty: 1) }
  end

  # Records what after_initialize saw, to prove attributes and the initializer
  # block are applied before the callback runs.
  class ConvInitItem < Grant::Base
    connection {{ adapter_literal }}
    table conv_init_items

    column id : Int64, primary: true
    column name : String?
    column status : String?
    column seen : String?

    after_initialize :record_seen

    def record_seen
      @seen = "#{@name}/#{@status}"
    end
  end
{% end %}

module ConvenienceSpecSupport
  # Recreates the conv_items table with a unique index on name.
  def self.reset_items : Nil
    ConvItem.migrator.drop_and_create
    index_sql = if CURRENT_ADAPTER == "mysql"
                  "CREATE UNIQUE INDEX idx_conv_items_name ON conv_items(name)"
                else
                  "CREATE UNIQUE INDEX IF NOT EXISTS idx_conv_items_name ON conv_items(name)"
                end
    ConvItem.exec(index_sql)
  end
end
