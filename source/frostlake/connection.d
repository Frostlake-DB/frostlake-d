/**
 * A connection to a Frostlake HTTP server, and the engine session behind it.
 *
 * The connection is the one thing in this package with a lifetime: it owns a
 * socket and a server-side session. Results, columns, cells and configs are all
 * plain values, so nothing else has to be closed or freed.
 *
 * Statements are serialised over the one session, which is what makes session
 * state — `USE`, session variables, an open transaction — carry from one
 * statement to the next.
 */
module frostlake.connection;

import core.time : Duration, MonoTime;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.string : toLower, startsWith;
import std.traits : isAssociativeArray;

import frostlake.bind : bindNamed, bindNames, bindPositional;
import frostlake.dsn : DsnConfig, parseDsn;
import frostlake.errors;
import frostlake.http : HttpClient, HttpResponse, snippet;
import frostlake.json : encodeJsonString, JsonValue, parseJson;
import frostlake.result : Column, Result, Value;
import frostlake.sql : changesScope;
import frostlake.value : Param, toParam;

/**
 * What may be set at connect time, over and above what the DSN says.
 *
 * Every field here can also be given in the DSN query string; an option set
 * here outranks it. A zero $(D Duration) means "no bound".
 */
struct ConnectOptions
{
    Duration timeout = Duration.zero;
    Duration connectTimeout = Duration.zero;
    Duration idleLimit = Duration.zero;
    string database;
    string schema;
    string role;
    string warehouse;

    private bool hasTimeout() const @safe pure nothrow @nogc { return timeout != Duration.zero; }
    private bool hasConnectTimeout() const @safe pure nothrow @nogc { return connectTimeout != Duration.zero; }
    private bool hasIdleLimit() const @safe pure nothrow @nogc { return idleLimit != Duration.zero; }
}

/**
 * An open connection.
 *
 * A connection belongs to one thread. It carries one session, and two
 * statements half-interleaved on one session would corrupt exactly the state a
 * session exists to keep — so a second statement started while the first is in
 * flight is refused rather than half-done.
 */
final class Connection
{
    private DsnConfig config_;
    private HttpClient client;
    private string sessionId_;
    private bool autoCommit_ = true;
    private bool closed_;
    private bool busy;

    /// `USE` statements still owed to the session, in dependency order.
    private string[] pendingUse;
    /// The scope the DSN named, kept so a lapsed session can be put back on it.
    private string[] sessionDefaults;
    /// Whether the caller has selected a scope themselves; once they have, the
    /// DSN's defaults are no longer the whole truth about this session.
    private bool sessionTouched;

    private MonoTime lastUsed;
    private bool everUsed;

    /**
     * Opens a connection and selects the scope the DSN names.
     *
     * The server is contacted before the constructor returns: its health
     * endpoint is called, and the `USE` statements are run. A database that
     * does not exist is therefore reported here, rather than surfacing later on
     * whichever query happened to run first.
     */
    this(string dsn, ConnectOptions options = ConnectOptions.init) @safe
    {
        config_ = parseDsn(dsn);

        if (options.hasTimeout) config_.timeout = options.timeout;
        if (options.hasConnectTimeout) config_.connectTimeout = options.connectTimeout;
        if (options.hasIdleLimit) config_.idleLimit = options.idleLimit;
        if (options.database.length) config_.database = options.database;
        if (options.schema.length) config_.schema = options.schema;
        if (options.role.length) config_.role = options.role;
        if (options.warehouse.length) config_.warehouse = options.warehouse;

        client = new HttpClient(config_);
        sessionDefaults = config_.useStatements();
        pendingUse = sessionDefaults.dup;

        try
        {
            ping();
            applyScope();
        }
        catch (Exception e)
        {
            release();
            throw e;
        }
    }

    /**
     * Closes the connection. Safe to call more than once.
     *
     * There is deliberately no destructor to fall back on: a class destructor
     * runs during a collection, where reaching for another GC-managed object —
     * the client, its socket — is not valid. $(D std.socket.Socket) closes its
     * own handle when it is finalised, so a forgotten connection still gives
     * its socket back eventually; `scope (exit) conn.close()` gives it back
     * when the caller meant to.
     */
    void close() @safe nothrow
    {
        release();
    }

