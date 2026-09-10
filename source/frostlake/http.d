/**
 * The HTTP/1.1 transport: one socket, held open across statements.
 *
 * Phobos offers $(D std.net.curl), and this does not use it, for two reasons
 * that are both about what a database driver needs and a general web client
 * does not:
 *
 * $(UL
 * $(LI $(B One socket for the connection's whole life.) A driver that opens a
 *      socket per statement burns an ephemeral TCP port per statement. A run
 *      of a few thousand statements will empty a machine's dynamic port
 *      range — on Windows that is 49152–65535, and closed sockets sit in
 *      TIME_WAIT for minutes afterwards — and the failures then land on
 *      whatever runs $(I next). Here the socket is opened once and every
 *      statement rides it.)
 * $(LI $(B The deadline is the caller's.) One deadline bounds the whole
 *      exchange — connect, write, status line, headers and body — rather than
 *      any single read, so a server dribbling one byte a minute cannot outlast
 *      it by resetting a per-read timer.)
 * )
 *
 * The socket is non-blocking and every wait goes through $(D Socket.select),
 * which is what makes the single deadline enforceable at all.
 */
module frostlake.http;

import core.time : dur, Duration, MonoTime, msecs, seconds;

import std.array : appender, Appender;
import std.conv : ConvException, to;
import std.format : format;
import std.socket : Address, AddressFamily, getAddress, Socket, SocketException,
                    SocketOption, SocketOptionLevel, SocketOSException, SocketSet,
                    SocketShutdown, SocketType, TcpSocket, wouldHaveBlocked;
import std.string : indexOf, strip, toLower;

import frostlake.dsn : DsnConfig;
import frostlake.errors;

/// One HTTP response, read whole.
struct HttpResponse
{
    int status;
    string reason;
    /// Header names folded to lower case — this server spells it
    /// `Content-length`, and folding here is what keeps that from mattering.
    string[string] headers;
    string content;
    /// Whether the server said this socket may not be reused.
    bool close;
}

/// The largest response body this client will accumulate, as a guard against a
/// server that promises more than there is memory for.
private enum size_t maxBodyBytes = 256 * 1024 * 1024;

/**
 * A keep-alive HTTP/1.1 connection to one server.
 *
 * The socket is opened on demand and replaced when the far side closes it. A
 * statement is never re-sent: if the exchange breaks part way through, the
 * socket is dropped and the failure reported, because a statement that may
 * already have run must not silently run twice.
 *
 * There is deliberately no destructor. A class destructor runs during a
 * collection, where reaching for another GC-managed object is not valid — and
 * $(D std.socket.Socket) already closes its own handle when it is finalised, so
 * a forgotten client still gives its socket back. Call $(D disconnect) to give
 * it back promptly.
 */
final class HttpClient
{
    private DsnConfig config;
    private Socket socket;
    private ubyte[] buffer;      // bytes read but not yet consumed
    private size_t cursor;       // how far into `buffer` the reader has got

    this(DsnConfig config) @safe
    {
        this.config = config;
    }

    /// Whether a socket is currently held.
    @property bool isOpen() const @safe pure nothrow @nogc { return socket !is null; }

    /// Drops the socket, if there is one.
    void disconnect() @trusted nothrow
    {
        if (socket is null) return;
        try
        {
            socket.shutdown(SocketShutdown.BOTH);
            socket.close();
        }
        catch (Exception) { }
        socket = null;
        buffer = null;
        cursor = 0;
    }

    /**
     * Whether the held socket cannot carry another request.
     *
     * Between exchanges there is nothing left to read — the body was read to
     * its stated length — so anything readable now is either the close the
     * server did while we were idle, or a desynchronised stream. Either way the
     * socket is replaced, and it is replaced $(I before) the statement is
     * written, which is what keeps this from ever re-sending one that may
     * already have run.
     */
    bool isStale() @trusted nothrow
    {
        if (socket is null) return true;
        if (cursor < buffer.length) return true;
        try
        {
            auto readable = new SocketSet(1);
            readable.add(socket);
            if (Socket.select(readable, null, null, Duration.zero) <= 0)
                return false;
            // Readable between exchanges means EOF or unexpected bytes.
            ubyte[1] peek;
            const got = socket.receive(peek[]);
            return !(got == Socket.ERROR && wouldHaveBlocked());
        }
        catch (Exception)
            return true;
    }

