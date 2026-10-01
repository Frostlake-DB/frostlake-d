/**
 * Transport tests against a scripted server, with no engine involved.
 *
 * A real engine answers correctly, which is exactly why it cannot test what
 * happens when the answer is wrong. These cases — a chunked body, a header
 * spelled in the wrong case, a proxy's HTML error page, a `Connection: close`,
 * a server that hangs up mid-response — are the ones a driver gets wrong in
 * production and never in development, so they are scripted here.
 *
 * The server is a thread that hands out canned responses in order, one per
 * request. It reads each request properly (headers, then the body by its
 * `Content-Length`) so that keep-alive really is being exercised.
 */
module tests.transport;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, minutes, MonoTime, msecs, seconds;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.exception : assertThrown, collectException, collectExceptionMsg;
import std.format : format;
import std.socket : AddressFamily, Internet6Address, InternetAddress, Socket, SocketSet,
                    SocketShutdown, TcpSocket;
import std.stdio : writefln;
import std.string : indexOf, toLower;

import frostlake;
import frostlake.dsn : parseDsn;
import frostlake.http : HttpClient;
import frostlake.json : parseJson;

/// A canned response, plus what the server should do after sending it.
struct Canned
{
    string raw;
    /// Hang up after writing this one.
    bool thenClose;
    /// Write only the first `truncateTo` bytes, then hang up.
    size_t truncateTo = size_t.max;
    /// Say nothing at all, and hold the socket until the server stops.
    bool thenHang;
}

/// The health answer a connection's constructor expects.
enum healthOk = "HTTP/1.1 200 OK\r\nContent-type: application/json\r\n" ~
                "Content-length: 39\r\n\r\n{\"status\":\"healthy\",\"activeSessions\":0}";

/// Wraps a Frostlake envelope in a normal 200.
string ok(string body_)
{
    return format!"HTTP/1.1 200 OK\r\nContent-type: application/json\r\nContent-length: %s\r\n\r\n%s"(
        body_.length, body_);
}

/// A successful single-value answer.
string successEnvelope(string cell = `1`)
{
    return `{"errorMessage":null,"executionTimeMs":1,"resultSets":[{"columns":` ~
           `[{"dataType":"NUMBER","name":"A","nullable":false,"precision":1,"scale":0}],` ~
           `"rowCount":1,"rows":[[` ~ cell ~ `]]}],"sessionId":"s1","success":true}`;
}

/**
 * A successful single-value answer from an engine that reports `newSession`
 * (0.1.0 and later); `started` says whether the session is a new one.
 */
string sessionEnvelope(string id, bool started, string cell = `1`)
{
    return `{"errorMessage":null,"executionTimeMs":1,"newSession":` ~ (started ? "true" : "false") ~
           `,"resultSets":[{"columns":[{"dataType":"NUMBER","name":"A","nullable":false,` ~
           `"precision":1,"scale":0}],"rowCount":1,"rows":[[` ~ cell ~ `]]}],"sessionId":"` ~ id ~
           `","success":true}`;
}

/// The 404 a request that requires its session gets once the engine no longer
/// holds it: nothing ran.
string sessionGone(string id)
{
    const body_ = `{"errorMessage":"Session '` ~ id ~ `' does not exist or has expired.",` ~
                  `"executionTimeMs":0,"newSession":false,"resultSets":[],"sessionId":null,` ~
                  `"success":false}`;
    return format!"HTTP/1.1 404 Not Found\r\nContent-type: application/json\r\nContent-length: %s\r\n\r\n%s"(
        body_.length, body_);
}

/// What `DELETE /api/sessions/{id}` answers for a session the engine held.
string released()
{
    return ok(`{"errorMessage":null,"executionTimeMs":0,"newSession":false,"resultSets":[],` ~
              `"sessionId":null,"success":true}`);
}

/// A scripted server on a port of its own.
final class FakeServer
{
    private TcpSocket listener;
    private Thread thread;
    private shared bool stopping;
    private Mutex lock;
    private string[] requests_;
    private bool ipv6;
    Canned[] script;
    ushort port;

    /// Listens on 127.0.0.1, or on the IPv6 loopback when `ipv6` is set.
    this(Canned[] script, bool ipv6 = false)
    {
        this.script = script;
        this.ipv6 = ipv6;
        lock = new Mutex();
        listener = new TcpSocket(ipv6 ? AddressFamily.INET6 : AddressFamily.INET);
        listener.setOption(std.socket.SocketOptionLevel.SOCKET,
                           std.socket.SocketOption.REUSEADDR, true);
        if (ipv6)
        {
            listener.bind(new Internet6Address("::1", 0));
            port = (cast(Internet6Address) listener.localAddress).port;
        }
        else
        {
            listener.bind(new InternetAddress("127.0.0.1", 0));
            port = (cast(InternetAddress) listener.localAddress).port;
        }
        listener.listen(8);
        thread = new Thread(&serve);
        thread.isDaemon = true;
        thread.start();
    }