    private void release() @safe nothrow
    {
        closed_ = true;
        if (client !is null) client.disconnect();
    }

    // ------------------------------------------------------------ reporting

    /// The engine's id for this connection's session, once it has one.
    @property string sessionId() const @safe pure nothrow @nogc { return sessionId_; }

    /// Whether a transaction is open — `begin` without a matching `commit` or
    /// `rollback`.
    @property bool inTransaction() const @safe pure nothrow @nogc { return !autoCommit_; }

    /// The server this connection speaks to, as `scheme://host:port`.
    @property string baseUrl() const @safe pure { return config_.baseUrl; }

    /// The parsed DSN, with any connect-time options folded in.
    @property DsnConfig configuration() const @safe pure nothrow @nogc { return config_; }

    @property bool isOpen() const @safe pure nothrow @nogc { return !closed_; }

    // ----------------------------------------------------------- statements

    /**
     * Runs one statement and returns its first result set.
     *
     * ---
     * conn.execute("SELECT 1");
     * conn.execute("INSERT INTO people VALUES (?, ?)", 1, "Ada");
     * conn.execute("SELECT :a + :b AS total", ["a": 2, "b": 40]);
     * ---
     *
     * Whether the arguments are read as positional or named is decided by the
     * $(I statement): `?` markers take positional arguments, `:name` markers
     * take an associative array. Passing an associative array selects named
     * binding whatever the statement says, which is the one case where the
     * argument decides — and a mismatch is reported rather than guessed at.
     */
    Result execute(Args...)(string sql, Args args) @safe
    {
        auto sets = executeAll(sql, args);
        return sets[0];
    }

    /**
     * Runs a statement string and returns every result set it produced, in
     * order. A single statement gives a one-element array.
     */
    Result[] executeAll(Args...)(string sql, Args args) @safe
    {
        return run(sql, render(sql, args));
    }

    /// Runs one statement with parameters built at runtime.
    Result executePositional(string sql, const(Param)[] params) @safe
    {
        return run(sql, bindPositional(sql, params))[0];
    }

    /// ditto
    Result executeNamed(string sql, const(Param[string]) params) @safe
    {
        return run(sql, bindNamed(sql, params))[0];
    }

    /**
     * Renders a statement with its parameters inlined, without sending it.
     * Useful for logging, and for seeing what a bind actually produced.
     *
     * Warning: the result holds bound values verbatim — a password bound into a
     * statement appears in it in the clear.
     */
    string render(Args...)(string sql, Args args) @safe
    {
        static if (Args.length == 1 && isAssociativeArray!(Args[0]))
        {
            Param[string] named;
            foreach (key, value; args[0])
                named[key] = toParam(value);
            return bindNamed(sql, named);
        }
        else
        {
            auto params = appender!(Param[]);
            static foreach (i; 0 .. Args.length)
                params.put(toParam(args[i]));
            return bindPositional(sql, params.data);
        }
    }

    // --------------------------------------------------------- transactions

    /// Opens a transaction: autocommit goes off and `BEGIN` is sent.
    void begin() @safe
    {
        enter();
        scope (exit) leave();
        // As before any statement: if the session may have been reclaimed while
        // idle, the DSN's scope goes back on first, or the whole transaction
        // would run in the engine's default scope.
        restoreSessionDefaults();
        drainPendingUse();
        autoCommit_ = false;
        try
            roundTrip("BEGIN");
        catch (Exception e)
        {
            autoCommit_ = true;
            throw e;
        }
    }

    /// Commits the open transaction and restores autocommit.
    void commit() @safe
    {
        enter();
        scope (exit) { autoCommit_ = true; leave(); }
        roundTrip("COMMIT");
    }

    /// Rolls the open transaction back and restores autocommit.
    void rollback() @safe
    {
        enter();
        scope (exit) { autoCommit_ = true; leave(); }
        roundTrip("ROLLBACK");
    }

