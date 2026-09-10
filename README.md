# frostlake-d

A D driver for [Frostlake](https://frostlake.dev)'s HTTP protocol, with no dependencies
outside Phobos.

Tested against engine 0.0.7 on Windows and Linux, with DMD 2.100, 2.112 and 2.113 and LDC 1.40.

```d
import frostlake;
import std.stdio;

// A fresh engine has no MY_DB, and a DSN naming a missing database fails at
// connect, so create it first.
auto admin = connect("frostlake://localhost:18082");
admin.execute("CREATE DATABASE IF NOT EXISTS MY_DB");
admin.close();

auto conn = connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC");
scope (exit) conn.close();

conn.execute("CREATE OR REPLACE TABLE people (id INTEGER, name VARCHAR)");
conn.execute("INSERT INTO people VALUES (?, ?), (?, ?)", 1, "Ada", 2, "Grace");

foreach (row; conn.execute("SELECT id, name FROM people ORDER BY id"))
    writefln("%s: %s", row["ID"].asLong, row["NAME"].asString);
```

## Install

Add it to your `dub.json`:

```json
"dependencies": { "frostlake": "~>0.1.0" }
```

Or point dub at a local checkout:

```bash
dub add-local /path/to/frostlake-d
```

Needs DMD 2.100+ or a matching LDC. Nothing else — no libcurl, no JSON package, no HTTP client.

## Binds are typed by D's own types

Most drivers in this family are written in languages where `42` and `"42"` are the same value, so
they must render every bind as a *string literal* unless told otherwise. That default is forced on
them: the engine reads `007` as the number seven, so inferring "this looks numeric" would silently
turn a VARCHAR `007` into `7`.

D already knows the difference, so this driver does not have to guess:

```d
conn.execute("INSERT INTO codes VALUES (?)", "007");   // VALUES('007') — text, zeros kept
conn.execute("SELECT * FROM people LIMIT ?", 5);       // LIMIT 5       — a real numeral
```

Both work, and neither needs an annotation. A quoted number is a syntax error in a `LIMIT` clause
and a bare `007` is data loss in a VARCHAR — D's type system tells the two apart for you.

| you pass | the statement gets |
| --- | --- |
| `null` | `NULL` |
| `bool` | `TRUE` / `FALSE` |
| any integer, `BigInt` | a bare numeral, in parentheses when negative |
| `float`, `double`, `real` | a numeric literal; NaN and the infinities in the form the engine parses |
| any string | a quoted string literal, quotes and backslashes escaped |
| `ubyte[]` | `X'...'` |
| `Date`, `TimeOfDay`, `DateTime`, `SysTime` | the matching temporal literal |
| `Nullable!T` | `NULL` when empty, otherwise `T`'s rendering |
| `Param` | itself — an explicit choice is never second-guessed |

For the cases inference cannot reach there are explicit constructors — `Param.ofVariant` for
semi-structured JSON, `Param.identifier` for a table name assembled at runtime, and `Param.raw`
for SQL inserted verbatim (the one bind that can carry an injection, and the reason the others
cannot).

Named parameters work too, and a homogeneous set reads nicely as an associative array:

```d
conn.execute("SELECT :a + :b AS total", ["a": 2, "b": 40]);

Param[string] mixed = ["n": toParam(3), "s": toParam("x")];
conn.executeNamed("SELECT :n AS n, :s AS s", mixed);
```

`conn.render(sql, args)` shows exactly what would be sent, without sending it.

## Cells keep the engine's own text

Nothing is converted on the way back. The engine renders temporals, binary and semi-structured
values as text and numbers as bare JSON numbers, so every reading is a call you make:

```d
auto cell = conn.execute("SELECT 12345678901234567890123456789012345678").value;
cell.asBigInt;    // exact — 38 digits fit in neither long nor double
cell.asString;    // the digits as sent
cell.asLong;      // throws ValueException rather than truncating
```

`asBool`, `asLong`, `asDouble`, `asBigInt`, `asBytes`, `asDate` and `asTimeOfDay` each either answer
exactly or throw. The timestamp readings are bounded by D's types: `asDateTime` gives the date and
wall-clock time and leaves out any fraction of a second and any offset, which a `DateTime` cannot
hold; `asSysTime` keeps the offset, and the fraction to the 100 ns a `SysTime` resolves. `opt!T`
gives a `Nullable!T` instead, and `isNull` is the only thing that reports SQL NULL — an empty
string never stands in for it.

This is also why the JSON reader is written here rather than taken from `std.json`: `std.json`
turns every number into a `long` or a `double` while parsing, which would round a `NUMBER(38,0)`
before any driver code could see it.

## Sessions and transactions

A connection carries one engine session, so `USE`, session variables and open transactions carry
from one statement to the next:

```d
conn.execute("USE DATABASE analytics");
conn.execute("SET threshold = 100");
conn.execute("SELECT * FROM events WHERE score > $threshold");   // both still in force
```

```d
conn.transaction({
    conn.execute("INSERT INTO ledger VALUES (?)", 1);
});   // commits, or rolls back and re-raises
```

`begin`, `commit` and `rollback` are there for when the scoped form does not fit.

## Errors

Everything thrown derives from `FrostlakeException`:

| type | meaning | what to do |
| --- | --- | --- |
| `UsageException` | the call was wrong — bad DSN, bind count mismatch, closed connection | nothing was sent; fix the code |
| `ConnectionException` | the wire | the statement's fate is **unknown** — it may have run |
| `QueryException` | the engine refused the statement | the connection and its session are intact |
| `ValueException` | a cell read as a type it does not hold | ask for a different reading |

The driver never retries a statement itself. If an exchange breaks part way through, the socket is
dropped and the failure reported — because a statement that may already have run must not silently
run twice.

Note that a refused statement arrives as HTTP 500 carrying the ordinary JSON envelope, so a
`QueryException` is what you get, not a `ConnectionException`.

## One socket per connection

Statements share one keep-alive socket for the connection's whole life. `connectTimeout` bounds
each attempt to open it, and `timeout` bounds a whole exchange — write, status line, headers and
body — rather than any single read.

This matters more than it sounds. A driver that opens a socket per statement burns an ephemeral
TCP port per statement; a run of a few thousand statements empties the machine's dynamic port
range (49152–65535 on Windows), closed sockets sit in `TIME_WAIT` for minutes, and the failures
then land on whatever runs *next*. This driver spends one socket per connection instead.

## TLS

Phobos ships no TLS, so an `https://` DSN is refused with an explanation rather than quietly sent
in the clear. Put a TLS-terminating proxy in front of the engine and point the DSN at that.

## DSN

```
frostlake://host[:port][/DATABASE][?param=value&...]
```

`http://` is accepted too; the custom scheme exists so a DSN reads as a database URL rather than a
web one. The default port is 18082 for `frostlake://` and 80 for `http://`. An `https://` DSN is
refused (see TLS).

| parameter | meaning |
| --- | --- |
| `schema`, `role`, `warehouse` | the rest of the session's scope, selected at connect |
| `timeout` | how long one statement may take (default `300s`) |
| `connectTimeout` | how long to wait for the socket (default `10s`) |
| `idleLimit` | how long a connection may idle before its scope is re-applied (default `20m`) |
| `tls` | accepted for compatibility with the other drivers; `true` is refused at connect, as `https://` is |

Durations are written `30s`, `500ms`, `5m`, `2h`, or a bare number of seconds; `0` removes the
bound. Anything set in `ConnectOptions` outranks the DSN. Where the Frostlake drivers share a
parameter they spell it the same, and any parameter this driver does not know is refused as a typo.

The scope is applied *before* the constructor returns, so a DSN naming a database that does not
exist fails at `connect` rather than on whichever query happens to run first.

## Testing

```bash
dub test                                            # every unittest block; needs nothing
FROSTLAKE_CLASSPATH='.../lib/*' dub run -c integration   # transport + a real engine
dub run -c example -- frostlake://localhost:18082        # the guided tour
```

Two layers, and each tests something the other cannot:

- **`dub test`** — the pure logic, in `unittest` blocks next to the code: the JSON reader, the DSN
  parser, the SQL scanner, binding, literal rendering, cell readings. No server involved.
- **`dub run -c integration`** — a scripted server for the answers a healthy engine will never
  give (a chunked body, a header in the wrong case, a proxy's HTML error page, a `Connection:
  close`, a response cut off mid-body), then 18 tests against a real engine it boots itself.

`FROSTLAKE_CLASSPATH` is the engine's Java classpath — the `frostlake-db` jar and its
dependencies — and the tests start `java` from `JAVA_HOME` or the `PATH`. The engine is booted
with a per-run home and data directory, so a run never inherits the last one's account-level
objects. Without `FROSTLAKE_CLASSPATH` the engine-backed tests report themselves as skipped
rather than passing against nothing.

`sh build.sh` compiles and runs the unit tests without dub, for a faster edit loop; point `DMD` at
your compiler first.

### If dub fails with "cannot create directory"

DMD on Windows cannot create directories whose path contains non-ASCII characters, and dub caches
builds under your user profile. If your Windows user name has one, point dub's cache somewhere
plain:

```bash
export DUB_HOME=C:/dub-home
```

## Layout

| file | what is in it |
| --- | --- |
| `source/frostlake/package.d` | the public API, and the one import a user needs |
| `source/frostlake/connection.d` | `Connection` — the session, statements, transactions |
| `source/frostlake/http.d` | the keep-alive HTTP/1.1 client, on raw sockets |
| `source/frostlake/json.d` | the JSON reader that keeps a number's digits |
| `source/frostlake/dsn.d` | the connection string |
| `source/frostlake/sql.d` | the scanner shared by binding and scope tracking |
| `source/frostlake/bind.d` | finding `?` and `:name`, and replacing them |
| `source/frostlake/value.d` | D values rendered as SQL literals |
| `source/frostlake/result.d` | `Result`, `Row`, `Column`, `Value` |
| `source/frostlake/errors.d` | the four exception types |

## License

Apache-2.0.
