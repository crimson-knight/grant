require "json"
require "../../spec_helper"

class F01Settings
  include JSON::Serializable

  property theme : String = "light"
  property items : Array(String) = [] of String

  def initialize(@theme = "light", @items = [] of String)
  end
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class F01Post < Grant::Base
    connection {{ adapter_literal }}
    table f01_posts

    column id : Int64, primary: true
    column title : String?
    column body : String?
    column views : Int32?
  end

  # Array columns without mutation detection.
  class F01Tagged < Grant::Base
    connection {{ adapter_literal }}
    table f01_taggeds

    column id : Int64, primary: true
    column title : String?
    column tags : Array(String)?
  end

  class F01Watched < Grant::Base
    connection {{ adapter_literal }}
    table f01_watcheds

    column id : Int64, primary: true
    column title : String?
    column views : Int32?
    column tags : Array(String)?

    detect_mutation
  end

  class F01WatchedNamed < Grant::Base
    connection {{ adapter_literal }}
    table f01_watched_nameds

    column id : Int64, primary: true
    column tags : Array(String)?
    column labels : Array(String)?

    detect_mutation :tags
  end

  class F01Prefs < Grant::Base
    connection {{ adapter_literal }}
    table f01_prefs

    column id : Int64, primary: true
    column title : String?
    serialized_column :prefs, F01Settings, format: :json

    detect_mutation
  end

  class F01PlainPrefs < Grant::Base
    connection {{ adapter_literal }}
    table f01_plain_prefs

    column id : Int64, primary: true
    serialized_column :prefs, F01Settings, format: :json
  end
{% end %}

F01Post.migrator.drop_and_create
F01Prefs.migrator.drop_and_create
F01PlainPrefs.migrator.drop_and_create

# Array columns exist on PostgreSQL only. The in-memory array examples run on
# every adapter; only the examples that save an array column need the tables.
if CURRENT_ADAPTER == "pg"
  F01Tagged.migrator.drop_and_create
  F01Watched.migrator.drop_and_create
end