    /**
     * Runs `work` between `BEGIN` and `COMMIT`, rolling back if it throws and
     * re-raising the original exception either way.
     *
     * ---
     * conn.transaction({ conn.execute("INSERT INTO acc VALUES (1)"); });
     * ---
     *
     * The connection is $(I not) held for the duration: a transaction lives on
     * the session, so anything else run on this same connection meanwhile joins
     * the transaction. Give a transaction its own connection if that is not
     * what you want.
     */
    void transaction(scope void delegate() @safe work) @safe
    {
        begin();
        try
            work();
        catch (Exception e)
        {
            // A failed rollback must not replace the error that caused it.
            try rollback();
            catch (Exception) { }
            throw e;
        }
        commit();
    }

    // ------------------------------------------------------------ transport

    /**
     * Checks that a Frostlake engine is answering, via `GET /api/health`.
     *
     * A 200 on its own only says something is listening — anything can serve
     * that. The health payload is what says it is an engine, so a body that is
     * not one is reported rather than passed off as healthy.
     */
    void ping() @safe
    {
        enter();
        scope (exit) leave();
        const endpoint = baseUrl ~ "/api/health";
        auto answer = send("GET", "/api/health", "");
        if (answer.status != 200)
            throw new ConnectionException(format!"%s answered HTTP %s: %s"(
                endpoint, answer.status, snippet(answer.content)), endpoint, answer.status);
        auto health = decode(endpoint, answer);
        if (!health.has("status"))
            throw new ConnectionException(format!
                "%s answered HTTP %s with a body that is not a Frostlake response: %s"(
                endpoint, answer.status, snippet(answer.content)), endpoint, answer.status);
    }

    /**
     * Selects the database, schema, role and warehouse the DSN names.
     *
     * The constructor calls this, so it is only worth calling again after the
     * session has been moved somewhere else deliberately.
     */
    void applyScope() @safe
    {
        enter();
        scope (exit) leave();
        if (sessionDefaults.length == 0) return;
        // Re-queue the whole scope: the constructor drained the queue already,
        // so without this a second call would send nothing and report success.
        pendingUse = sessionDefaults.dup;
        sessionTouched = false;
        drainPendingUse();
    }

    // ------------------------------------------------------------- internals

    /// Claims the connection for one caller.
    private void enter() @safe
    {
        if (closed_)
            throw new UsageException("the connection is closed");
        if (busy)
            throw new UsageException(
                "this connection is already running a statement; a connection " ~
                "carries one session and cannot interleave two");
        busy = true;
    }

    private void leave() @safe nothrow
    {
        busy = false;
    }

    /**
     * The pending `USE` statements and the statement itself reach the session as
     * one unit: no other caller may slip a query in between them.
     */
    private Result[] run(string sql, string rendered) @safe
    {
        enter();
        scope (exit) leave();
        restoreSessionDefaults();
        drainPendingUse();
        auto answer = roundTrip(rendered);
        if (changesScope(sql)) sessionTouched = true;
        return shape(answer);
    }

    /**
     * Each `USE` leaves the queue only once it has succeeded. A DSN naming a
     * database that does not exist has to keep failing; the alternative is
     * later statements quietly running in the default scope.
     */
    private void drainPendingUse() @safe
    {
        while (pendingUse.length)
        {
            roundTrip(pendingUse[0]);
            pendingUse = pendingUse[1 .. $];
        }
    }

    /**
     * The engine reclaims a session once it has been idle long enough, then
     * quietly builds a fresh one for the id we keep sending — losing the scope
     * we selected. Nothing in the reply gives it away: the id we sent is echoed
     * back either way. So past the limit the only safe reading is that the
     * session is new, and the DSN's defaults go back on.
     *
     * Not once the caller has selected a scope themselves: putting our defaults
     * over their choice is its own surprise.
     */
    private void restoreSessionDefaults() @safe
    {
        if (sessionDefaults.length == 0 || sessionTouched) return;
        if (config_.idleLimit == Duration.zero || !everUsed) return;
        if (MonoTime.currTime - lastUsed < config_.idleLimit) return;
        pendingUse = sessionDefaults.dup;
    }

