# Test models for polymorphic associations
{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}
  
  class Comment < Granite::Base
    connection {{ adapter_literal }}
    table comments

    column id : Int64, primary: true
    column content : String

    # Polymorphic association
    belongs_to :commentable, polymorphic: true
  end

  class Image < Granite::Base
    connection {{ adapter_literal }}
    table images

    column id : Int64, primary: true
    column url : String

    # Polymorphic association
    belongs_to :imageable, polymorphic: true
  end

  class Post < Granite::Base
    connection {{ adapter_literal }}
    table posts

    column id : Int64, primary: true
    column name : String

    # Polymorphic associations
    has_many :comments, as: :commentable
    has_one :image, as: :imageable
  end

  class PolyBook < Granite::Base
    connection {{ adapter_literal }}
    table poly_books

    column id : Int64, primary: true
    column name : String

    # Polymorphic associations
    has_many :comments, as: :commentable
    has_one :image, as: :imageable
  end
{% end %}