    /**
     * Opens the socket, waiting no longer than the DSN's connect timeout.
     *
     * Throws: $(D ConnectionException) when the server cannot be reached, and
     * $(D UsageException) for an `https` DSN, which this build cannot speak.
     */
    void connect() @trusted
    {
        disconnect();

        if (config.secure)
            throw new UsageException(
                "this driver speaks plain HTTP only: Phobos ships no TLS, and " ~
                "quietly sending an https:// DSN in the clear would be worse " ~
                "than refusing it. Put a TLS-terminating proxy in front of the " ~
                "engine and point the DSN at that.");

        const endpoint = config.baseUrl;
        Address[] addresses;
        try
            addresses = getAddress(config.host, config.port);
        catch (SocketException e)
            throw new ConnectionException(
                format!"cannot resolve %s: %s"(config.host, e.msg), endpoint);
        if (addresses.length == 0)
            throw new ConnectionException(
                format!"%s resolved to no addresses"(config.host), endpoint);

        string lastProblem;
        foreach (address; addresses)
        {
            try
            {
                socket = openTo(address, endpoint);
                return;
            }
            catch (ConnectionException e)
            {
                lastProblem = e.msg;
                disconnect();
            }
        }
        throw new ConnectionException(lastProblem, endpoint);
    }

    private Socket openTo(Address address, string endpoint) @trusted
    {
        auto candidate = new TcpSocket(address.addressFamily);
        scope (failure) { try candidate.close(); catch (Exception) { } }

        candidate.blocking = false;
        // Nagle would hold a small request back waiting for more; a statement
        // is one write and there is never more coming.
        candidate.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);

        try
            candidate.connect(address);
        catch (SocketOSException e)
        {
            if (!wouldHaveBlocked())
                throw new ConnectionException(
                    format!"cannot reach %s: %s"(endpoint, e.msg), endpoint);
        }

        const deadline = config.connectTimeout == Duration.zero
            ? MonoTime.max : MonoTime.currTime + config.connectTimeout;
        SocketSet writable, failed;
        int ready;
        for (;;)
        {
            // `select` empties the sets it is given, so every wait starts afresh.
            writable = new SocketSet(1);
            failed = new SocketSet(1);
            writable.add(candidate);
            failed.add(candidate);
            if (deadline == MonoTime.max)
            {
                // An unbounded wait is the overload WITHOUT a timeout: `Duration.max`
                // splits into a seconds count that overflows the `int` a Windows
                // timeval holds, and a negative timeval makes select fail at once.
                ready = Socket.select(null, writable, failed);
            }
            else
            {
                const remaining = deadline - MonoTime.currTime;
                if (remaining <= Duration.zero) { ready = 0; break; }
                const slice = clampWait(remaining);
                ready = Socket.select(null, writable, failed, slice);
                if (ready == 0 && slice < remaining) continue;
            }
            // A signal cut the wait short with nothing to report (on POSIX,
            // druntime stops every thread with one for each collection), so
            // wait out whatever time is left.
            if (ready < 0) continue;
            break;
        }
        if (ready == 0)
            throw new ConnectionException(format!
                "%s did not accept a connection within %s"(
                endpoint, describe(config.connectTimeout)), endpoint);

