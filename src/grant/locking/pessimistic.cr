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
      result : U? = nil
      transaction do
        record = where({primary_name => id}).lock(mode).first!
        result = block.call(record)
      end
      result.not_nil!
    end

    def with_lock(mode : LockMode = LockMode::Update, &block : self -> U) : U forall U
      result : U? = nil
      transaction do
        record = lock(mode).first!
        result = block.call(record)
      end
      result.not_nil!
    end
  end

  def with_lock(mode : LockMode = LockMode::Update, &block : self -> U) : U forall U
    result : U? = nil
    self.class.transaction do
      reload_with_lock(mode)
      result = block.call(self)
    end
    result.not_nil!
  end

  def reload_with_lock(mode : LockMode = LockMode::Update) : self
    {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      {% raise "A primary key must be defined for #{@type.name}." unless primary_key %}

      fresh = self.class.where({{primary_key.name.id}}: @{{primary_key.name.id}}).lock(mode).first!

      # Copy only @[Grant::Column] annotated instance variables from the fresh record
      {% for ivar in @type.instance_vars %}
        {% if ivar.annotation(Grant::Column) %}
          @{{ivar.name.id}} = fresh.@{{ivar.name.id}}
        {% end %}
      {% end %}

      self
    {% end %}
  end

  def lock!(mode : LockMode = LockMode::Update) : self
    reload_with_lock(mode)
  end
end
