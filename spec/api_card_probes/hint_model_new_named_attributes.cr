require "./probe_support"

class AutosaveCompany < Grant::Base
  table :api_card_probe_autosave_companies

  column id : Int64, primary: true
  column name : String
end

class EnumArticle < Grant::Base
  table :api_card_probe_enum_articles

  enum Status
    Draft
    Published
  end

  column id : Int64, primary: true
  column status : Status
end

def assert_autosave_company(value : T) forall T
  {% unless T == AutosaveCompany %}
    {% raise "Grant create! must return the model" %}
  {% end %}
end

company = AutosaveCompany.create!(name: "ACME Corp")
article = EnumArticle.new
article.status = EnumArticle::Status::Published
assert_autosave_company(company)
