/**
 * Turning a connection string into everything a connection needs.
 *
 * The grammar is small and spelled out here rather than borrowed, which keeps
 * the package dependency-free:
 *
 * ---
 * frostlake://host[:port][/DATABASE][?schema=...&role=...&warehouse=...]
 * ---
 *
 * `http://` and `https://` mean the same thing; the custom scheme exists so a
 * DSN reads as a database URL rather than a web one.
 *
 * The parameter spellings match the other Frostlake drivers on purpose, so one
 * DSN string works across all of them.
 */
module frostlake.dsn;

import core.time : Duration, dur, msecs, seconds;
import std.algorithm : canFind, sort;
import std.array : appender, array, join, split;
import std.ascii : isDigit, isHexDigit;
import std.conv : ConvException, to;
import std.format : format;
import std.string : indexOf, lastIndexOf, strip, toLower;
import std.uni : toUpper;

import frostlake.errors;

/// The port a `DatabaseHttpServer` listens on unless told otherwise.
enum ushort defaultPort = 18082;

/// Long enough for a slow query, short enough that an unreachable host fails
/// while someone is still watching.
enum Duration defaultConnectTimeout = dur!"seconds"(10);
/// ditto
enum Duration defaultRequestTimeout = dur!"seconds"(300);

/// The engine reclaims a session after 30 minutes idle. Past that the driver
/// has to assume its own is gone, because nothing in a response says so. The
/// default sits under the engine's figure: the engine measures idleness from a
/// request's ARRIVAL and sweeps every five minutes, so a limit equal to its own
/// left a window — the length of the last statement — in which the session was
/// already gone while the driver still trusted it.
enum Duration defaultIdleLimit = dur!"minutes"(20);

/// Everything the DSN query string may carry. Anything else is a typo — and a
/// typo in `schema` or `timeout` changes behaviour without saying so.
immutable string[] dsnParameters = [
    "connectTimeout", "idleLimit", "role", "schema", "timeout", "tls", "warehouse"
];

/**
 * A parsed DSN: the server to speak to, the scope to select, and the three
 * deadlines a connection keeps.
 *
 * A zero $(D Duration) means "no bound", which is why 0 is accepted where a
 * negative number is not.
 */
struct DsnConfig
{
    string host;
    ushort port = defaultPort;
    bool secure;

    string database;
    string schema;
    string role;
    string warehouse;

    Duration connectTimeout = defaultConnectTimeout;
    Duration timeout = defaultRequestTimeout;
    Duration idleLimit = defaultIdleLimit;

    /// The server's base URL, without a trailing slash.
    string baseUrl() const @safe pure
    {
        return format!"%s://%s:%s"(secure ? "https" : "http", host, port);
    }

    /**
     * The scope this DSN names, rendered as the `USE` statements a fresh
     * session needs, in dependency order.
     *
     * Rebuilt on demand rather than cached, so a session that may have lapsed
     * can be put back on this scope.
     */
    string[] useStatements() const @safe pure
    {
        auto result = appender!(string[]);
        if (role.length)      result.put("USE ROLE " ~ useIdentifier(role));
        if (warehouse.length) result.put("USE WAREHOUSE " ~ useIdentifier(warehouse));
        if (database.length)  result.put("USE DATABASE " ~ useIdentifier(database));
        if (schema.length)    result.put("USE SCHEMA " ~ useIdentifier(schema));
        return result.data;
    }
}

/**
 * Quotes an identifier for use in a statement.
 *
 * Always quoted. Leaving "unambiguous" names bare lets through ones that cannot
 * legally appear that way — `1ABC` starts with a digit, `SELECT` is reserved —
 * and quoting costs nothing: `"NAME"` and `NAME` name the same object, so only
 * genuinely lower-case names are affected, and those had to be quoted anyway.
 * Embedded quotes are doubled, so a name arriving from a DSN cannot break out.
 */
string quoteIdentifier(const(char)[] name) @safe pure
{
    if (name.length == 0)
        throw new UsageException("an identifier cannot be empty");
    auto result = appender!string();
    result.reserve(name.length + 2);
    result.put('"');
    foreach (char c; name)
    {
        if (c == '"') result.put('"');
        result.put(c);
    }
    result.put('"');
    return result.data;
}

