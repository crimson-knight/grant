# Test models for polymorphic associations
{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}
  
  class Comment < Grant::Base
    connection {{ adapter_literal }}
    table comments

    column id : Int64, primary: true
    column content : String

    # Polymorphic association
    belongs_to :commentable, polymorphic: true, optional: true
  end

  class Image < Grant::Base
    connection {{ adapter_literal }}
    table images

    column id : Int64, primary: true
    column url : String

    # Polymorphic association
    belongs_to :imageable, polymorphic: true, optional: true
  end

  class Post < Grant::Base
    connection {{ adapter_literal }}
    table posts

    column id : Int64, primary: true
    column name : String

    # Polymorphic associations
    has_many :comments, as: :commentable, class_name: "Comment"
    has_one :image, as: :imageable, class_name: "Image"
  end

  class PolyBook < Grant::Base
    connection {{ adapter_literal }}
    table poly_books

    column id : Int64, primary: true
    column name : String

    # Polymorphic associations
    has_many :comments, as: :commentable, class_name: "Comment"
    has_one :image, as: :imageable, class_name: "Image"
  end
{% end %}
