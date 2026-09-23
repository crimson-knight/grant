{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}

  class T6PersistenceRecord < Grant::Base
    connection {{ adapter_literal }}
    table t6_persistence_records

    column id : Int64, primary: true
    column name : String?
    column note : String?
    column counter : Int32?
    timestamps
  end

  class T6ReadonlyRecord < Grant::Base
    connection {{ adapter_literal }}
    table t6_readonly_records

    column id : Int64, primary: true
    column slug : String

    attr_readonly :slug
  end

  class T6HaltedRecord < Grant::Base
    connection {{ adapter_literal }}
    table t6_halted_records

    column id : Int64, primary: true
    column name : String

    around_save :halt_save

    private def halt_save(continuation : Proc(Nil))
    end
  end

  class T6CommitFailureRecord < Grant::Base
    connection {{ adapter_literal }}
    table t6_commit_failure_records

    column id : Int64, primary: true
    column name : String

    after_commit :raise_after_commit

    private def raise_after_commit
      raise "T6 after_commit failure"
    end
  end

  class T6TouchRecord < Grant::Base
    connection {{ adapter_literal }}
    table t6_touch_records

    column id : Int64, primary: true
    column name : String?
    column note : String?
    column counter : Int32?
    column last_seen_at : Time = Time.utc(2020, 1, 1)
    timestamps

    getter list_of_callback_events : Array(String) = [] of String

    before_save :record_before_save
    before_update :record_before_update
    after_save :record_after_save
    after_touch :record_after_touch

    private def record_before_save
      list_of_callback_events << "before_save"
    end

    private def record_before_update
      list_of_callback_events << "before_update"
    end

    private def record_after_save
      list_of_callback_events << "after_save"
    end

    private def record_after_touch
      list_of_callback_events << "after_touch"
    end
  end

  class T6DeleteRecord < Grant::Base
    connection {{ adapter_literal }}
    table t6_delete_records

    column id : Int64, primary: true
    column name : String

    getter has_destroy_callback_run : Bool = false

    after_destroy :record_destroy_callback

    private def record_destroy_callback
      @has_destroy_callback_run = true
    end
  end
{% end %}