/**
 * A DSN name as a `USE` statement needs it. A plain name means what it means
 * unquoted in SQL — the upper-case object it folds to — so it is folded before
 * it is quoted; anything else is quoted exactly as given. Quoted as given, a
 * lower-case name would ask for a lower-case object, which `USE` refuses: it
 * resolves names exactly, as live does.
 */
private string useIdentifier(const(char)[] name) @safe pure
{
    import std.ascii : isAlpha, isAlphaNum, toUpper;

    bool plain = name.length > 0 && (isAlpha(name[0]) || name[0] == '_');
    foreach (char c; name)
    {
        if (!isAlphaNum(c) && c != '_' && c != '$')
            plain = false;
    }
    if (!plain)
        return quoteIdentifier(name);
    auto folded = new char[name.length];
    foreach (i, char c; name)
        folded[i] = cast(char) toUpper(c);
    return quoteIdentifier(folded);
}

/**
 * Parses a DSN.
 *
 * Throws: $(D UsageException) for anything malformed — an unknown scheme, a
 * port that is not a number, a parameter this driver does not know.
 */
DsnConfig parseDsn(string text) @safe pure
{
    const separator = text.indexOf("://");
    if (separator <= 0)
        throw new UsageException(
            "a DSN must start with frostlake://, http:// or https://, got \"" ~ text ~ "\"");

    const scheme = text[0 .. separator].toLower();
    if (scheme != "frostlake" && scheme != "http" && scheme != "https")
        throw new UsageException(
            "a DSN must start with frostlake://, http:// or https://, got \"" ~ scheme ~ "://\"");

    auto rest = text[separator + 3 .. $];

    // Strip the fragment, then the query, so neither can be mistaken for part
    // of the path.
    const hash = rest.indexOf('#');
    if (hash >= 0) rest = rest[0 .. hash];

    string query;
    const question = rest.indexOf('?');
    if (question >= 0)
    {
        query = rest[question + 1 .. $];
        rest = rest[0 .. question];
    }

    string path;
    const slash = rest.indexOf('/');
    if (slash >= 0)
    {
        path = rest[slash + 1 .. $];
        rest = rest[0 .. slash];
    }

    DsnConfig config;
    config.secure = scheme == "https";

    // The server authenticates nobody, so credentials in a DSN would be
    // silently dropped — and silently dropping a password is worse than saying so.
    if (rest.canFind('@'))
        throw new UsageException(
            "the server takes no credentials; remove user:password from the DSN");

    splitAuthority(rest, scheme, config);
    if (config.host.length == 0)
        throw new UsageException("the DSN is missing host[:port]");

    // The path names at most one database.
    auto segments = appender!(string[]);
    foreach (segment; path.split('/'))
        if (segment.length)
            segments.put(percentDecode(segment));
    if (segments.data.length > 1)
        throw new UsageException(
            format!"the DSN path names one database, got \"/%s\""(path));
    if (segments.data.length == 1)
        config.database = segments.data[0];

    applyQuery(query, config);
    return config;
}

private void splitAuthority(string authority, string scheme, ref DsnConfig config) @safe pure
{
    // A scheme with a port of its own keeps it: reading the engine's default
    // into `https://h` would quietly move the DSN to another port, so only the
    // custom scheme — which has no default of its own — falls back to 18082.
    ushort fallback = defaultPort;
    if (scheme == "http") fallback = 80;
    else if (scheme == "https") fallback = 443;

    if (authority.length && authority[0] == '[')
    {
        const close = authority.indexOf(']');
        if (close < 0)
            throw new UsageException("the DSN has an unclosed IPv6 address");
        config.host = authority[1 .. close];
        auto tail = authority[close + 1 .. $];
        if (tail.length == 0) { config.port = fallback; return; }
        if (tail[0] != ':')
            throw new UsageException("the DSN is missing host[:port]");
        config.port = parsePort(tail[1 .. $]);
        return;
    }

    const colon = authority.lastIndexOf(':');
    if (colon < 0)
    {
        config.host = authority;
        config.port = fallback;
        return;
    }
    config.host = authority[0 .. colon];
    config.port = parsePort(authority[colon + 1 .. $]);
}