    private JsonValue roundTrip(string sql) @safe
    {
        const endpoint = baseUrl ~ "/api/execute";

        auto payload = appender!string();
        payload.put(`{"sql":`);
        payload.put(encodeJsonString(sql));
        if (sessionId_.length)
        {
            payload.put(`,"sessionId":`);
            payload.put(encodeJsonString(sessionId_));
        }
        payload.put(`,"autoCommit":`);
        payload.put(autoCommit_ ? "true" : "false");
        payload.put('}');

        auto answer = send("POST", "/api/execute", payload.data);
        auto decoded = decode(endpoint, answer);

        // On a failure the engine answers with `sessionId: null`, so the id is
        // taken only when it is really there — otherwise one bad statement
        // would drop the session and silently start a new one.
        auto session = decoded.at("sessionId");
        if (session.isText && session.text.length)
            sessionId_ = session.text;

        auto success = decoded.at("success");
        if (!(success.isBoolean && success.boolean))
            throw new QueryException(failureMessage(decoded, answer), sql, answer.status);

        lastUsed = MonoTime.currTime;
        everUsed = true;
        return decoded;
    }

    /**
     * Sends one request, opening the socket if there is none and replacing it
     * if the server closed the one there was.
     */
    private HttpResponse send(string method, string path, string payload) @safe
    {
        if (closed_)
            throw new UsageException("the connection is closed");
        if (client.isStale)
            client.connect();
        // A transport failure leaves the statement's fate unknown — it may have
        // run before the connection broke — so the socket goes (HttpClient drops
        // it), but nothing is ever re-sent.
        return client.exchange(method, path, payload);
    }

    /**
     * Reads a response body as the JSON object a Frostlake answer is.
     *
     * The status is not consulted: a refused statement comes back as HTTP 500
     * carrying the ordinary envelope with `success: false`, so treating a
     * non-200 as a transport failure would turn every rejected statement into a
     * connection error.
     *
     * A proxy error page, the wrong port, a crashed server: report what came
     * back rather than where the JSON parser gave up, which is the difference
     * between "malformed JSON at offset 0" and a message naming the address
     * that answered.
     */
    private JsonValue decode(string endpoint, HttpResponse answer) @safe
    {
        try
        {
            auto decoded = parseJson(answer.content);
            if (decoded.isObject) return decoded;
        }
        catch (UsageException) { }
        throw new ConnectionException(format!
            "%s answered HTTP %s with a body that is not a Frostlake response: %s"(
            endpoint, answer.status, snippet(answer.content)), endpoint, answer.status);
    }

    /**
     * Never answers the empty string: a response can report failure carrying no
     * message at all, and an error that prints as nothing tells the caller less
     * than the status code would.
     */
    private string failureMessage(JsonValue decoded, HttpResponse answer) @safe
    {
        foreach (key; ["errorMessage", "error"])
        {
            auto field = decoded.at(key);
            if (field.isText && field.text.length) return field.text;
        }
        return format!"the statement failed with HTTP %s and no error message: %s"(
            answer.status, snippet(answer.content));
    }

    // --------------------------------------------------------- result shape

    private Result[] shape(JsonValue decoded) @safe
    {
        auto results = appender!(Result[]);
        auto sets = decoded.at("resultSets");
        if (sets.isArray)
            foreach (entry; sets.items)
            {
                auto mutable = entry;
                if (mutable.isObject) results.put(shapeOne(mutable));
            }
        // A statement that returned no grid at all — DDL, a bare USE — still
        // answers with one result, so `execute` always has one to hand back.
        if (results.data.length == 0) return [Result.make(null, null)];
        return results.data;
    }

