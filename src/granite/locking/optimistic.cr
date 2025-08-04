require "../locking"

module Granite::Locking::Optimistic
  class StaleObjectError < Exception
    getter record_class : String
    getter record_id : String?
    
    def initialize(record : Granite::Base)
      @record_class = record.class.name
      {% begin %}
        {% primary_key = record.class.instance_vars.find { |ivar| (ann = ivar.annotation(Granite::Column)) && ann[:primary] } %}
        @record_id = record.{{primary_key.name.id}}.to_s if record.responds_to?(:{{primary_key.name.id}})
      {% end %}
      
      message = if id = @record_id
        "Attempted to update a stale #{@record_class} (id: #{id})"
      else
        "Attempted to update a stale #{@record_class}"
      end
      
      super(message)
    end
  end
  
  macro included
    column lock_version : Int32 = 0
    
    before_update :__check_lock_version
    after_update :__increment_lock_version
    
    @lock_version_was : Int32 = 0
    @lock_conflict_retry_count : Int32 = 0
    
    class_property lock_conflict_max_retries : Int32 = 0
  end
  
  def lock_version_was : Int32
    @lock_version_was
  end
  
  def lock_version_changed? : Bool
    lock_version != @lock_version_was
  end
  
  def with_optimistic_retry(max_retries : Int32 = self.class.lock_conflict_max_retries, &block)
    retry_count = 0
    
    loop do
      begin
        yield
        break
      rescue ex : StaleObjectError
        retry_count += 1
        if retry_count > max_retries
          raise ex
        end
        
        reload
        @lock_conflict_retry_count = retry_count
      end
    end
    
    @lock_conflict_retry_count = 0
  end
  
  private def __check_lock_version
    return true unless persisted?
    return true if @lock_version_was == 0 && lock_version == 0
    
    @lock_version_was = lock_version_was.presence || attribute_before_last_save("lock_version").as(Int32)
    
    {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Granite::Column)) && ann[:primary] } %}
      {% raise "A primary key must be defined for #{@type.name}." unless primary_key %}
      
      affected_rows = self.class.adapter.open do |db|
        fields = self.class.content_fields.dup
        values = content_values.dup
        
        if created_at_index = fields.index("created_at")
          fields.delete_at created_at_index
          values.delete_at created_at_index
        end
        
        fields_clause = fields.map { |f| "#{self.class.adapter.quote(f)} = ?" }.join(", ")
        where_clause = "#{self.class.adapter.quote({{primary_key.name.stringify}})} = ? AND #{self.class.adapter.quote("lock_version")} = ?"
        
        statement = "UPDATE #{self.class.adapter.quote(self.class.table_name)} SET #{fields_clause} WHERE #{where_clause}"
        params = values + [@{{primary_key.name.id}}, @lock_version_was]
        
        result = db.exec(statement, args: params)
        
        case self.class.adapter
        when Granite::Adapter::Pg
          result.rows_affected
        when Granite::Adapter::Mysql
          result.rows_affected
        when Granite::Adapter::Sqlite
          db.scalar("SELECT changes()").as(Int64)
        else
          1_i64
        end
      end
      
      if affected_rows == 0
        raise StaleObjectError.new(self)
      end
      
      true
    {% end %}
  rescue ex : StaleObjectError
    raise ex
  rescue ex
    raise ex
  end
  
  private def __increment_lock_version
    @lock_version = lock_version + 1
    @lock_version_was = lock_version
  end
  
  private def attribute_before_last_save(name : String)
    case name
    when "lock_version"
      @lock_version_was
    else
      nil
    end
  end
  
  def reload
    super
    @lock_version_was = lock_version
    self
  end
  
  macro finished
    def save(*, validate : Bool = true, skip_timestamps : Bool = false)
      if new_record?
        super
      else
        @lock_version_was = lock_version
        
        previous_def
      end
    end
  end
end