    string dsn() const
    {
        return ipv6 ? format!"frostlake://[::1]:%s"(port) : format!"frostlake://127.0.0.1:%s"(port);
    }

    /// Every request received so far, headers and body, in arrival order.
    string[] requests()
    {
        lock.lock();
        scope (exit) lock.unlock();
        return requests_.dup;
    }

    void stop()
    {
        import core.atomic : atomicStore;
        atomicStore(stopping, true);
        try
        {
            listener.shutdown(SocketShutdown.BOTH);
            listener.close();
        }
        catch (Exception) { }
    }

    private void serve()
    {
        size_t next;
        while (true)
        {
            import core.atomic : atomicLoad;
            if (atomicLoad(stopping)) return;
            Socket client;
            try
                client = listener.accept();
            catch (Exception)
                return;

            // One connection may carry several requests — that is the point.
            while (next < script.length)
            {
                const request = readRequest(client);
                if (request is null) break;
                lock.lock();
                requests_ ~= request;
                lock.unlock();
                auto canned = script[next++];
                if (canned.thenHang)
                {
                    import core.atomic : atomicLoad;
                    while (!atomicLoad(stopping))
                        Thread.sleep(msecs(5));
                    break;
                }
                auto bytes = canned.raw;
                if (canned.truncateTo < bytes.length)
                    bytes = bytes[0 .. canned.truncateTo];
                try
                    client.send(cast(const(void)[]) bytes);
                catch (Exception)
                    break;
                if (canned.thenClose || canned.truncateTo < canned.raw.length)
                    break;
            }
            try
            {
                client.shutdown(SocketShutdown.BOTH);
                client.close();
            }
            catch (Exception) { }
            if (next >= script.length) return;
        }
    }

    /// Reads one whole request, so the next response lands on a clean stream,
    /// and answers it — headers and body — or null when the client hung up.
    private static string readRequest(Socket client)
    {
        auto buffer = appender!(char[]);
        ubyte[4096] scratch;
        ptrdiff_t headerEnd = -1;
        while (headerEnd < 0)
        {
            const got = client.receive(scratch[]);
            if (got <= 0) return null;
            buffer.put(cast(char[]) scratch[0 .. got]);
            headerEnd = buffer.data.indexOf("\r\n\r\n");
        }
        const headers = buffer.data[0 .. headerEnd];
        size_t contentLength;
        const marker = headers.toLower().indexOf("content-length:");
        if (marker >= 0)
        {
            auto tail = headers[marker + 15 .. $];
            const lineEnd = tail.indexOf("\r\n");
            try
                contentLength = tail[0 .. lineEnd < 0 ? tail.length : lineEnd].to!string
                                    .strip_.to!size_t;
            catch (Exception)
                contentLength = 0;
        }
        size_t have = buffer.data.length - (headerEnd + 4);
        while (have < contentLength)
        {
            const got = client.receive(scratch[]);
            if (got <= 0) return null;
            buffer.put(cast(char[]) scratch[0 .. got]);
            have += got;
        }
        return buffer.data.idup;
    }
}

private string strip_(string s)
{
    import std.string : strip;
    return s.strip();
}

// ------------------------------------------------------------------- tests

private alias TransportTest = void function();

private immutable TransportTest[] tests = [
    &testChunkedBody,
    &testHeaderCaseFolding,
    &testNonJsonBody,
    &testConnectionCloseIsHonoured,
    &testErrorEnvelopeOn500,
    &testTruncatedResponse,
    &testKeepAliveReusesOneSocket,
    &testWireFailuresDropTheSocket,
    &testSystemWorkInATransaction,
    &testAnErrorInATransactionRollsItBack,
    &testLookalikeCountersAreData,
    &testAContainerCellIsItsJsonText,
    &testAnUnsetOptionKeepsTheDsnBound,
    &testAnIpv6HostIsBracketed,
    &testAStatementCountTravelsOnlyWhenAsked,
    &testTheSessionFlagWaitsForTheEngine,
    &testAnOlderEngineIsSentNoSessionFlag,
    &testALostSessionIsReplacedOnce,
    &testASecondLossRaises,
    &testALostTransactionIsReported,
    &testATransactionBegunAsAStatementIsTracked,
    &testALostContextIsReported,
    &testAReplacedSessionGetsItsScopeBack,
    &testIdleRescopeIsForOlderEnginesOnly,
    &testClosingReleasesTheSessionOnce,
    &testClosingNeverRaises,
    &testARefusedScopeReleasesItsSession,
];

