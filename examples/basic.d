/**
 * A tour of the driver against a running engine.
 *
 * ---
 * dub run -c example                                  # frostlake://localhost:18082
 * dub run -c example -- frostlake://host:port/DB      # somewhere else
 * ---
 *
 * Start an engine first:
 *
 * ---
 * java -cp 'path/to/frostlake/lib/*' dev.frostlake.http.DatabaseHttpServer 18082
 * ---
 */
module examples.basic;

import std.bigint : BigInt;
import std.datetime.date : Date;
import std.stdio : writefln, writeln;
import std.typecons : Nullable, nullable;

import frostlake;

int main(string[] arguments)
{
    const dsn = arguments.length > 1 ? arguments[1] : "frostlake://localhost:18082";

    Connection conn;
    try
        conn = connect(dsn);
    catch (ConnectionException e)
    {
        writefln("cannot reach %s: %s", dsn, e.msg);
        writeln("start an engine with:");
        writeln("  java -cp 'path/to/frostlake/lib/*' dev.frostlake.http.DatabaseHttpServer 18082");
        return 1;
    }
    scope (exit) conn.close();
    writefln("connected to %s (driver %s)", conn.baseUrl, version_);

    // ---------------------------------------------------------------- setup

    conn.execute("CREATE OR REPLACE DATABASE example_db");
    conn.execute("USE DATABASE example_db");
    conn.execute("CREATE OR REPLACE SCHEMA public");
    conn.execute("USE SCHEMA public");

    // `USE` carried across statements because they share one engine session.
    writefln("session %s is in %s.%s",
             conn.sessionId,
             conn.execute("SELECT CURRENT_DATABASE()").value.asString,
             conn.execute("SELECT CURRENT_SCHEMA()").value.asString);

    // ------------------------------------------------------------ statements

    conn.execute("CREATE TABLE people (id INTEGER, name VARCHAR, joined DATE)");

    auto inserted = conn.execute(
        "INSERT INTO people VALUES (?, ?, ?), (?, ?, ?)",
        1, "Ada", Date(1843, 1, 1),
        2, "Grace", Date(1952, 1, 1));
    writefln("inserted %s row(s)", inserted.updateCount);

    writeln();
    writeln("id  name   joined");
    foreach (row; conn.execute("SELECT id, name, joined FROM people ORDER BY id"))
        writefln("%-3s %-6s %s", row["ID"].asLong, row["NAME"].asString, row["JOINED"].asDate);

    // ------------------------------------------------------- typed binding

    writeln();
    // A D `string` is quoted and a D `int` is a bare numeral, so the driver
    // never has to guess — and a numeric-looking string keeps its zeros.
    conn.execute("CREATE TABLE codes (v VARCHAR)");
    conn.execute("INSERT INTO codes VALUES (?)", "007");
    writefln("a VARCHAR '007' comes back as %s", conn.execute("SELECT v FROM codes").value.asString);
    writefln("...while LIMIT ? takes a real number: %s row(s)",
             conn.execute("SELECT * FROM people LIMIT ?", 1).rowCount);
    writefln("rendered: %s", conn.render("SELECT * FROM people LIMIT ?", 1));

    // Named parameters, when a statement reads better with them.
    writefln("named binds: %s",
             conn.execute("SELECT :a + :b AS total", ["a": 2, "b": 40]).value.asLong);

    // ------------------------------------------------------- exact numbers

    writeln();
    auto wide = conn.execute("SELECT 12345678901234567890123456789012345678 AS n").value;
    writefln("a NUMBER(38,0) keeps every digit: %s", wide.asBigInt);

    // ------------------------------------------------------------- NULL

    auto missing = conn.execute("SELECT NULL AS n").value;
    writefln("NULL is not the empty string: isNull=%s, opt!long=%s",
             missing.isNull, missing.opt!long.isNull ? "none" : "some");

    // -------------------------------------------------------- transactions

    writeln();
    conn.transaction({
        conn.execute("INSERT INTO people VALUES (?, ?, ?)", 3, "Alan", Date(1936, 1, 1));
    });
    writefln("after a committed transaction: %s people",
             conn.execute("SELECT COUNT(*) FROM people").value.asLong);

    try
        conn.transaction({
            conn.execute("INSERT INTO people VALUES (?, ?, ?)", 4, "Nobody", Date(2000, 1, 1));
            throw new Exception("changed my mind");
        });
    catch (Exception e)
        writefln("rolled back after \"%s\": still %s people",
                 e.msg, conn.execute("SELECT COUNT(*) FROM people").value.asLong);

    // ------------------------------------------------------------- errors

    writeln();
    try
        conn.execute("SELECT * FROM no_such_table");
    catch (QueryException e)
        writefln("the engine refused a statement, and the session survived: %s",
                 e.msg.length > 60 ? e.msg[0 .. 60] ~ "..." : e.msg);
    writefln("still usable: %s", conn.execute("SELECT 1").value.asLong);

    conn.execute("DROP DATABASE IF EXISTS example_db");
    return 0;
}
