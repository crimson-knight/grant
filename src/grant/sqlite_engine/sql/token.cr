module Grant::SQLiteEngine::SQL
  # Token kinds, one per token class of SQLite's tokenizer (tokenize.c) and
  # one per keyword (mkkeywordhash.c). Keywords that SQLite maps to a shared
  # token keep that sharing: LEFT, RIGHT, FULL, INNER, OUTER, CROSS and
  # NATURAL are all `JoinKeyword`; LIKE, GLOB and REGEXP are `LikeKeyword`;
  # the three CURRENT_ keywords are `CurrentTimeKeyword`; TEMP and TEMPORARY
  # are `Temp`.
  enum TokenKind
    EndOfInput
    Illegal
    Identifier # a bare word that is not a keyword, or a "quoted", `quoted` or [bracketed] name
    String     # a 'single-quoted' literal
    Integer
    Float
    QuotedNumber # a number written with `_` digit separators
    Blob
    Variable

    # Punctuation and operators.
    LeftParen
    RightParen
    Semicolon
    Comma
    Dot
    Plus
    Minus
    Star
    Slash
    Remainder
    Equal
    NotEqual
    Less
    LessOrEqual
    Greater
    GreaterOrEqual
    ShiftLeft
    ShiftRight
    BitAnd
    BitOr
    BitNot
    Concat
    Pointer # -> and ->>

    # Keywords, alphabetically.
    Abort
    Action
    Add
    After
    All
    Alter
    Always
    Analyze
    And
    As
    Asc
    Attach
    Autoincrement
    Before
    Begin
    Between
    By
    Cascade
    Case
    Cast
    Check
    Collate
    Column
    Commit
    Conflict
    Constraint
    Create
    Current
    CurrentTimeKeyword
    Database
    Default
    Deferrable
    Deferred
    Delete
    Desc
    Detach
    Distinct
    Do
    Drop
    Each
    Else
    End
    Escape
    Except
    Exclude
    Exclusive
    Exists
    Explain
    Fail
    Filter
    First
    Following
    For
    Foreign
    From
    Generated
    Group
    Groups
    Having
    If
    Ignore
    Immediate
    In
    Index
    Indexed
    Initially
    Insert
    Instead
    Intersect
    Into
    Is
    IsNull
    Join
    JoinKeyword
    Key
    Last
    LikeKeyword
    Limit
    Match
    Materialized
    No
    Not
    Nothing
    NotNull
    Null
    Nulls
    Of
    Offset
    On
    Or
    Order
    Others
    Over
    Partition
    Plan
    Pragma
    Preceding
    Primary
    Query
    Raise
    Range
    Recursive
    References
    Reindex
    Release
    Rename
    Replace
    Restrict
    Returning
    Rollback
    Row
    Rows
    Savepoint
    Select
    Set
    Table
    Temp
    Then
    Ties
    To
    Transaction
    Trigger
    Unbounded
    Union
    Unique
    Update
    Using
    Vacuum
    Values
    View
    Virtual
    When
    Where
    Window
    With
    Without
  end

  # One token: its kind and where its text lies in the statement's bytes.
  record Token, kind : TokenKind, start : Int32, size : Int32 do
    def end_offset : Int32
      @start + @size
    end
  end
end
