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

import core.time : Duration, MonoTime, seconds;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.string : toLower;
import std.traits : isAssociativeArray;
import std.typecons : Nullable, nullable;
import std.uri : encodeComponent;

import frostlake.bind : bindNamed, bindNames, bindPositional;
import frostlake.dsn : DsnConfig, parseDsn;
import frostlake.errors;
import frostlake.http : HttpClient, HttpResponse, snippet;
import frostlake.json : encodeJsonString, JsonValue, parseJson;
import frostlake.result : Column, Result, Value;
import frostlake.sql : splitStatements, touchesSession, transactionEffect, TransactionEffect;
import frostlake.value : Param, toParam;

/**
 * What the engine is known to do with the session id a request names.
 *
 * An engine that answers `newSession` also honours `requireSession` and
 * `DELETE /api/sessions/{id}`; one that predates the field knows neither, and
 * its parser may refuse a field it does not know. Nothing is known until the
 * first answer that names a session.
 */
private enum SessionSupport
{
    unknown,
    /// The engine answers `newSession`.
    tracked,
    /// The engine predates `newSession`.
    untracked,
}

/// What one request to `/api/execute` came back with.
private enum Outcome
{
    /// An answer, in the session the request named or a new one it started.
    answered,
    /// An answer, from a fresh session the engine started in place of the one
    /// the request named: whatever that one held is gone.
    replaced,
    /// A refusal: the engine no longer holds the session the request named,
    /// and nothing ran.
    sessionGone,
}

/**
 * What may be set on one request, over and above its SQL.
 *
 * A field left unset is a field the request never carries, so a call that
 * passes these untouched sends exactly what it sent before they existed:
 *
 * ---
 * ExecuteOptions options;
 * options.multiStatementCount = 2;
 * conn.executeAll("CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1)", options);
 * ---
 */
struct ExecuteOptions
{
    /**
     * How many statements the request carries.
     *
     * A session runs one statement per request until its
     * `MULTI_STATEMENT_COUNT` says otherwise, and refuses a request that
     * carries more. This says it for one request instead: it outranks the
     * session's setting for that request and leaves the session itself alone,
     * so there is nothing to put back afterwards and two connections cannot
     * disturb each other. `0` accepts any number; left unset, the request
     * carries no such field and the session's value decides.
     */
    Nullable!int multiStatementCount;
}

/**
 * What may be set at connect time, over and above what the DSN says.
 *
 * Every field here can also be given in the DSN query string; an option set
 * here outranks it. A duration left unset keeps the DSN's value, and one set to
 * $(D Duration.zero) removes the bound:
 *
 * ---
 * ConnectOptions options;
 * options.connectTimeout = seconds(2);
 * options.timeout = Duration.zero;      // no deadline, whatever the DSN says
 * ---
 */
struct ConnectOptions
{
    Nullable!Duration timeout;
    Nullable!Duration connectTimeout;
    Nullable!Duration idleLimit;
    string database;
    string schema;
    string role;
    string warehouse;
}

/**
 * An open connection.
 *
 * A connection belongs to one thread. It carries one session, and two
 * statements half-interleaved on one session would corrupt exactly the state a
 * session exists to keep — so a second statement started while the first is in
 * flight is refused rather than half-done.
 *
 * The engine keeps the session until the connection closes, or until it has
 * idled past the engine's expiry, been released, or the server restarted. A
 * statement that finds it gone did not run: it is sent once more in a fresh
 * session on the DSN's scope when the old session held nothing a fresh one
 * lacks, and refused with a $(D SessionLostException) when it held an open
 * transaction or context set up on it.
 */
final class Connection
{
    /// How long closing may spend releasing the session.
    private enum Duration closeBudget = seconds(5);

    private DsnConfig config_;
    private HttpClient client;
    private string sessionId_;
    private bool autoCommit_ = true;
    private bool closed_;
    private bool busy;

    /// Whether the engine keeps sessions to their id; see $(D SessionSupport).
    private SessionSupport sessions = SessionSupport.unknown;
    /// A transaction opened by a `BEGIN` sent as a statement, until its
    /// `COMMIT` or `ROLLBACK`.
    private bool transactionOpen_;