private immutable string[] testNames = [
    "a chunked response body is reassembled",
    "header names are matched case-insensitively",
    "a body that is not a Frostlake answer names the endpoint",
    "Connection: close is honoured and the socket re-opened",
    "an error envelope on HTTP 500 is a query error, not a transport one",
    "a response cut off mid-body fails as a transport error",
    "many statements ride one keep-alive socket",
    "every broken answer drops the socket it arrived on",
    "a transaction's work may call @system code",
    "an Error thrown inside a transaction rolls it back",
    "a column that merely starts 'number of' is no update count",
    "a container cell reads as its JSON text",
    "an option left unset keeps the DSN's bound; zero removes it",
    "an IPv6 host is bracketed in the Host header and the URL",
    "a request declares a statement count only when one is asked for",
    "requireSession is sent once the engine says it keeps sessions",
    "an engine without newSession is sent no requireSession and no DELETE",
    "a lost session is replaced on the DSN's scope and the statement sent once more",
    "a session refused twice in a row raises, and the connection carries on",
    "a session lost with a transaction open raises and nothing is re-sent",
    "a BEGIN run as a statement opens a transaction the driver tracks",
    "a session lost after a USE, SET, ALTER SESSION or temporary table raises",
    "a session the engine replaced gets the DSN's scope back first",
    "only an engine without newSession gets its scope re-applied after idling",
    "closing sends one DELETE for the session, and a second close sends nothing",
    "closing never raises, whether the DELETE meets a 404, a 405, a hang-up or a hang",
    "a scope refused at connect releases the session it started",
];

/// The statements a scripted server was sent, in order.
private string[] statementsSent(FakeServer server)
{
    string[] result;
    foreach (request; server.requests)
    {
        const bodyStart = request.indexOf("\r\n\r\n");
        if (bodyStart < 0 || bodyStart + 4 >= request.length) continue;
        result ~= parseJson(request[bodyStart + 4 .. $]).at("sql").text;
    }
    return result;
}

/// One request a scripted server received, read back.
private struct Received
{
    string method;
    string path;
    /// What the body carried: empty, or false, when it carried no such field.
    string sql;
    string sessionId;
    bool carriesRequireSession;
    bool requireSession;
    bool autoCommit;
}

/// Every request a scripted server received, in order.
private Received[] received(FakeServer server)
{
    Received[] result;
    foreach (request; server.requests)
    {
        Received r;
        const lineEnd = request.indexOf("\r\n");
        const line = lineEnd < 0 ? request : request[0 .. lineEnd];
        const methodEnd = line.indexOf(' ');
        const pathEnd = line.indexOf(' ', methodEnd + 1);
        r.method = line[0 .. methodEnd];
        r.path = line[methodEnd + 1 .. pathEnd];
        const bodyStart = request.indexOf("\r\n\r\n");
        if (bodyStart >= 0 && bodyStart + 4 < request.length)
        {
            auto fields = parseJson(request[bodyStart + 4 .. $]);
            if (fields.at("sql").isText) r.sql = fields.at("sql").text;
            if (fields.at("sessionId").isText) r.sessionId = fields.at("sessionId").text;
            r.carriesRequireSession = fields.has("requireSession");
            r.requireSession = fields.at("requireSession").isBoolean
                && fields.at("requireSession").boolean;
            r.autoCommit = fields.at("autoCommit").isBoolean && fields.at("autoCommit").boolean;
        }
        result ~= r;
    }
    return result;
}

/// The request bodies a scripted server was sent, as they went over the wire.
private string[] bodiesSent(FakeServer server)
{
    string[] result;
    foreach (request; server.requests)
    {
        const bodyStart = request.indexOf("\r\n\r\n");
        if (bodyStart < 0 || bodyStart + 4 >= request.length) continue;
        result ~= request[bodyStart + 4 .. $].idup;
    }
    return result;
}

/// Runs them all, returning how many failed.
size_t runTransportTests()
{
    import std.stdio : writeln;
    writeln();
    writeln("transport tests (scripted server, no engine):");
    size_t failed;
    foreach (i, test; tests)
    {
        try
        {
            test();
            writefln("  ok    %s", testNames[i]);
        }
        catch (Throwable e)
        {
            failed++;
            writefln("  FAIL  %s\n          %s", testNames[i], e.msg);
        }
    }
    return failed;
}