        // A non-blocking connect reports its failure here, not at `connect`.
        int problem;
        candidate.getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, problem);
        if (problem != 0 || failed.isSet(candidate))
            throw new ConnectionException(
                format!"cannot reach %s: connection failed (error %s)"(endpoint, problem),
                endpoint);

        return candidate;
    }

    /**
     * Sends one request and reads its whole response.
     *
     * Throws: $(D ConnectionException) if anything goes wrong on the wire. The
     * socket is dropped in that case; nothing is re-sent.
     */
    HttpResponse exchange(string method, string path, string payload) @trusted
    {
        if (socket is null) connect();

        const endpoint = config.baseUrl ~ path;
        const limit = config.timeout;
        // One deadline for the whole exchange.
        const deadline = limit == Duration.zero ? MonoTime.max : MonoTime.currTime + limit;

        auto request = appender!string();
        request.put(method);
        request.put(' ');
        request.put(path);
        request.put(" HTTP/1.1\r\nHost: ");
        request.put(config.host);
        request.put(':');
        request.put(config.port.to!string);
        request.put("\r\nUser-Agent: frostlake-d/");
        request.put(driverVersion);
        request.put("\r\nAccept: application/json\r\nConnection: keep-alive\r\n");
        if (method != "GET" && method != "HEAD")
        {
            request.put("Content-Type: application/json\r\nContent-Length: ");
            request.put(payload.length.to!string);
            request.put("\r\n");
        }
        request.put("\r\n");
        request.put(payload);

        buffer = null;
        cursor = 0;
        sendAll(cast(const(ubyte)[]) request.data, endpoint, deadline, limit);

        auto response = readResponse(method, endpoint, deadline, limit);
        if (response.close) disconnect();
        return response;
    }

    // ------------------------------------------------------------- writing

    private void sendAll(const(ubyte)[] bytes, string endpoint,
                         MonoTime deadline, Duration limit) @trusted
    {
        size_t sent;
        while (sent < bytes.length)
        {
            const wrote = socket.send(bytes[sent .. $]);
            if (wrote == Socket.ERROR)
            {
                if (!wouldHaveBlocked())
                    fail(format!"cannot write to %s"(endpoint), endpoint);
                waitFor(false, endpoint, deadline, limit);
                continue;
            }
            if (wrote == 0)
                fail(format!"%s closed the connection while the request was being sent"(endpoint),
                     endpoint);
            sent += wrote;
        }
    }

    // ------------------------------------------------------------- reading

    private HttpResponse readResponse(string method, string endpoint,
                                      MonoTime deadline, Duration limit) @trusted
    {
        HttpResponse response;

        const statusLine = readLine(endpoint, deadline, limit);
        const(char)[] rest = statusLine;
        if (rest.length < 8 || rest[0 .. 5] != "HTTP/")
            throw new ConnectionException(format!
                "%s answered something that is not HTTP: %s"(endpoint, snippet(statusLine)),
                endpoint);
        const versionEnd = rest.indexOf(' ');
        if (versionEnd < 0)
            throw new ConnectionException(format!
                "%s answered a malformed status line: %s"(endpoint, snippet(statusLine)),
                endpoint);
        const httpVersion = rest[5 .. versionEnd];
        rest = rest[versionEnd + 1 .. $].strip();
        const codeEnd = rest.indexOf(' ');
        const codeText = codeEnd < 0 ? rest : rest[0 .. codeEnd];
        try
            response.status = codeText.to!int;
        catch (ConvException)
            throw new ConnectionException(format!
                "%s answered a malformed status line: %s"(endpoint, snippet(statusLine)),
                endpoint);
        response.reason = codeEnd < 0 ? "" : rest[codeEnd + 1 .. $].strip().idup;

        for (;;)
        {
            const line = readLine(endpoint, deadline, limit);
            if (line.length == 0) break;
            const colon = line.indexOf(':');
            if (colon < 0) continue;
            response.headers[line[0 .. colon].strip().toLower().idup]
                = line[colon + 1 .. $].strip().idup;
        }

        response.close = httpVersion == "1.0";
        if (auto connection = "connection" in response.headers)
            response.close = (*connection).toLower().indexOf("close") >= 0;

        response.content = readBody(method, response, endpoint, deadline, limit);
        return response;
    }

    private string readBody(string method, ref HttpResponse response, string endpoint,
                            MonoTime deadline, Duration limit) @trusted
    {
        // A response to HEAD, and the statuses defined to carry no body, have
        // none however the headers read.
        if (method == "HEAD" || response.status == 204 || response.status == 304
            || (response.status >= 100 && response.status < 200))
            return "";

        if (auto encoding = "transfer-encoding" in response.headers)
            if ((*encoding).toLower().indexOf("chunked") >= 0)
                return readChunked(endpoint, deadline, limit);

        if (auto length = "content-length" in response.headers)
        {
            size_t count;
            try
                count = (*length).strip().to!size_t;
            catch (ConvException)
                throw new ConnectionException(format!
                    "%s sent a Content-Length that is not a number: %s"(
                    endpoint, snippet(*length)), endpoint, response.status);
            if (count > maxBodyBytes)
                throw new ConnectionException(format!
                    "%s promised a %s-byte body, past this driver's limit"(endpoint, count),
                    endpoint, response.status);
            return cast(string) readExactly(count, endpoint, deadline, limit).idup;
        }

        // No length and no chunking: the body runs to end of stream, and the
        // socket cannot be reused afterwards.
        response.close = true;
        return readToEnd(endpoint, deadline, limit);
    }

    private string readChunked(string endpoint, MonoTime deadline, Duration limit) @trusted
    {
        auto content = appender!(ubyte[]);
        for (;;)
        {
            const header = readLine(endpoint, deadline, limit);
            // A chunk size may carry `;ext=value` extensions after a semicolon.
            const(char)[] sizeText = header;
            const semicolon = sizeText.indexOf(';');
            if (semicolon >= 0) sizeText = sizeText[0 .. semicolon];
            sizeText = sizeText.strip();

            size_t size;
            try
                size = sizeText.to!size_t(16);
            catch (ConvException)
                throw new ConnectionException(format!
                    "%s sent a chunk header that is not a size: %s"(endpoint, snippet(header)),
                    endpoint);

            if (size == 0)
            {
                // Trailers, then the blank line that ends them.
                while (readLine(endpoint, deadline, limit).length) { }
                return cast(string) content.data.idup;
            }
            if (content.data.length + size > maxBodyBytes)
                throw new ConnectionException(format!
                    "%s sent a body past this driver's limit"(endpoint), endpoint);
            content.put(readExactly(size, endpoint, deadline, limit));
            readLine(endpoint, deadline, limit);   // the CRLF after the chunk
        }
    }

    /// Reads one CRLF-terminated line, minus its terminator.
    private const(char)[] readLine(string endpoint, MonoTime deadline, Duration limit) @trusted
    {
        for (;;)
        {
            foreach (i; cursor .. buffer.length)
                if (buffer[i] == '\n')
                {
                    auto line = buffer[cursor .. i];
                    if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
                    cursor = i + 1;
                    return cast(const(char)[]) line;
                }
            fillMore(endpoint, deadline, limit);
        }
    }

    private const(ubyte)[] readExactly(size_t count, string endpoint,
                                       MonoTime deadline, Duration limit) @trusted
    {
        while (buffer.length - cursor < count)
            fillMore(endpoint, deadline, limit);
        auto slice = buffer[cursor .. cursor + count];
        cursor += count;
        return slice;
    }

    private string readToEnd(string endpoint, MonoTime deadline, Duration limit) @trusted
    {
        // Here end-of-stream is the terminator, not a failure — and it must be
        // read as one BEFORE the socket is dropped: `fail` clears the buffer,
        // which used to turn every close-delimited body into an empty one.
        while (fillMore(endpoint, deadline, limit, true))
        {
            if (buffer.length > maxBodyBytes)
                throw new ConnectionException(format!
                    "%s sent a body past this driver's limit"(endpoint), endpoint);
        }
        auto slice = buffer[cursor .. $];
        cursor = buffer.length;
        auto text = cast(string) slice.idup;
        // The server closed; nothing else can ride this socket.
        disconnect();
        return text;
    }

    /**
     * Waits for more bytes and appends them, or gives up on the deadline.
     * End of stream is a failure unless `eofEnds`, in which case it answers
     * false and leaves the buffer intact.
     */
    private bool fillMore(string endpoint, MonoTime deadline, Duration limit,
                          bool eofEnds = false) @trusted
    {
        ubyte[16 * 1024] scratch;
        for (;;)
        {
            const got = socket.receive(scratch[]);
            if (got > 0)
            {
                buffer ~= scratch[0 .. got];
                return true;
            }
            if (got == 0)
            {
                if (eofEnds) return false;
                fail(format!"%s closed the connection mid-response"(endpoint), endpoint);
            }
            if (!wouldHaveBlocked())
                fail(format!"cannot read from %s"(endpoint), endpoint);
            waitFor(true, endpoint, deadline, limit);
        }
    }

    /// The longest single `select` wait: a Windows timeval counts its seconds
    /// in an `int`, so a longer deadline is waited out in slices.
    private enum Duration maxSelectWait = dur!"hours"(1);

    private static Duration clampWait(Duration wait) @safe pure nothrow @nogc
    {
        return wait > maxSelectWait ? maxSelectWait : wait;
    }

    /// Blocks until the socket is ready, or the exchange's deadline passes.
    private void waitFor(bool forReading, string endpoint,
                         MonoTime deadline, Duration limit) @trusted
    {
        for (;;)
        {
            auto ready = new SocketSet(1);
            auto failed = new SocketSet(1);
            ready.add(socket);
            failed.add(socket);
            int outcome;
            if (deadline == MonoTime.max)
            {
                // No bound: the overload WITHOUT a timeout blocks. `Duration.max`
                // would overflow a Windows timeval and fail the wait at once.
                outcome = forReading
                    ? Socket.select(ready, null, failed)
                    : Socket.select(null, ready, failed);
            }
            else
            {
                const remaining = deadline - MonoTime.currTime;
                if (remaining <= Duration.zero) expired(endpoint, limit);
                const slice = clampWait(remaining);
                outcome = forReading
                    ? Socket.select(ready, null, failed, slice)
                    : Socket.select(null, ready, failed, slice);
                if (outcome == 0 && slice < remaining) continue;
            }
            if (outcome == 0) expired(endpoint, limit);
            // A signal cut the wait short with nothing to report (on POSIX,
            // druntime stops every thread with one for each collection), so
            // wait out whatever time is left.
            if (outcome < 0) continue;
            return;
        }
    }

    private void expired(string endpoint, Duration limit) @trusted
    {
        fail(format!"%s did not answer within %s"(endpoint, describe(limit)), endpoint);
    }

    /// Drops the socket and reports. Every wire failure comes through here, so
    /// none of them can leave a half-read socket behind to confuse the next
    /// statement.
    private void fail(string message, string endpoint) @trusted
    {
        disconnect();
        throw new ConnectionException(message, endpoint);
    }
}