    /// `USE` statements still owed to the session, in dependency order.
    private string[] pendingUse;
    /// The scope the DSN named, kept so a lapsed session can be put back on it.
    private string[] sessionDefaults;
    /// Whether a statement has left state behind that a fresh session would
    /// not have — a scope the caller selected themselves, a variable, a
    /// setting, a temporary object. Once it has, the DSN's defaults are no
    /// longer the whole truth about this session.
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

        if (!options.timeout.isNull) config_.timeout = options.timeout.get;
        if (!options.connectTimeout.isNull) config_.connectTimeout = options.connectTimeout.get;
        if (!options.idleLimit.isNull) config_.idleLimit = options.idleLimit.get;
        if (options.database.length) config_.database = options.database;
        if (options.schema.length) config_.schema = options.schema;
        if (options.role.length) config_.role = options.role;
        if (options.warehouse.length) config_.warehouse = options.warehouse;

        client = new HttpClient(config_);
        sessionDefaults = config_.useStatements();
        pendingUse = sessionDefaults.dup;

        try
        {
            // Part of connecting, so the connect timeout bounds it, not a
            // statement's.
            probe(config_.connectTimeout);
            applyScope();
        }
        catch (Exception e)
        {
            // A scope the engine refused still started a session; it goes
            // back rather than waiting out the engine's idle expiry.
            close();
            throw e;
        }
    }

    /**
     * Closes the connection, and gives the engine its session back. Safe to
     * call more than once; only the first call sends anything.
     *
     * The session is released with `DELETE /api/sessions/{id}`, which also
     * rolls back a transaction left open on it, so it does not linger until
     * the engine's idle expiry. That is a courtesy, not a requirement: it is
     * bounded by the shorter of five seconds and the DSN's `timeout`, and
     * whatever goes wrong with it is swallowed, because closing never fails.
     * An engine that predates the endpoint (it answers no `newSession`) is
     * sent nothing, and its session lingers as it always did.
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
        if (closed_) return;
        releaseSession();
        release();
    }

    private void release() @safe nothrow
    {
        closed_ = true;
        if (client !is null) client.disconnect();
    }

    /**
     * `DELETE /api/sessions/{id}`, best effort: nothing it meets is raised,
     * and it spends at most the shorter of $(D closeBudget) and the DSN's
     * `timeout`, a socket it has to open again included.
     */
    private void releaseSession() @safe nothrow
    {
        const id = sessionId_;
        sessionId_ = null;
        if (id.length == 0 || sessions != SessionSupport.tracked || client is null) return;
        try
        {
            const budget = shorter(closeBudget, config_.timeout);
            const started = MonoTime.currTime;
            if (client.isStale)
                client.connect(shorter(budget, config_.connectTimeout));
            const left = budget - (MonoTime.currTime - started);
            if (left > Duration.zero)
                client.exchange("DELETE", "/api/sessions/" ~ encodeComponent(id), "", left);
        }
        catch (Exception) { }
    }

    /// The shorter of two bounds, where `Duration.zero` is no bound at all.
    private static Duration shorter(Duration a, Duration b) @safe pure nothrow @nogc
    {
        if (a == Duration.zero) return b;
        if (b == Duration.zero) return a;
        return a < b ? a : b;
    }

    // ------------------------------------------------------------ reporting

    /// The engine's id for this connection's session, once it has one, and
    /// until the connection closes.
    @property string sessionId() const @safe pure nothrow @nogc { return sessionId_; }

    /// Whether a transaction is open — `begin` without a matching `commit` or
    /// `rollback`, or a `BEGIN` run as a statement until its `COMMIT` or
    /// `ROLLBACK`.
    @property bool inTransaction() const @safe pure nothrow @nogc
    {
        return !autoCommit_ || transactionOpen_;
    }

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
     * Runs a statement string with the options that apply to that one
     * request, and returns its first result set.
     *
     * ---
     * ExecuteOptions options;
     * options.multiStatementCount = 2;
     * conn.execute("CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1)", options);
     * ---
     */
    Result execute(string sql, ExecuteOptions options) @safe
    {
        return executeAll(sql, options)[0];
    }

    /**
     * Runs a statement string and returns every result set it produced, in
     * order. A single statement gives a one-element array.
     */
    Result[] executeAll(Args...)(string sql, Args args) @safe
    {
        return run(sql, render(sql, args), ExecuteOptions.init);
    }

    /// ditto, with the options that apply to that one request.
    Result[] executeAll(string sql, ExecuteOptions options) @safe
    {
        return run(sql, render(sql), options);
    }

    /// Runs one statement with parameters built at runtime.
    Result executePositional(string sql, const(Param)[] params,
                             ExecuteOptions options = ExecuteOptions.init) @safe
    {
        return run(sql, bindPositional(sql, params), options)[0];
    }

    /// ditto
    Result executeNamed(string sql, const(Param[string]) params,
                        ExecuteOptions options = ExecuteOptions.init) @safe
    {
        return run(sql, bindNamed(sql, params), options)[0];
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
        // The BEGIN itself already carries autocommit off. Autocommit is
        // switched off only once it has run, so a session lost under it is not
        // mistaken for one that took an open transaction with it.
        roundTrip("BEGIN", ExecuteOptions.init, false);
        autoCommit_ = false;
    }

    /// Commits the open transaction and restores autocommit.
    void commit() @safe
    {
        enter();
        scope (exit) { autoCommit_ = true; transactionOpen_ = false; leave(); }
        roundTrip("COMMIT");
    }

    /// Rolls the open transaction back and restores autocommit.
    void rollback() @safe
    {
        enter();
        scope (exit) { autoCommit_ = true; transactionOpen_ = false; leave(); }
        roundTrip("ROLLBACK");
    }

    /**
     * Runs `work` between `BEGIN` and `COMMIT`, rolling back if it throws —
     * anything at all, an $(D Error) included — and re-raising what it threw.
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
        runInTransaction(work);
    }

    /// ditto — the overload `work` that calls `@system` code resolves to.
    void transaction(scope void delegate() @system work) @system
    {
        runInTransaction(work);
    }

    private void runInTransaction(Work)(scope Work work)
    {
        begin();
        {
            // An open transaction must not outlive the work that failed in it,
            // whatever that work threw.
            scope (failure) rollbackQuietly();
            work();
        }
        commit();
    }

    /// A failed rollback must not replace the error that caused it, and a
    /// transaction already gone — with a lost session, say — needs none.
    private void rollbackQuietly() @safe nothrow
    {
        if (!inTransaction) return;
        try rollback();
        catch (Exception) { }
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
        probe(config_.timeout);
    }

    /**
     * `ping` bounded by `limit`: a call to `ping` runs under the statement
     * `timeout`, the check made while connecting under `connectTimeout`.
     */
    private void probe(Duration limit) @safe
    {
        enter();
        scope (exit) leave();
        const endpoint = baseUrl ~ "/api/health";
        auto answer = send("GET", "/api/health", "", limit);
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
    private Result[] run(string sql, string rendered, ExecuteOptions options) @safe
    {
        enter();
        scope (exit) leave();
        restoreSessionDefaults();
        drainPendingUse();
        auto answer = roundTrip(rendered, options);
        track(sql);
        return shape(answer);
    }

    /**
     * What a statement that ran left on the session: context a fresh session
     * would not have, and whether a transaction is open. Every statement of a
     * request counts, so a `USE` riding behind a `SELECT` is seen too.
     */
    private void track(const(char)[] sql) @safe
    {
        foreach (statement; splitStatements(sql))
        {
            if (touchesSession(statement)) sessionTouched = true;
            final switch (transactionEffect(statement))
            {
                case TransactionEffect.begins: transactionOpen_ = true; break;
                case TransactionEffect.ends: transactionOpen_ = false; break;
                case TransactionEffect.none: break;
            }
        }
    }

    /**
     * Each `USE` leaves the queue only once it has succeeded. A DSN naming a
     * database that does not exist has to keep failing; the alternative is
     * later statements quietly running in the default scope.
     *
     * A session lost part way through the scope takes the `USE` statements
     * already run with it, so the whole scope starts over in a fresh session —
     * once. With the whole scope on, the session holds nothing the caller put
     * there.
     */
    private void drainPendingUse() @safe
    {
        if (pendingUse.length == 0) return;
        bool restarted;
        while (pendingUse.length)
        {
            const statement = pendingUse[0];
            JsonValue decoded;
            HttpResponse answer;
            final switch (post(statement, ExecuteOptions.init, autoCommit_, decoded, answer))
            {
                case Outcome.answered:
                    checked(statement, decoded, answer);
                    pendingUse = pendingUse[1 .. $];
                    break;
                case Outcome.replaced:
                    if (restarted)
                    {
                        checked(statement, decoded, answer);
                        pendingUse = pendingUse[1 .. $];
                        break;
                    }
                    // The engine ran this `USE` in a fresh session in place of
                    // ours, so what the ones before it selected is gone.
                    restarted = true;
                    forgetSession();
                    checked(statement, decoded, answer);
                    break;
                case Outcome.sessionGone:
                    if (restarted) throw lostAgain(statement);
                    restarted = true;
                    loseSession(statement);
                    break;
            }
        }
        sessionTouched = false;
    }

    /**
     * The engine reclaims a session once it has been idle long enough. An
     * engine that answers `newSession` then refuses the id, and the refusal is
     * recovered from where it lands. One that predates the field quietly
     * builds a fresh session for the id we keep sending — losing the scope we
     * selected — and nothing in the reply gives it away: the id we sent is
     * echoed back either way. So against such an engine, past the limit the
     * only safe reading is that the session is new, and the DSN's defaults go
     * back on.
     *
     * Not once the caller has selected a scope themselves, nor inside a
     * transaction: putting our defaults over their choice is its own surprise.
     */
    private void restoreSessionDefaults() @safe
    {
        if (sessions != SessionSupport.untracked) return;
        if (sessionDefaults.length == 0 || sessionTouched || inTransaction) return;
        if (config_.idleLimit == Duration.zero || !everUsed) return;
        if (MonoTime.currTime - lastUsed < config_.idleLimit) return;
        pendingUse = sessionDefaults.dup;
    }

    /// One statement, under the connection's autocommit.
    private JsonValue roundTrip(string sql, ExecuteOptions options = ExecuteOptions.init) @safe
    {
        return roundTrip(sql, options, autoCommit_);
    }

    /**
     * One statement, checked.
     *
     * A statement that finds the session gone did not run. When the session
     * held nothing a fresh one lacks, the DSN's scope goes onto a fresh session
     * and the statement is sent once more; when it held a transaction or
     * context, $(D loseSession) refuses instead.
     */
    private JsonValue roundTrip(string sql, ExecuteOptions options, bool autoCommit) @safe
    {
        foreach (attempt; 0 .. 2)
        {
            JsonValue decoded;
            HttpResponse answer;
            final switch (post(sql, options, autoCommit, decoded, answer))
            {
                case Outcome.answered:
                    return checked(sql, decoded, answer);
                case Outcome.replaced:
                    // It ran, but in a fresh session: the scope goes back on
                    // before the next statement.
                    forgetSession();
                    return checked(sql, decoded, answer);
                case Outcome.sessionGone:
                    if (attempt > 0) throw lostAgain(sql);
                    loseSession(sql);
                    drainPendingUse();
                    break;
            }
        }
        assert(0, "a statement is sent at most twice");
    }

    /**
     * One `POST /api/execute`, without any recovery: the answer is read into
     * `decoded` and `answer`, and the outcome says what became of the session.
     */
    private Outcome post(string sql, ExecuteOptions options, bool autoCommit,
                         out JsonValue decoded, out HttpResponse answer) @safe
    {
        const endpoint = baseUrl ~ "/api/execute";
        const namedSession = sessionId_.length > 0;
        // Resume the session or refuse: without this, an engine that no longer
        // holds it starts a fresh one under the same id and the statement runs
        // in the wrong context. Sent only once the engine is known to honour it:
        // an older one's parser may refuse a field it does not know.
        const requireSession = namedSession && sessions == SessionSupport.tracked;

        auto payload = appender!string();
        payload.put(`{"sql":`);
        payload.put(encodeJsonString(sql));
        if (namedSession)
        {
            payload.put(`,"sessionId":`);
            payload.put(encodeJsonString(sessionId_));
        }
        if (requireSession)
            payload.put(`,"requireSession":true`);
        payload.put(`,"autoCommit":`);
        payload.put(autoCommit ? "true" : "false");
        if (!options.multiStatementCount.isNull)
        {
            payload.put(`,"multiStatementCount":`);
            payload.put(options.multiStatementCount.get.to!string);
        }
        payload.put('}');

        answer = send("POST", "/api/execute", payload.data);
        decoded = decode(endpoint, answer);

        auto session = decoded.at("sessionId");
        const named = session.isText && session.text.length > 0;
        auto success = decoded.at("success");
        const succeeded = success.isBoolean && success.boolean;
        if (requireSession && answer.status == 404 && !succeeded && !named)
            return Outcome.sessionGone;

        // On a failure the engine answers with `sessionId: null`, so the id is
        // taken only when it is really there — otherwise one bad statement
        // would drop the session and silently start a new one.
        if (!named) return Outcome.answered;
        sessionId_ = session.text;

        // The first answer that names a session says whether the engine keeps
        // sessions to their id: one that does answers `newSession`.
        auto started = decoded.at("newSession");
        if (started.isBoolean)
        {
            sessions = SessionSupport.tracked;
            if (started.boolean && namedSession) return Outcome.replaced;
        }
        else if (sessions == SessionSupport.unknown)
            sessions = SessionSupport.untracked;
        return Outcome.answered;
    }

    /// Raises the engine's refusal, or takes note that the connection was used.
    private JsonValue checked(string sql, JsonValue decoded, HttpResponse answer) @safe
    {
        auto success = decoded.at("success");
        if (!(success.isBoolean && success.boolean))
            throw new QueryException(failureMessage(decoded, answer), sql, answer.status);

        lastUsed = MonoTime.currTime;
        everUsed = true;
        return decoded;
    }

    /**
     * The engine no longer holds this connection's session — it expired, was
     * released, or the server restarted — and nothing ran. The id is dropped
     * and the DSN's scope queued for a fresh session.
     *
     * When the lost session held an open transaction, or context set up on it,
     * re-running the statement would put it somewhere its author did not
     * intend, so that is refused instead. Either way the connection stays
     * usable, and its next statement starts on the DSN's scope.
     */
    private void loseSession(string sql) @safe
    {
        const hadTransaction = inTransaction;
        const hadContext = sessionTouched;
        sessionId_ = null;
        forgetSession();
        if (hadTransaction)
            throw new SessionLostException(
                "the engine no longer holds this connection's session (it expired, was " ~
                "released, or the server restarted), so its open transaction is gone; " ~
                "the statement did not run", sql);
        if (hadContext)
            throw new SessionLostException(
                "the engine no longer holds this connection's session (it expired, was " ~
                "released, or the server restarted), and the context set up on it (USE, " ~
                "SET, ALTER SESSION or a temporary object) went with it, so the statement " ~
                "was not re-run; the next statement starts a fresh session on the " ~
                "connection's scope", sql);
    }

    /**
     * Nothing is left of what the session held — it was lost, or the engine
     * ran a request in a fresh session in place of it — so the DSN's scope
     * goes back on before the next statement.
     */
    private void forgetSession() @safe nothrow
    {
        autoCommit_ = true;
        transactionOpen_ = false;
        sessionTouched = false;
        pendingUse = sessionDefaults.dup;
    }

    /// A session the engine started for this connection was refused at once.
    /// It is dropped as well, so the next statement starts over.
    private SessionLostException lostAgain(string sql) @safe nothrow
    {
        sessionId_ = null;
        forgetSession();
        return new SessionLostException(
            "the engine refused a session it had just started for this connection; " ~
            "the statement did not run", sql);
    }

    /**
     * Sends one request, opening the socket if there is none and replacing it
     * if the server closed the one there was.
     */
    private HttpResponse send(string method, string path, string payload) @safe
    {
        return send(method, path, payload, config_.timeout);
    }

    /// As `send` above, bounded by `limit` rather than the statement `timeout`.
    private HttpResponse send(string method, string path, string payload, Duration limit) @safe
    {
        if (closed_)
            throw new UsageException("the connection is closed");
        if (client.isStale)
            client.connect();
        // A transport failure leaves the statement's fate unknown — it may have
        // run before the connection broke — so the socket goes (HttpClient drops
        // it), but nothing is ever re-sent.
        return client.exchange(method, path, payload, limit);
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
                c.length = asLength(column.at("length"));
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
        import frostlake.json : encodeJson, JsonKind;
        final switch (cell.kind)
        {
            case JsonKind.null_:   return Value.ofNull();
            case JsonKind.boolean: return Value.ofBoolean(cell.boolean);
            case JsonKind.number:  return Value.ofNumber(cell.text);
            case JsonKind.text:    return Value.ofText(cell.text);
            // A container cell is handed back as its JSON text — the reading a
            // VARIANT gets when the engine sends it as a string.
            case JsonKind.array:
            case JsonKind.object:  return Value.ofText(encodeJson(cell));
        }
    }

    /// The counters the engine answers DML with, by the names it gives them.
    private static immutable string[] dmlCounters = [
        "number of rows inserted",
        "number of rows updated",
        "number of rows deleted",
        "number of multi-joined rows updated",
    ];

    /**
     * Recognises a DML answer by its shape and derives the affected-row count.
     *
     * The protocol carries no statement type, so a DML answer is recognised by
     * its grid: a single row whose every column is one of the counters the
     * engine answers DML with. INSERT and DELETE report one, UPDATE adds
     * "number of multi-joined rows updated", and MERGE reports one per action.
     * A column that merely starts `number of` is data, not a counter.
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
        {
            bool counter;
            foreach (name; dmlCounters)
                counter = counter || column.name.toLower() == name;
            if (!counter)
                return Result.make(columns, rows);
        }

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
            if (column.name.toLower() != "number of multi-joined rows updated")
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

    /// The declared width a text or binary column carries. A field the answer
    /// left out stays empty rather than becoming a width of zero: only those
    /// two families carry one, and an engine that predates it carries none.
    private static Nullable!long asLength(const JsonValue field) @safe
    {
        if (!field.isNumber) return Nullable!long.init;
        try
            return nullable(field.text.to!long);
        catch (Exception)
            return Nullable!long.init;
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

@safe unittest
{
    // Only the engine's own counters make a DML answer.
    auto touched = Connection.withUpdateCount(
        [Column("number of rows inserted", "NUMBER"), Column("number of rows deleted", "NUMBER")],
        [[Value.ofNumber("2"), Value.ofNumber("1")]]);
    assert(touched.isUpdate && touched.updateCount == 3);

    // The multi-joined count is reported but not added in.
    auto updated = Connection.withUpdateCount(
        [Column("number of rows updated", "NUMBER"),
         Column("number of multi-joined rows updated", "NUMBER")],
        [[Value.ofNumber("4"), Value.ofNumber("0")]]);
    assert(updated.updateCount == 4 && updated.counters.length == 2);

    // A column that merely starts "number of" is data, alone or beside a counter.
    auto apples = Connection.withUpdateCount([Column("number of apples", "NUMBER")],
                                             [[Value.ofNumber("5")]]);
    assert(!apples.isUpdate && apples.value.asLong == 5);
    auto mixed = Connection.withUpdateCount(
        [Column("number of rows inserted", "NUMBER"), Column("number of apples", "NUMBER")],
        [[Value.ofNumber("1"), Value.ofNumber("5")]]);
    assert(!mixed.isUpdate && mixed.rowCount == 1);
}

@safe unittest
{
    import frostlake.json : parseJson;
    // A text or binary column carries its declared width; every other type
    // carries none, and none is not a width of zero.
    auto columns = parseJson(`[{"length":9},{"length":16777216},{"precision":10},` ~
                             `{"length":"9"}]`);
    assert(Connection.asLength(columns.at(0).at("length")).get == 9);
    assert(Connection.asLength(columns.at(1).at("length")).get == 16_777_216);
    assert(Connection.asLength(columns.at(2).at("length")).isNull);
    // Only a JSON number is a width.
    assert(Connection.asLength(columns.at(3).at("length")).isNull);
}

@safe unittest
{
    import frostlake.json : parseJson;
    import frostlake.result : ValueKind;
    // A container cell reads as its JSON text rather than as nothing.
    auto cells = parseJson(`[[1,{"k":"v"}],{"a":[]},"text"]`);
    assert(Connection.toValue(cells.at(0)).text == `[1,{"k":"v"}]`);
    assert(Connection.toValue(cells.at(0)).kind == ValueKind.text);
    assert(Connection.toValue(cells.at(1)).text == `{"a":[]}`);
    assert(Connection.toValue(cells.at(2)).text == "text");
}
