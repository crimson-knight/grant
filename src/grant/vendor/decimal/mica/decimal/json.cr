# TEMPORARY development stub (contract only).
require "json"
require "../decimal"

struct Grant::Mica::Decimal128
  def self.new(pull : JSON::PullParser)
    parse(pull.read_string)
  end

  def to_json(json : JSON::Builder) : Nil
    json.string(to_s)
  end
end

struct Grant::Mica::Money
  def self.new(pull : JSON::PullParser)
    amount = nil
    code = nil
    pull.read_object do |key|
      case key
      when "amount"   then amount = pull.read_string
      when "currency" then code = pull.read_string
      else                 pull.skip
      end
    end
    new(amount.not_nil!, code.not_nil!)
  end

  def to_json(json : JSON::Builder) : Nil
    json.object do
      json.field "amount", amount.to_s
      json.field "currency", currency.code
    end
  end
end