private void testChunkedBody()
{
    // The same envelope, delivered in three chunks with an extension on one.
    const envelope = successEnvelope("42");
    const first = envelope[0 .. 20];
    const second = envelope[20 .. 45];
    const third = envelope[45 .. $];
    const chunked = "HTTP/1.1 200 OK\r\nContent-type: application/json\r\n" ~
        "Transfer-Encoding: chunked\r\n\r\n" ~
        format!"%x;note=first\r\n%s\r\n"(first.length, first) ~
        format!"%x\r\n%s\r\n"(second.length, second) ~
        format!"%x\r\n%s\r\n"(third.length, third) ~
        "0\r\n\r\n";

    auto server = new FakeServer([Canned(healthOk), Canned(chunked)]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();
    assert(conn.execute("SELECT 42").value.asLong == 42);
}

private void testHeaderCaseFolding()
{
    // The engine really does spell it `Content-length`; a driver matching
    // `Content-Length` exactly would read no body at all.
    const envelope = successEnvelope("7");
    const oddCase = format!("HTTP/1.1 200 OK\r\ncOnTeNt-TyPe: application/json\r\n" ~
                            "CONTENT-LENGTH: %s\r\n\r\n%s")(envelope.length, envelope);

    auto server = new FakeServer([Canned(healthOk), Canned(oddCase)]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();
    assert(conn.execute("SELECT 7").value.asLong == 7);
}

private void testNonJsonBody()
{
    // A proxy's error page, or the wrong port entirely.
    const page = "<html><body>502 Bad Gateway</body></html>";
    const response = format!"HTTP/1.1 502 Bad Gateway\r\nContent-type: text/html\r\nContent-length: %s\r\n\r\n%s"(
        page.length, page);

    auto server = new FakeServer([Canned(healthOk), Canned(response)]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    const message = collectExceptionMsg!ConnectionException(conn.execute("SELECT 1"));
    // The complaint names the address that answered and shows what it said,
    // rather than reporting where a JSON parser gave up.
    assert(message.canFind("/api/execute"), message);
    assert(message.canFind("502"), message);
    assert(message.canFind("Bad Gateway"), message);
}

private void testConnectionCloseIsHonoured()
{
    const envelope = successEnvelope("1");
    const closing = format!("HTTP/1.1 200 OK\r\nContent-type: application/json\r\n" ~
                            "Connection: close\r\nContent-length: %s\r\n\r\n%s")(
                            envelope.length, envelope);

    auto server = new FakeServer([
        Canned(healthOk),
        Canned(closing, true),
        Canned(ok(successEnvelope("2"))),
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    assert(conn.execute("SELECT 1").value.asLong == 1);
    // The driver must notice the close and open a fresh socket rather than
    // writing the next statement into a dead one.
    assert(conn.execute("SELECT 2").value.asLong == 2);
}

private void testErrorEnvelopeOn500()
{
    // The engine answers a refused statement with HTTP 500 carrying the
    // ordinary envelope. Treating the status as a transport failure would turn
    // every rejected statement into a connection error.
    const envelope = `{"errorMessage":"Numeric value 'Inf' is not recognized",` ~
                     `"executionTimeMs":0,"resultSets":[],"sessionId":null,"success":false}`;
    const response = format!"HTTP/1.1 500 Internal Server Error\r\nContent-type: application/json\r\nContent-length: %s\r\n\r\n%s"(
        envelope.length, envelope);

    auto server = new FakeServer([
        Canned(healthOk),
        Canned(response),
        Canned(ok(successEnvelope("5"))),
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    QueryException caught;
    try
        conn.execute("SELECT 'Inf'::DOUBLE");
    catch (QueryException e)
        caught = e;
    assert(caught !is null, "a 500 with an error envelope should be a QueryException");
    assert(caught.msg.canFind("not recognized"), caught.msg);
    assert(caught.status == 500);
    // ...and the connection is still usable afterwards.
    assert(conn.execute("SELECT 5").value.asLong == 5);
}

private void testTruncatedResponse()
{
    const envelope = successEnvelope("1");
    const full = format!"HTTP/1.1 200 OK\r\nContent-type: application/json\r\nContent-length: %s\r\n\r\n%s"(
        envelope.length, envelope);

    auto server = new FakeServer([
        Canned(healthOk),
        Canned(full, false, full.length - 20),   // promised more than it sends
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    const message = collectExceptionMsg!ConnectionException(conn.execute("SELECT 1"));
    assert(message.canFind("closed the connection"), message);
}

private void testKeepAliveReusesOneSocket()
{
    Canned[] script = [Canned(healthOk)];
    foreach (i; 0 .. 25)
        script ~= Canned(ok(successEnvelope(i.to!string)));

    auto server = new FakeServer(script);
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    // The scripted server serves every one of these on the connection it
    // accepted first; if the driver opened a new socket per statement the
    // second would never be answered.
    foreach (i; 0 .. 25)
        assert(conn.execute("SELECT " ~ i.to!string).value.asLong == i);
}

private void testWireFailuresDropTheSocket()
{
    // Each answer breaks the exchange a different way. After every one the
    // socket is gone, so nothing half-read can reach the next exchange.
    auto server = new FakeServer([
        Canned("HTTP/1.1 200 OK\r\nContent-length: 300000000\r\n\r\n{\"status\""),
        Canned("SMTP ready\r\n\r\n"),
        Canned("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"),
        Canned("HTTP/1.1 200 OK\r\nContent-length: many\r\n\r\n"),
    ]);
    scope (exit) server.stop();

    auto client = new HttpClient(parseDsn(server.dsn));
    foreach (expected; ["past this driver's limit", "not HTTP", "not a size", "not a number"])
    {
        const message = collectExceptionMsg!ConnectionException(
            client.exchange("GET", "/api/health", ""));
        assert(message.canFind(expected), message);
        assert(!client.isOpen, "the socket outlived: " ~ message);
    }
}

private void testSystemWorkInATransaction()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(successEnvelope())),      // BEGIN
        Canned(ok(successEnvelope())),      // SELECT 1
        Canned(ok(successEnvelope())),      // COMMIT
    ]);
    scope (exit) server.stop();
    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    // Unannotated code is @system, and a transaction's work may call it.
    static size_t calls;
    static void systemCode() @system { calls++; }
    conn.transaction({
        systemCode();
        conn.execute("SELECT 1");
    });
    assert(calls == 1);
    const sent = statementsSent(server);
    assert(sent == ["BEGIN", "SELECT 1", "COMMIT"], sent.to!string);
}

private void testAnErrorInATransactionRollsItBack()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(successEnvelope())),      // BEGIN
        Canned(ok(successEnvelope())),      // ROLLBACK
    ]);
    scope (exit) server.stop();
    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    // An Error is no Exception, but it still ends the transaction: the
    // rollback goes out, and the Error itself reaches the caller.
    string reached;
    try
        conn.transaction({ throw new Error("deliberate"); });
    catch (Error e)
        reached = e.msg;
    assert(reached == "deliberate", "the Error itself should reach the caller");
    assert(!conn.inTransaction);
    const sent = statementsSent(server);
    assert(sent == ["BEGIN", "ROLLBACK"], sent.to!string);
}

private void testLookalikeCountersAreData()
{
    const grid = `{"errorMessage":null,"resultSets":[{"columns":[{"dataType":"NUMBER",` ~
                 `"name":"number of apples","nullable":false,"precision":1,"scale":0}],` ~
                 `"rowCount":1,"rows":[[5]]}],"sessionId":"s1","success":true}`;
    auto server = new FakeServer([Canned(healthOk), Canned(ok(grid))]);
    scope (exit) server.stop();
    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    auto result = conn.execute(`SELECT 5 AS "number of apples"`);
    assert(!result.isUpdate);
    assert(result.updateCount == -1);
    assert(result.value.asLong == 5);
}

private void testAContainerCellIsItsJsonText()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(successEnvelope(`[1,{"k":"v"}]`))),
    ]);
    scope (exit) server.stop();
    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    const text = conn.execute("SELECT ARRAY_CONSTRUCT(1, OBJECT_CONSTRUCT('k', 'v'))").value.text;
    assert(text == `[1,{"k":"v"}]`, text);
}

