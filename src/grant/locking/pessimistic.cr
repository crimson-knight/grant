require "../locking"
require "../transaction"

module Grant::Locking::Pessimistic
  macro included
    extend ClassMethods
  end
  
  module ClassMethods
    def lock(mode : LockMode = LockMode::Update)
      query = Query::Builder(self).new(self.name)
      query.lock(mode)
    end
    
    def with_lock(id, mode : LockMode = LockMode::Update, &block : self -> U) : U forall U
      transaction do
        record = where({primary_name => id}).lock(mode).first!
        yield record
      end
    end
    
    def with_lock(mode : LockMode = LockMode::Update, &block : self -> U) : U forall U
      transaction do
        record = lock(mode).first!
        yield record
      end
    end
  end
  
  def with_lock(mode : LockMode = LockMode::Update, &block : self -> U) : U forall U
    self.class.transaction do
      reload_with_lock(mode)
      yield self
    end
  end
  
  def reload_with_lock(mode : LockMode = LockMode::Update) : self
    {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      {% raise "A primary key must be defined for #{@type.name}." unless primary_key %}
      
      fresh = self.class.where({{primary_key.name.stringify}} => @{{primary_key.name.id}}).lock(mode).first!
      
      {% for ivar in @type.instance_vars %}
        {% unless ivar.annotation(Grant::Column) && ivar.annotation(Grant::Column)[:primary] %}
          @{{ivar.name.id}} = fresh.{{ivar.name.id}}
        {% end %}
      {% end %}
      
      self
    {% end %}
  end
  
  def lock!(mode : LockMode = LockMode::Update) : self
    reload_with_lock(mode)
  end
end