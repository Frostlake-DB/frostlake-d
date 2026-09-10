/**
 * What can go wrong, and how a caller tells the cases apart.
 *
 * Four kinds, because a caller does something different about each:
 *
 *  $(UL
 *  $(LI $(D UsageException) — this program is wrong. A malformed DSN, a bind
 *       count that does not match the statement, a closed connection reused.
 *       Nothing was sent; fixing the code fixes it.)
 *  $(LI $(D ConnectionException) — the server could not be reached, or stopped
 *       answering mid-exchange. The statement's fate is $(I unknown): it may
 *       have run. Retrying is the caller's decision, not the driver's, which is
 *       why the driver never retries one itself.)
 *  $(LI $(D QueryException) — the engine understood the statement and refused
 *       it. The connection is fine and the session is intact.)
 *  $(LI $(D ValueException) — a cell was read as a type it does not hold.)
 *  )
 *
 * All four derive from $(D FrostlakeException), so `catch (FrostlakeException)`
 * catches everything this library throws and nothing it does not.
 */
module frostlake.errors;

/// Base of every exception this library throws.
class FrostlakeException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow
    {
        super(msg, file, line, next);
    }
}

/// The caller asked for something impossible. Nothing was sent.
class UsageException : FrostlakeException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow
    {
        super(msg, file, line, next);
    }
}

/**
 * The server could not be reached, or stopped answering part way through.
 *
 * When this is thrown from a statement the statement's fate is unknown — it may
 * have reached the engine and run. The driver drops the socket and re-opens on
 * the next call, but never re-sends.
 */
class ConnectionException : FrostlakeException
{
    /// The URL that was being spoken to, as `scheme://host:port/path`.
    string endpoint;
    /// The HTTP status, when one was read before things went wrong; 0 otherwise.
    int status;

    this(string msg, string endpoint = null, int status = 0,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow
    {
        super(msg, file, line, next);
        this.endpoint = endpoint;
        this.status = status;
    }
}

/// The engine refused the statement. The connection and its session are intact.
class QueryException : FrostlakeException
{
    /// The statement as it was sent — after binding, so it is what the engine saw.
    string statement;
    /// The HTTP status the refusal arrived with.
    int status;

    this(string msg, string statement = null, int status = 0,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow
    {
        super(msg, file, line, next);
        this.statement = statement;
        this.status = status;
    }
}

/// A cell was read as a type it does not hold.
class ValueException : FrostlakeException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow
    {
        super(msg, file, line, next);
    }
}

@safe unittest
{
    // Every exception this library throws answers to the one base type.
    auto e = new QueryException("refused", "SELECT 1", 200);
    assert(cast(FrostlakeException) e !is null);
    assert(e.statement == "SELECT 1");
    assert(e.status == 200);

    auto c = new ConnectionException("gone", "http://h:1/api/execute");
    assert(c.endpoint == "http://h:1/api/execute");
    assert(c.status == 0);
}