private void testAnUnsetOptionKeepsTheDsnBound()
{
    auto server = new FakeServer([Canned(healthOk)]);
    scope (exit) server.stop();

    ConnectOptions options;
    options.timeout = Duration.zero;
    auto conn = connect(server.dsn ~ "?timeout=5s&idleLimit=1m", options);
    scope (exit) conn.close();
    // Set to zero, the option removes the DSN's bound; left unset, it keeps it.
    assert(conn.configuration.timeout == Duration.zero);
    assert(conn.configuration.idleLimit == minutes(1));
}

private void testAnIpv6HostIsBracketed()
{
    FakeServer server;
    try
        server = new FakeServer([Canned(healthOk), Canned(ok(successEnvelope("6")))], true);
    catch (Exception e)
    {
        writefln("          (no IPv6 loopback here, so not exercised: %s)", e.msg);
        return;
    }
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();
    assert(conn.baseUrl == format!"http://[::1]:%s"(server.port), conn.baseUrl);
    assert(conn.execute("SELECT 6").value.asLong == 6);
    const host = format!"\r\nHost: [::1]:%s\r\n"(server.port);
    foreach (request; server.requests)
        assert(request.canFind(host), request);
}

private void testAStatementCountTravelsOnlyWhenAsked()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(successEnvelope("1"))),
        Canned(ok(successEnvelope("2"))),
        Canned(ok(successEnvelope("3"))),
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn);
    scope (exit) conn.close();

    conn.execute("SELECT 1");
    ExecuteOptions packed;
    packed.multiStatementCount = 2;
    conn.executeAll("SELECT 1; SELECT 2", packed);
    // Zero is a count like any other — any number of statements — not an absent one.
    ExecuteOptions any;
    any.multiStatementCount = 0;
    conn.execute("SELECT 1; SELECT 2; SELECT 3", any);

    auto bodies = bodiesSent(server);
    assert(bodies.length == 3, bodies.length.to!string);
    // Nothing asked for a count, so the body carries no such field at all — not
    // null, not zero — and the session answers for the request as it always has.
    assert(!bodies[0].canFind("multiStatementCount"), bodies[0]);
    assert(bodies[1].canFind(`"multiStatementCount":2`), bodies[1]);
    assert(bodies[2].canFind(`"multiStatementCount":0`), bodies[2]);
}

