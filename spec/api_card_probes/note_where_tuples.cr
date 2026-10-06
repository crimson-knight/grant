require "./probe_support"

class Post < Grant::Base
  table :api_card_probe_composite_criteria_posts

  column id : Int64, primary: true
  column shop_id : Int64
  column order_id : Int64
end

def assert_composite_criteria_where_returns_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(Post) %}
    {% raise "Post.where criteria must return a Post query builder" %}
  {% end %}
end

assert_composite_criteria_where_returns_builder(Post.where(shop_id: 1_i64, order_id: 1_i64))
