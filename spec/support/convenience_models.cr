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