// ------------------------------------------------------------ the session

/// The scope a DSN naming database APP selects.
private enum useApp = `USE DATABASE "APP"`;

private void testTheSessionFlagWaitsForTheEngine()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(sessionEnvelope("s1", true))),     // USE DATABASE, which starts the session
        Canned(ok(sessionEnvelope("s1", false))),    // SELECT 1
        Canned(released()),                          // DELETE, on close
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn ~ "/APP");
    conn.execute("SELECT 1");
    conn.close();

    auto sent = received(server);
    assert(sent.length == 4, sent.length.to!string);
    // Nothing is known before the first answer, so the request that starts the
    // session carries neither an id nor the flag.
    assert(sent[1].sql == useApp, sent[1].sql);
    assert(sent[1].sessionId == "" && !sent[1].carriesRequireSession, sent[1].to!string);
    // That answer carried newSession, so every request naming the session
    // requires it from then on.
    assert(sent[2].sessionId == "s1" && sent[2].requireSession, sent[2].to!string);
}

private void testAnOlderEngineIsSentNoSessionFlag()
{
    // Engines before 0.1.0 answer no newSession, and know neither
    // requireSession nor DELETE /api/sessions: their parser may refuse a field
    // it does not know.
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(successEnvelope())),     // USE DATABASE
        Canned(ok(successEnvelope())),     // SELECT 1
        Canned(ok(successEnvelope())),     // what a stray DELETE would get
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn ~ "/APP");
    conn.execute("SELECT 1");
    conn.close();

    auto sent = received(server);
    assert(sent.length == 3, sent.to!string);
    assert(sent[2].sessionId == "s1", sent[2].to!string);
    assert(!sent[2].carriesRequireSession, "an older engine was sent requireSession");
}

private void testALostSessionIsReplacedOnce()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(sessionEnvelope("s1", true))),        // USE DATABASE
        Canned(ok(sessionEnvelope("s1", false))),       // CREATE TABLE, which is no context
        Canned(sessionGone("s1")),                      // SELECT 7: the session is gone
        Canned(ok(sessionEnvelope("s2", true))),        // USE DATABASE, in a fresh session
        Canned(ok(sessionEnvelope("s2", false, "7"))),  // SELECT 7, once more
        Canned(released()),
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn ~ "/APP");
    conn.execute("CREATE TABLE t (a INT)");
    assert(conn.execute("SELECT 7").value.asLong == 7);
    assert(conn.sessionId == "s2", conn.sessionId);
    conn.close();

    const statements = statementsSent(server);
    assert(statements == [useApp, "CREATE TABLE t (a INT)", "SELECT 7", useApp, "SELECT 7"],
           statements.to!string);
    auto sent = received(server);
    // The scope went onto a fresh session, named by no id, and the statement
    // followed it there.
    assert(sent[4].sessionId == "" && !sent[4].carriesRequireSession, sent[4].to!string);
    assert(sent[5].sessionId == "s2" && sent[5].requireSession, sent[5].to!string);
    assert(sent[6].method == "DELETE" && sent[6].path == "/api/sessions/s2", sent[6].to!string);
}

private void testASecondLossRaises()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(sessionEnvelope("s1", true))),        // USE DATABASE
        Canned(sessionGone("s1")),                      // SELECT 1
        Canned(ok(sessionEnvelope("s2", true))),        // USE DATABASE, in a fresh session
        Canned(sessionGone("s2")),                      // SELECT 1, refused again
        Canned(ok(sessionEnvelope("s3", true))),        // the next statement starts over
        Canned(ok(sessionEnvelope("s3", false, "2"))),  // SELECT 2
        Canned(released()),
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn ~ "/APP");
    auto lost = collectException!SessionLostException(conn.execute("SELECT 1"));
    assert(lost !is null, "a second refusal should raise");
    assert(lost.statement == "SELECT 1", lost.statement);
    assert(conn.isOpen);

    // The connection carries on: the next statement starts a fresh session on
    // the DSN's scope.
    assert(conn.execute("SELECT 2").value.asLong == 2);
    conn.close();
    const statements = statementsSent(server);
    assert(statements == [useApp, "SELECT 1", useApp, "SELECT 1", useApp, "SELECT 2"],
           statements.to!string);
}