private ushort parsePort(const(char)[] text) @safe pure
{
    if (text.length == 0)
        throw new UsageException("the DSN port must be a number, got \"\"");
    foreach (char c; text)
        if (!c.isDigit)
            throw new UsageException(
                "the DSN port must be a number, got \"" ~ text.idup ~ "\"");
    ulong value;
    // Parsed digit by digit rather than by `to!ushort`, so an out-of-range port
    // is reported as out of range rather than as an overflow.
    foreach (char c; text)
    {
        value = value * 10 + (c - '0');
        if (value > 65535)
            throw new UsageException(
                "the DSN port must be between 1 and 65535, got \"" ~ text.idup ~ "\"");
    }
    if (value < 1)
        throw new UsageException("the DSN port must be between 1 and 65535, got 0");
    return cast(ushort) value;
}

private void applyQuery(string query, ref DsnConfig config) @safe pure
{
    string[string] params;
    string[] order;
    foreach (pair; query.split('&'))
    {
        if (pair.length == 0) continue;
        const equals = pair.indexOf('=');
        const key = equals < 0 ? percentDecode(pair) : percentDecode(pair[0 .. equals]);
        const value = equals < 0 ? "" : percentDecode(pair[equals + 1 .. $]);
        if (key !in params) order ~= key;
        params[key] = value;
    }

    string[] unknown;
    foreach (key; order)
        if (!dsnParameters.canFind(key))
            unknown ~= key;
    if (unknown.length)
    {
        unknown.sort();
        throw new UsageException(format!"unknown DSN parameter: %s (expected %s)"(
            unknown.join(", "), dsnParameters.join(", ")));
    }

    if (auto p = "schema" in params)    config.schema    = nonEmpty("schema", *p);
    if (auto p = "role" in params)      config.role      = nonEmpty("role", *p);
    if (auto p = "warehouse" in params) config.warehouse = nonEmpty("warehouse", *p);

    if (auto p = "connectTimeout" in params) config.connectTimeout = parseDuration("connectTimeout", *p);
    if (auto p = "timeout" in params)        config.timeout        = parseDuration("timeout", *p);
    if (auto p = "idleLimit" in params)      config.idleLimit      = parseDuration("idleLimit", *p);

    // `tls=true` turns on TLS for any scheme; an `https://` DSN is already
    // secure and `tls=false` cannot talk it back down.
    if (auto p = "tls" in params)
        if (parseBoolean("tls", *p))
            config.secure = true;
}

private string nonEmpty(string name, string value) @safe pure
{
    if (value.length == 0)
        throw new UsageException("the DSN parameter " ~ name ~ " cannot be empty");
    return value;
}

private bool parseBoolean(string name, string value) @safe pure
{
    switch (value.toLower())
    {
        case "true", "1", "yes": return true;
        case "false", "0", "no": return false;
        default:
            throw new UsageException(
                format!"%s must be true or false, got \"%s\""(name, value));
    }
}

/**
 * Reads a duration the way a connection string writes one: a bare number of
 * seconds, or a number with an `ms`/`s`/`m`/`h` suffix.
 *
 * Zero is meaningful — it removes the bound — so it is accepted where a
 * negative number is not.
 */
Duration parseDuration(string name, const(char)[] text) @safe pure
{
    auto trimmed = text.strip();
    if (trimmed.length == 0)
        throw new UsageException(malformedDuration(name, text));

    size_t i;
    while (i < trimmed.length && trimmed[i].isDigit) i++;
    size_t fractionStart = i;
    if (i < trimmed.length && trimmed[i] == '.')
    {
        i++;
        while (i < trimmed.length && trimmed[i].isDigit) i++;
    }
    if (fractionStart == 0)
        throw new UsageException(malformedDuration(name, text));

    const number = trimmed[0 .. i];
    const unit = trimmed[i .. $];

    long factor;
    switch (unit)
    {
        case "ms":     factor = 1; break;
        case "", "s":  factor = 1_000; break;
        case "m":      factor = 60_000; break;
        case "h":      factor = 3_600_000; break;
        default:
            throw new UsageException(malformedDuration(name, text));
    }

    double amount;
    try
        amount = number.to!double;
    catch (ConvException)
        throw new UsageException(malformedDuration(name, text));

    // Rounded rather than truncated, so `0.5s` is 500ms and not 0.
    const millis = cast(long)(amount * factor + 0.5);
    return msecs(millis);
}

