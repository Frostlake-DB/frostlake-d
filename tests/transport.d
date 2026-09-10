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

import core.thread : Thread;
import core.time : msecs, seconds;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.exception : collectExceptionMsg;
import std.format : format;
import std.socket : InternetAddress, Socket, SocketSet, SocketShutdown, TcpSocket;
import std.stdio : writefln;
import std.string : indexOf, toLower;

import frostlake;

/// A canned response, plus what the server should do after sending it.
struct Canned
{
    string raw;
    /// Hang up after writing this one.
    bool thenClose;
    /// Write only the first `truncateTo` bytes, then hang up.
    size_t truncateTo = size_t.max;
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

/// A scripted server on a port of its own.
final class FakeServer
{
    private TcpSocket listener;
    private Thread thread;
    private shared bool stopping;
    Canned[] script;
    ushort port;

    this(Canned[] script)
    {
        this.script = script;
        listener = new TcpSocket();
        listener.setOption(std.socket.SocketOptionLevel.SOCKET,
                           std.socket.SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(8);
        port = (cast(InternetAddress) listener.localAddress).port;
        thread = new Thread(&serve);
        thread.isDaemon = true;
        thread.start();
    }

    string dsn() const
    {
        return format!"frostlake://127.0.0.1:%s"(port);
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
                if (!readRequest(client)) break;
                auto canned = script[next++];
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

    /// Reads one whole request, so the next response lands on a clean stream.
    private static bool readRequest(Socket client)
    {
        auto buffer = appender!(char[]);
        ubyte[4096] scratch;
        ptrdiff_t headerEnd = -1;
        while (headerEnd < 0)
        {
            const got = client.receive(scratch[]);
            if (got <= 0) return false;
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
            if (got <= 0) return false;
            have += got;
        }
        return true;
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
];

private immutable string[] testNames = [
    "a chunked response body is reassembled",
    "header names are matched case-insensitively",
    "a body that is not a Frostlake answer names the endpoint",
    "Connection: close is honoured and the socket re-opened",
    "an error envelope on HTTP 500 is a query error, not a transport one",
    "a response cut off mid-body fails as a transport error",
    "many statements ride one keep-alive socket",
];

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

import std.socket;
