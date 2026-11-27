# TEMPORARY development stub (contract only).
require "yaml"
require "../decimal"

struct Grant::Mica::Decimal128
  def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
    parse(String.new(ctx, node))
  end

  def to_yaml(yaml : YAML::Nodes::Builder) : Nil
    yaml.scalar(to_s)
  end
end

struct Grant::Mica::Money
  def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
    hash = Hash(String, String).new(ctx, node)
    new(hash["amount"], hash["currency"])
  end

  def to_yaml(yaml : YAML::Nodes::Builder) : Nil
    {"amount" => amount.to_s, "currency" => currency.code}.to_yaml(yaml)
  end
end