    private Result shapeOne(JsonValue entry) @safe
    {
        auto columns = appender!(Column[]);
        auto rawColumns = entry.at("columns");
        if (rawColumns.isArray)
            foreach (raw; rawColumns.items)
            {
                auto column = raw;
                if (!column.isObject) continue;
                Column c;
                c.name = column.at("name").isText ? column.at("name").text : "";
                c.dataType = column.at("dataType").isText ? column.at("dataType").text : "";
                auto nullable = column.at("nullable");
                c.nullableKnown = nullable.isBoolean;
                c.nullable = nullable.boolean;
                c.precision = asCount(column.at("precision"));
                c.scale = asCount(column.at("scale"));
                columns.put(c);
            }

        auto rows = appender!(Value[][]);
        auto rawRows = entry.at("rows");
        if (rawRows.isArray)
            foreach (raw; rawRows.items)
            {
                auto row = raw;
                if (!row.isArray) continue;
                auto cells = appender!(Value[]);
                foreach (cell; row.items)
                    cells.put(toValue(cell));
                // A row the server sent short of the column count is padded, so
                // every row lines up with `columns` positionally.
                auto padded = cells.data;
                while (padded.length < columns.data.length) padded ~= Value.ofNull();
                rows.put(padded);
            }

        return withUpdateCount(columns.data, rows.data);
    }

    private static Value toValue(const JsonValue cell) @safe
    {
        import frostlake.json : JsonKind;
        final switch (cell.kind)
        {
            case JsonKind.null_:   return Value.ofNull();
            case JsonKind.boolean: return Value.ofBoolean(cell.boolean);
            case JsonKind.number:  return Value.ofNumber(cell.text);
            case JsonKind.text:    return Value.ofText(cell.text);
            // A cell is always a scalar on this protocol; a container would be
            // a protocol change, and its JSON text is the only honest reading.
            case JsonKind.array:
            case JsonKind.object:  return Value.ofText("");
        }
    }

    /**
     * Recognises a DML answer by its shape and derives the affected-row count.
     *
     * The protocol carries no statement type, so a DML answer is recognised by
     * its grid: a single row whose every column is a `number of ...` counter.
     * INSERT and DELETE report one, UPDATE adds "number of multi-joined rows
     * updated", and MERGE reports an inserted and an updated count.
     *
     * The counters named `number of rows ...` are summed, so a MERGE reports
     * everything it touched. "number of multi-joined rows updated" is a
     * diagnostic sub-count of rows already counted as updated, and is left out.
     *
     * The grid itself is kept rather than folded away: a statement whose answer
     * merely $(I looks) like a status grid is indistinguishable from one that
     * is, and hiding its rows would lose the only copy of them.
     */
    private static Result withUpdateCount(Column[] columns, Value[][] rows) @safe
    {
        if (rows.length != 1 || columns.length == 0)
            return Result.make(columns, rows);

        foreach (column; columns)
            if (!column.name.toLower().startsWith("number of "))
                return Result.make(columns, rows);

        long[string] counters;
        long affected;
        foreach (i, column; columns)
        {
            if (i >= rows[0].length) continue;
            const text = rows[0][i].text;
            long count;
            try
                count = text.to!long;
            catch (Exception)
                continue;
            counters[column.name] = count;
            if (column.name.toLower().startsWith("number of rows "))
                affected += count;
        }
        return Result.make(columns, rows, affected, counters);
    }

    private static long asCount(const JsonValue field) @safe
    {
        if (!field.isNumber) return 0;
        try
            return field.text.to!long;
        catch (Exception)
            return 0;
    }
}

/**
 * Opens a connection to a Frostlake HTTP server.
 *
 * ---
 * auto conn = connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC");
 * scope (exit) conn.close();
 * ---
 */
Connection connect(string dsn, ConnectOptions options = ConnectOptions.init) @safe
{
    return new Connection(dsn, options);
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    import std.exception : assertThrown;
    // A malformed DSN is refused before anything is opened.
    assertThrown!UsageException(new Connection("not-a-dsn"));
    assertThrown!UsageException(new Connection("frostlake://h?bogus=1"));
}

@safe unittest
{
    import core.time : msecs;
    import std.exception : assertThrown;
    // An unreachable server fails at construction, not at the first query.
    ConnectOptions options;
    options.connectTimeout = msecs(400);
    options.timeout = msecs(400);
    assertThrown!ConnectionException(
        new Connection("frostlake://127.0.0.1:1/DB", options));
}