private string malformedDuration(string name, const(char)[] text) @safe pure
{
    return format!"%s must be a duration such as 30s, 500ms or 5m, got \"%s\""(name, text);
}

/// Percent-decoding, over bytes: `%C3%A9` is one character in two escapes, so
/// the bytes are rebuilt first and read as UTF-8 afterwards.
private string percentDecode(const(char)[] text) @safe pure
{
    if (!text.canFind('%') && !text.canFind('+'))
        return text.idup;
    auto result = appender!string();
    result.reserve(text.length);
    for (size_t i = 0; i < text.length; i++)
    {
        const c = text[i];
        if (c == '%' && i + 2 < text.length && text[i + 1].isHexDigit && text[i + 2].isHexDigit)
        {
            result.put(cast(char)((hexValue(text[i + 1]) << 4) | hexValue(text[i + 2])));
            i += 2;
        }
        else if (c == '+')
            result.put(' ');
        else
            result.put(c);
    }
    return result.data;
}

private ubyte hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
    if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
    return cast(ubyte)(c - 'A' + 10);
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    // The shape a caller actually writes.
    auto c = parseDsn("frostlake://localhost:18082/MY_DB?schema=PUBLIC");
    assert(c.host == "localhost");
    assert(c.port == 18082);
    assert(!c.secure);
    assert(c.database == "MY_DB");
    assert(c.schema == "PUBLIC");
    assert(c.baseUrl == "http://localhost:18082");
    assert(c.useStatements == [`USE DATABASE "MY_DB"`, `USE SCHEMA "PUBLIC"`]);
}

@safe unittest
{
    // Defaults, and the port each scheme falls back to.
    assert(parseDsn("frostlake://h").port == 18082);
    assert(parseDsn("http://h").port == 80);
    assert(parseDsn("https://h").port == 443);
    assert(parseDsn("https://h").secure);
    assert(parseDsn("http://h:9").port == 9);

    auto c = parseDsn("frostlake://h");
    assert(c.connectTimeout == dur!"seconds"(10));
    assert(c.timeout == dur!"seconds"(300));
    assert(c.idleLimit == dur!"minutes"(20));
    assert(c.database == "" && c.schema == "" && c.role == "" && c.warehouse == "");
    assert(c.useStatements.length == 0);
}

@safe unittest
{
    // Scope, in the dependency order a fresh session needs.
    auto c = parseDsn("frostlake://h/DB?schema=S&role=R&warehouse=W");
    assert(c.useStatements == [
        `USE ROLE "R"`, `USE WAREHOUSE "W"`, `USE DATABASE "DB"`, `USE SCHEMA "S"`
    ]);
}

@safe unittest
{
    // A plain DSN name folds as it does unquoted in SQL; anything else keeps its
    // case. Every name is quoted.
    auto c = parseDsn("frostlake://h/it_scope_db?schema=s");
    assert(c.useStatements == [`USE DATABASE "IT_SCOPE_DB"`, `USE SCHEMA "S"`]);
    assert(useIdentifier("select") == `"SELECT"`);
    assert(useIdentifier("1abc") == `"1abc"`);
    assert(useIdentifier("my db") == `"my db"`);
    assert(useIdentifier(`a"b`) == `"a""b"`);
}