/// The version this driver reports in its `User-Agent`.
enum string driverVersion = "0.1.0";

/// Renders a duration the way a person would say it.
string describe(Duration limit) @safe
{
    if (limit == Duration.zero) return "no time at all";
    const millis = limit.total!"msecs";
    if (millis < 1000) return format!"%sms"(millis);
    if (millis % 1000 == 0) return format!"%ss"(millis / 1000);
    return format!"%.3gs"(millis / 1000.0);
}

/// Trims a server's answer down to something an error message can carry.
string snippet(const(char)[] text) @safe pure
{
    auto trimmed = text.strip();
    if (trimmed.length == 0) return "(nothing)";
    if (trimmed.length > 512) return trimmed[0 .. 512].idup ~ "...";
    return trimmed.idup;
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    assert(describe(msecs(250)) == "250ms");
    assert(describe(seconds(30)) == "30s");
    assert(describe(msecs(1500)) == "1.5s");
    assert(describe(Duration.zero) == "no time at all");
}

@safe unittest
{
    assert(snippet("  hello  ") == "hello");
    assert(snippet("") == "(nothing)");
    assert(snippet("   ") == "(nothing)");
    auto long_ = new char[600];
    long_[] = 'x';
    assert(snippet(long_).length == 515);      // 512 plus the ellipsis
}

@safe unittest
{
    import std.exception : assertThrown, collectExceptionMsg;
    import frostlake.dsn : parseDsn;
    // An https DSN is refused outright rather than quietly sent in the clear.
    auto client = new HttpClient(parseDsn("https://example.invalid"));
    const message = collectExceptionMsg!UsageException(client.connect());
    assert(message.canFind("no TLS"));
}

@safe unittest
{
    import std.algorithm : canFind;
    import frostlake.dsn : parseDsn;
    // A host that cannot resolve is a connection failure naming the endpoint.
    auto config = parseDsn("frostlake://no-such-host.invalid:18082");
    config.connectTimeout = msecs(500);
    auto client = new HttpClient(config);
    assert(!client.isOpen);
    assert(client.isStale);          // nothing held is trivially unusable
    try
    {
        client.connect();
        assert(false, "connecting to an unresolvable host should fail");
    }
    catch (ConnectionException e)
        assert(e.endpoint == "http://no-such-host.invalid:18082");
}

private bool canFind(const(char)[] haystack, const(char)[] needle) @safe pure
{
    import std.string : indexOf;
    return haystack.indexOf(needle) >= 0;
}
