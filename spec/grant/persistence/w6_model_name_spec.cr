require "../../spec_helper"

module W6Blog
  class Post < Grant::Base
    connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
    table w6_blog_posts

    column id : Int64, primary: true
    column first_name : String?
  end
end

class W6Category < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6_categories

  column id : Int64, primary: true
end

class W6Equipment < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6_equipment

  column id : Int64, primary: true
end

describe "Grant::ModelName" do
  after_each do
    Grant::I18n.locale = "en"
    Grant::I18n.clear_cache
  end

  it "has plural, collection, route_key, singular_route_key and param_key" do
    name = W6Blog::Post.model_name
    name.singular.should eq("w6_blog_post")
    name.plural.should eq("w6_blog_posts")
    name.collection.should eq("w6_blog/posts")
    name.route_key.should eq("w6_blog_posts")
    name.singular_route_key.should eq("w6_blog_post")
    name.param_key.should eq("w6_blog_post")
    name.i18n_key.should eq("w6_blog/post")
    name.element.should eq("post")
  end

  it "pluralizes irregular, y and uncountable names" do
    W6Category.model_name.plural.should eq("w6_categories")
    W6Category.model_name.route_key.should eq("w6_categories")
    W6Equipment.model_name.plural.should eq("w6_equipment")
    W6Equipment.model_name.route_key.should eq("w6_equipment_index")
    W6Equipment.model_name.singular_route_key.should eq("w6_equipment")

    Grant::ModelName.pluralize("person").should eq("people")
    Grant::ModelName.pluralize("box").should eq("boxes")
    Grant::ModelName.pluralize("order_item").should eq("order_items")
    Grant::ModelName.pluralize("blog_post").should eq("blog_posts")
    Grant::ModelName.pluralize("day").should eq("days")
    Grant::ModelName.pluralize("knife").should eq("knives")
    Grant::ModelName.pluralize("photo").should eq("photos")
  end

  describe "human(count:)" do
    it "defaults to the humanized, unpluralized name" do
      W6Category.model_name.human.should eq("W6 category")
      W6Category.model_name.human(count: 2).should eq("W6 category")
    end

    it "prefers the one / other translation for a count" do
      Grant::I18n.store("models.w6_category.one", "Category")
      Grant::I18n.store("models.w6_category.other", "Categories")
      W6Category.model_name.human(count: 1).should eq("Category")
      W6Category.model_name.human(count: 3).should eq("Categories")
      W6Category.model_name.human.should eq("W6 category")
    end

    it "falls back to models.<key> when there is no count translation" do
      Grant::I18n.store("models.w6_equipment", "Gear")
      W6Equipment.model_name.human(count: 2).should eq("Gear")
      W6Equipment.model_name.human.should eq("Gear")
    end
  end

  describe "human_attribute_name" do
    it "titleizes by default and honors translations per locale" do
      W6Blog::Post.human_attribute_name(:first_name).should eq("First name")
      Grant::I18n.store("attributes.w6_blog/post.first_name", "Prenom", "fr")
      Grant::I18n.with_locale("fr") { W6Blog::Post.human_attribute_name(:first_name).should eq("Prenom") }
      W6Blog::Post.human_attribute_name(:first_name).should eq("First name")
    end
  end

  describe "fiber-local locale" do
    it "scopes with_locale to the current fiber and restores it" do
      Grant::I18n.locale.should eq("en")
      Grant::I18n.with_locale("fr") do
        Grant::I18n.locale.should eq("fr")
        Grant::I18n.with_locale("de") { Grant::I18n.locale.should eq("de") }
        Grant::I18n.locale.should eq("fr")
      end
      Grant::I18n.locale.should eq("en")
    end

    it "does not leak into other fibers, so concurrent requests cannot race" do
      Grant::I18n.store("models.w6_category", "Categorie", "fr")
      channel = Channel(String).new
      done = Channel(Nil).new

      spawn do
        Grant::I18n.with_locale("fr") do
          Fiber.yield
          channel.send(W6Category.model_name.human)
          done.receive
        end
      end

      other = W6Category.model_name.human
      french = channel.receive
      done.send(nil)

      other.should eq("W6 category")
      french.should eq("Categorie")
      Grant::I18n.locale.should eq("en")
    end

    it "keeps locale = as the process-wide default" do
      Grant::I18n.locale = "fr"
      W6Category.model_name.human.should eq("Categorie") # stored for fr above
      done = Channel(String).new
      spawn { done.send(Grant::I18n.locale) }
      done.receive.should eq("fr")
    end
  end
end
