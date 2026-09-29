require "./exceptions"
require "./settings"

module Grant
  # Raised when a persistence call fails validation. It is the validation
  # specific `RecordNotSaved`, so `rescue Grant::RecordNotSaved` keeps catching
  # everything `save!` can raise, while `rescue Grant::RecordInvalid` isolates
  # validation failures from callback aborts.
  #
  # Mirrors ActiveRecord's `ActiveRecord::RecordInvalid`.
  #
  # ```
  # begin
  #   User.create!(email: "")
  # rescue ex : Grant::RecordInvalid
  #   ex.message # => "Validation failed: Email can't be blank"
  #   ex.record.errors.full_messages
  # end
  # ```
  class RecordInvalid < RecordNotSaved
    def initialize(model : Grant::Base)
      super(model.class.name, model)
      messages = model.errors.full_messages
      @message = messages.empty? ? "Validation failed" : "Validation failed: #{messages.join(", ")}"
    end

    # The record that failed validation.
    def record : Grant::Base
      model
    end
  end

  # Raised by the bang finders when no row matches. `Grant::Querying::NotFound`
  # is the historical subclass and stays rescuable on its own.
  #
  # Mirrors ActiveRecord's `ActiveRecord::RecordNotFound`.
  class RecordNotFound < ErrorBase
  end

  # Base class for failures of a statement sent to the database. The driver's
  # own exception is kept as `#cause`; `#message` is the driver's message.
  #
  # `#sql` is the failing statement text. `#binds` holds one entry per bound
  # parameter and never retains the raw values: they are redacted unless
  # `Grant.settings.capture_statement_bind_values` is enabled, and even then
  # each value is truncated and only the first `MAX_BINDS` are kept, so an
  # exception cannot pin a large payload in memory or leak a secret to a log.
  #
  # Mirrors ActiveRecord's `ActiveRecord::StatementInvalid`.
  class StatementInvalid < ErrorBase
    MAX_BINDS       = 20
    MAX_BIND_LENGTH = 64
    REDACTED        = "[FILTERED]"

    getter sql : String?
    getter binds : Array(String)

    def initialize(message : String? = nil, @sql : String? = nil, binds : Enumerable? = nil, cause : ::Exception? = nil)
      super(message, cause)
      @binds = StatementInvalid.describe_binds(binds)
    end

    # Renders *binds* for storage on an exception: redacted by default, bounded
    # always.
    def self.describe_binds(binds : Enumerable?) : Array(String)
      described = [] of String
      return described unless binds

      capture = Grant.settings.capture_statement_bind_values?
      binds.each do |value|
        break if described.size >= MAX_BINDS
        described << (capture ? truncate(value.to_s) : REDACTED)
      end
      described
    end

    private def self.truncate(text : String) : String
      text.size > MAX_BIND_LENGTH ? "#{text[0, MAX_BIND_LENGTH]}..." : text
    end
  end

  # A unique index or primary key rejected the write.
  class RecordNotUnique < StatementInvalid
  end

  # A foreign key rejected the write or delete.
  class InvalidForeignKey < StatementInvalid
  end

  # A NOT NULL column received NULL.
  class NotNullViolation < StatementInvalid
  end

  # A value was longer than its column allows.
  class ValueTooLong < StatementInvalid
  end

  # The database aborted the transaction and asked the caller to retry it.
  class TransactionRollbackError < StatementInvalid
  end

  # The transaction could not be serialized against concurrent work.
  class SerializationFailure < TransactionRollbackError
  end

  # The database picked this transaction as the victim of a lock cycle.
  class Deadlocked < TransactionRollbackError
  end

  # A lock could not be acquired in time, or at all for NOWAIT requests.
  class LockWaitTimeout < StatementInvalid
  end

  # The statement ran longer than the server's statement timeout.
  class StatementTimeout < StatementInvalid
  end

  # The statement was canceled before it finished.
  class QueryCanceled < StatementInvalid
  end

  # The database named by the connection does not exist.
  class NoDatabaseError < StatementInvalid
  end

  # Base class for failures to reach or hold a database connection.
  #
  # Mirrors ActiveRecord's `ActiveRecord::ConnectionNotEstablished`.
  class ConnectionNotEstablished < ErrorBase
  end

  # No pooled connection became available before the checkout timeout.
  class ConnectionTimeoutError < ConnectionNotEstablished
  end

  # The server refused or dropped the connection.
  class ConnectionFailed < ConnectionNotEstablished
  end

  # No connection was defined for the model, the same condition as
  # `Grant::AdapterNotAvailableError`.
  alias ConnectionNotDefined = AdapterNotAvailableError

  # A write was attempted while writes are blocked or the transaction is
  # read-only. `Grant::Transaction::ReadOnlyError` is the same class.
  alias ReadOnlyError = Transaction::ReadOnlyError
end