private void testALostTransactionIsReported()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(sessionEnvelope("s1", true))),     // USE DATABASE
        Canned(ok(sessionEnvelope("s1", false))),    // BEGIN
        Canned(sessionGone("s1")),                   // INSERT: the session is gone
        Canned(ok(sessionEnvelope("s2", true))),     // the next statement starts over
        Canned(ok(sessionEnvelope("s2", false))),    // SELECT 1
        Canned(released()),
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn ~ "/APP");
    conn.begin();
    auto lost = collectException!SessionLostException(conn.execute("INSERT INTO t VALUES (1)"));
    assert(lost !is null, "a lost transaction should raise");
    assert(lost.msg.canFind("transaction"), lost.msg);
    assert(!conn.inTransaction);
    assert(conn.isOpen);
    conn.execute("SELECT 1");
    conn.close();

    // The INSERT was not sent again, and the next statement started over on the
    // DSN's scope with autocommit back on.
    const statements = statementsSent(server);
    assert(statements == [useApp, "BEGIN", "INSERT INTO t VALUES (1)", useApp, "SELECT 1"],
           statements.to!string);
    auto sent = received(server);
    assert(sent[4].sessionId == "" && sent[4].autoCommit, sent[4].to!string);
    assert(sent[5].autoCommit, sent[5].to!string);
}

private void testATransactionBegunAsAStatementIsTracked()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(sessionEnvelope("s1", true))),     // USE DATABASE
        Canned(ok(sessionEnvelope("s1", false))),    // BEGIN TRANSACTION
        Canned(ok(sessionEnvelope("s1", false))),    // COMMIT
        Canned(ok(sessionEnvelope("s1", false))),    // START TRANSACTION
        Canned(sessionGone("s1")),                   // INSERT: the session is gone
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn ~ "/APP");
    conn.execute("BEGIN TRANSACTION");
    assert(conn.inTransaction);
    conn.execute("COMMIT");
    assert(!conn.inTransaction);
    conn.execute("START TRANSACTION");
    assert(conn.inTransaction);
    auto lost = collectException!SessionLostException(conn.execute("INSERT INTO t VALUES (1)"));
    assert(lost !is null && lost.msg.canFind("transaction"), lost is null ? "nothing raised" : lost.msg);
    assert(!conn.inTransaction);
    // The session is gone, so there is nothing left to release.
    conn.close();
    const statements = statementsSent(server);
    assert(statements == [useApp, "BEGIN TRANSACTION", "COMMIT", "START TRANSACTION",
                          "INSERT INTO t VALUES (1)"], statements.to!string);
}

private void testALostContextIsReported()
{
    // Each of these leaves something behind that a fresh session would not
    // have, so re-running the next statement in one would run it elsewhere.
    foreach (context; ["USE SCHEMA OTHER", "SET v = 1", "ALTER SESSION SET TIMEZONE = 'UTC'",
                       "CREATE TEMPORARY TABLE scratch (a INT)"])
    {
        auto server = new FakeServer([
            Canned(healthOk),
            Canned(ok(sessionEnvelope("s1", true))),     // USE DATABASE
            Canned(ok(sessionEnvelope("s1", false))),    // the context
            Canned(sessionGone("s1")),                   // SELECT: the session is gone
            Canned(ok(sessionEnvelope("s2", true))),     // the next statement starts over
            Canned(ok(sessionEnvelope("s2", false))),    // SELECT 1
            Canned(released()),
        ]);
        scope (exit) server.stop();

        auto conn = connect(server.dsn ~ "/APP");
        conn.execute(context);
        auto lost = collectException!SessionLostException(conn.execute("SELECT * FROM t"));
        assert(lost !is null, "no error after " ~ context);
        assert(lost.msg.canFind("context"), lost.msg);
        conn.execute("SELECT 1");
        conn.close();
        const statements = statementsSent(server);
        assert(statements == [useApp, context, "SELECT * FROM t", useApp, "SELECT 1"],
               statements.to!string);
    }
}

private void testAReplacedSessionGetsItsScopeBack()
{
    // An engine that ran a request in a fresh session in place of the one it
    // named says so with newSession: true; what the old one held is gone.
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(sessionEnvelope("s1", true))),         // USE DATABASE
        Canned(ok(sessionEnvelope("s1", true, "1"))),    // SELECT 1, in a fresh session
        Canned(ok(sessionEnvelope("s1", false))),        // USE DATABASE, again
        Canned(ok(sessionEnvelope("s1", false, "2"))),   // SELECT 2
        Canned(released()),
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn ~ "/APP");
    assert(conn.execute("SELECT 1").value.asLong == 1);
    assert(conn.execute("SELECT 2").value.asLong == 2);
    conn.close();
    const statements = statementsSent(server);
    assert(statements == [useApp, "SELECT 1", useApp, "SELECT 2"], statements.to!string);
}

