/**
 * A Frostlake driver for D, with no dependencies outside Phobos.
 *
 * $(H2 Getting started)
 *
 * ---
 * import frostlake;
 * import std.stdio;
 *
 * auto conn = connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC");
 * scope (exit) conn.close();
 *
 * conn.execute("CREATE OR REPLACE TABLE people (id INTEGER, name VARCHAR)");
 * conn.execute("INSERT INTO people VALUES (?, ?), (?, ?)", 1, "Ada", 2, "Grace");
 *
 * foreach (row; conn.execute("SELECT id, name FROM people ORDER BY id"))
 *     writefln("%s: %s", row["ID"].asLong, row["NAME"].asString);
 * ---
 *
 * $(H2 What the driver does and does not do for you)
 *
 * $(UL
 * $(LI $(B Binds are typed by D's own types.) `?` and `:name` placeholders are
 *      inlined here, because the HTTP protocol has no server-side binding — but
 *      unlike the string-based drivers in this family, this one does not have to
 *      guess. A `string` is quoted, an `int` is a bare numeral, a
 *      `Nullable!T` that is empty is `NULL`. See $(MREF frostlake, value).)
 * $(LI $(B Cells keep the engine's own text.) Nothing is converted on the way
 *      back: `asLong`, `asBigInt`, `asDate` and their kin are calls you make,
 *      so a `NUMBER(38,0)` is never rounded behind your back. See
 *      $(MREF frostlake, result).)
 * $(LI $(B One socket per connection.) Statements share one keep-alive socket,
 *      so a long run does not exhaust the machine's ephemeral ports. See
 *      $(MREF frostlake, http).)
 * $(LI $(B Sessions are real.) `USE`, session variables and open transactions
 *      carry from one statement to the next, because every statement rides the
 *      same engine session.)
 * )
 *
 * $(H2 Errors)
 *
 * Everything thrown derives from $(D FrostlakeException):
 * $(D UsageException) for a caller mistake (nothing was sent),
 * $(D ConnectionException) for the wire (the statement's fate is unknown),
 * $(D QueryException) for a statement the engine refused (the session is
 * intact), and $(D ValueException) for a cell read as a type it does not hold.
 *
 * $(H2 TLS)
 *
 * Phobos ships no TLS, so an `https://` DSN is refused with an explanation
 * rather than quietly sent in the clear. Put a terminating proxy in front of
 * the engine and point the DSN at that.
 *
 * License: Apache-2.0
 */
module frostlake;

public import frostlake.connection : connect, Connection, ConnectOptions;
public import frostlake.dsn : DsnConfig, parseDsn, quoteIdentifier, defaultPort;
public import frostlake.errors : ConnectionException, FrostlakeException,
                                 QueryException, UsageException, ValueException;
public import frostlake.http : driverVersion;
public import frostlake.result : Column, Result, Row, Value, ValueKind;
public import frostlake.value : baseType, isBinaryType, isVariantType, Param,
                                Temporal, temporalKind, toParam;

/// The library's version, as reported in the `User-Agent` header.
enum string version_ = driverVersion;

@safe unittest
{
    // The public surface is reachable through the one import.
    static assert(is(typeof(&connect)));
    static assert(is(Connection));
    static assert(is(Result));
    static assert(is(Value));
    static assert(is(Param));
    assert(version_.length > 0);
    assert(defaultPort == 18082);
    assert(quoteIdentifier("a") == `"a"`);
    assert(toParam(1).literal == "1");
}