@safe unittest
{
    // Durations, in every spelling a DSN may use.
    assert(parseDsn("frostlake://h?timeout=45").timeout == dur!"seconds"(45));
    assert(parseDsn("frostlake://h?timeout=45s").timeout == dur!"seconds"(45));
    assert(parseDsn("frostlake://h?timeout=500ms").timeout == dur!"msecs"(500));
    assert(parseDsn("frostlake://h?timeout=5m").timeout == dur!"minutes"(5));
    assert(parseDsn("frostlake://h?timeout=2h").timeout == dur!"hours"(2));
    assert(parseDsn("frostlake://h?timeout=0.5s").timeout == dur!"msecs"(500));
    // Zero is not a malformed duration — it removes the bound.
    assert(parseDsn("frostlake://h?timeout=0").timeout == Duration.zero);
}

@safe unittest
{
    // TLS can be asked for without changing the scheme.
    assert(parseDsn("frostlake://h?tls=true").secure);
    assert(parseDsn("frostlake://h?tls=yes").secure);
    assert(!parseDsn("frostlake://h?tls=false").secure);
    // ...but cannot be talked back down on an https DSN.
    assert(parseDsn("https://h?tls=false").secure);
}

@safe unittest
{
    // IPv6 literals, with and without a port.
    auto a = parseDsn("frostlake://[::1]:18082/DB");
    assert(a.host == "::1" && a.port == 18082 && a.database == "DB");
    auto b = parseDsn("frostlake://[2001:db8::1]");
    assert(b.host == "2001:db8::1" && b.port == 18082);
    assert(b.baseUrl == "http://2001:db8::1:18082");
}

@safe unittest
{
    // Percent-encoding, including a multi-byte character split across escapes.
    assert(parseDsn("frostlake://h/my%20db").database == "my db");
    assert(parseDsn("frostlake://h?schema=caf%C3%A9").schema == "café");
    assert(parseDsn("frostlake://h?schema=a+b").schema == "a b");
}

@safe unittest
{
    // A fragment is not part of the path or the query.
    assert(parseDsn("frostlake://h/DB#note").database == "DB");
    assert(parseDsn("frostlake://h/DB?schema=S#note").schema == "S");
}

@safe unittest
{
    import std.exception : assertThrown, collectExceptionMsg;

    assertThrown!UsageException(parseDsn("localhost:18082"));
    assertThrown!UsageException(parseDsn("mysql://h"));
    assertThrown!UsageException(parseDsn("frostlake://"));
    assertThrown!UsageException(parseDsn("frostlake://h:abc"));
    assertThrown!UsageException(parseDsn("frostlake://h:0"));
    assertThrown!UsageException(parseDsn("frostlake://h:70000"));
    assertThrown!UsageException(parseDsn("frostlake://[::1"));
    assertThrown!UsageException(parseDsn("frostlake://h/a/b"));
    assertThrown!UsageException(parseDsn("frostlake://h?schema="));
    assertThrown!UsageException(parseDsn("frostlake://h?tls=maybe"));
    assertThrown!UsageException(parseDsn("frostlake://h?timeout=soon"));
    assertThrown!UsageException(parseDsn("frostlake://h?timeout=-5"));

    // A credential is refused rather than quietly dropped.
    assert(collectExceptionMsg(parseDsn("frostlake://user:pw@h"))
           .canFind("takes no credentials"));

    // A misspelled parameter names itself and lists what was expected.
    const msg = collectExceptionMsg(parseDsn("frostlake://h?shcema=S"));
    assert(msg.canFind("shcema"));
    assert(msg.canFind("schema"));
}

@safe unittest
{
    import std.exception : assertThrown;
    // Identifiers are always quoted, and a quote inside one cannot break out.
    assert(quoteIdentifier("db") == `"db"`);
    assert(quoteIdentifier("MY_DB") == `"MY_DB"`);
    assert(quoteIdentifier(`a"b`) == `"a""b"`);
    assert(quoteIdentifier(`"; DROP TABLE t; --`) == `"""; DROP TABLE t; --"`);
    assertThrown!UsageException(quoteIdentifier(""));

    // ...which means a hostile database name in a DSN stays one identifier.
    auto c = parseDsn(`frostlake://h/a%22b`);
    assert(c.useStatements == [`USE DATABASE "a""b"`]);
}