private void testIdleRescopeIsForOlderEnginesOnly()
{
    ConnectOptions options;
    options.idleLimit = msecs(1);

    // An engine that answers newSession refuses a lapsed session instead of
    // rebuilding it, and the refusal is recovered from where it lands: no USE
    // goes ahead of a statement on a hunch, however long the connection idled.
    {
        auto server = new FakeServer([
            Canned(healthOk),
            Canned(ok(sessionEnvelope("s1", true))),     // USE DATABASE
            Canned(ok(sessionEnvelope("s1", false))),    // SELECT 1
            Canned(ok(sessionEnvelope("s1", false))),    // SELECT 2
            Canned(released()),
        ]);
        scope (exit) server.stop();
        auto conn = connect(server.dsn ~ "/APP", options);
        conn.execute("SELECT 1");
        Thread.sleep(msecs(20));
        conn.execute("SELECT 2");
        conn.close();
        const statements = statementsSent(server);
        assert(statements == [useApp, "SELECT 1", "SELECT 2"], statements.to!string);
    }

    // An older engine rebuilds a lapsed session under the same id without a
    // word, so past the limit the scope goes back on first.
    {
        Canned[] script = [Canned(healthOk)];
        foreach (i; 0 .. 6)
            script ~= Canned(ok(successEnvelope()));
        auto server = new FakeServer(script);
        scope (exit) server.stop();
        auto conn = connect(server.dsn ~ "/APP", options);
        conn.execute("SELECT 1");
        Thread.sleep(msecs(20));
        conn.execute("SELECT 2");
        conn.close();
        const statements = statementsSent(server);
        assert(statements.length >= 4 && statements[$ - 2 .. $] == [useApp, "SELECT 2"],
               statements.to!string);
    }
}

private void testClosingReleasesTheSessionOnce()
{
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(sessionEnvelope("s1", true))),     // USE DATABASE
        Canned(ok(sessionEnvelope("s1", false))),    // BEGIN
        Canned(released()),                          // DELETE, which rolls the transaction back
        Canned(released()),                          // what a second DELETE would get
    ]);
    scope (exit) server.stop();

    auto conn = connect(server.dsn ~ "/APP");
    conn.begin();
    conn.close();
    assert(!conn.isOpen);
    assert(conn.sessionId == "", conn.sessionId);
    conn.close();
    assertThrown!UsageException(conn.execute("SELECT 1"));

    auto sent = received(server);
    assert(sent.length == 4, sent.to!string);
    assert(sent[3].method == "DELETE" && sent[3].path == "/api/sessions/s1", sent[3].to!string);
}

private void testClosingNeverRaises()
{
    // Whatever the DELETE meets, closing returns quietly and within its bound —
    // here the DSN's 300 ms timeout, which is shorter than the five seconds
    // closing would otherwise allow itself.
    const refusal = `{"errorMessage":"Session 's1' does not exist or has expired.",` ~
                    `"executionTimeMs":0,"newSession":false,"resultSets":[],"sessionId":null,` ~
                    `"success":false}`;
    Canned[] answers = [
        Canned(format!"HTTP/1.1 404 Not Found\r\nContent-type: application/json\r\nContent-length: %s\r\n\r\n%s"(
            refusal.length, refusal)),
        Canned("HTTP/1.1 405 Method Not Allowed\r\nContent-length: 0\r\n\r\n"),
        Canned("", true),                      // hangs up without a word
        Canned("", false, size_t.max, true),   // never answers
    ];
    foreach (i, answer; answers)
    {
        auto server = new FakeServer([Canned(healthOk), Canned(ok(sessionEnvelope("s1", true))), answer]);
        scope (exit) server.stop();
        auto conn = connect(server.dsn ~ "/APP?timeout=300ms");

        const started = MonoTime.currTime;
        conn.close();       // nothrow, so nothing can escape it
        const took = MonoTime.currTime - started;
        assert(took < seconds(3), format!"case %s: closing took %s"(i, took));
        assert(!conn.isOpen);
        auto sent = received(server);
        assert(sent.length == 3 && sent[2].method == "DELETE", format!"case %s: %s"(i, sent));
    }
}

private void testARefusedScopeReleasesItsSession()
{
    // The engine refused the USE, but in a session it started for it.
    const refused = `{"errorMessage":"Database 'APP' does not exist or not authorized.",` ~
                    `"executionTimeMs":0,"newSession":true,"resultSets":[],"sessionId":"s9",` ~
                    `"success":false}`;
    auto server = new FakeServer([
        Canned(healthOk),
        Canned(ok(refused)),     // USE DATABASE
        Canned(released()),      // DELETE
    ]);
    scope (exit) server.stop();

    const message = collectExceptionMsg!QueryException(connect(server.dsn ~ "/APP"));
    assert(message.canFind("APP"), message);
    auto sent = received(server);
    assert(sent.length == 3, sent.to!string);
    assert(sent[2].method == "DELETE" && sent[2].path == "/api/sessions/s9", sent[2].to!string);
}

import std.socket;
