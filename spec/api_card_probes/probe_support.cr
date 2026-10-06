require "../../src/grant"
require "../../src/adapter/sqlite"

module GrantAPICardProbeModels
  class User < Grant::Base
    table :api_card_probe_users

    column id : Int64, primary: true
    column email : String
    column name : String
    column nickname : String?

    macro assert_api_card_name_accessor_exists
      {% unless @type.has_method?(:name?) %}
        {% raise "Grant column getter is missing its name? accessor" %}
      {% end %}
    end

    assert_api_card_name_accessor_exists
  end

  class Post < Grant::Base
    table :api_card_probe_posts

    column id : Int64, primary: true
    column title : String
    column author_id : Int64?
    column status : String?
    column score : Int64?

    macro assert_api_card_find_question_missing
      {% if @type.class.has_method?(:find?) %}
        {% raise "Grant model unexpectedly has a find? method" %}
      {% end %}
    end

    assert_api_card_find_question_missing
  end

  alias NullableInt64 = Int64 | Nil
  alias NullableString = String | Nil
  alias PostOrNil = Post | Nil
  alias ListOfPosts = Array(Post) | Grant::Collection(Post)
end
