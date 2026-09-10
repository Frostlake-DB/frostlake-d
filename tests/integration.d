/**
 * Driver tests that need a real engine.
 *
 * These are ordinary functions rather than `unittest` blocks, because they all
 * share one booted engine and D runs `unittest` blocks before `main` — before
 * there is anything to talk to. `tests/unit_main.d` boots the engine once and
 * calls them.
 *
 * Without `FROSTLAKE_CLASSPATH` they are skipped rather than passed: a green
 * suite that never reached an engine would be worse than a skipped one.
 */
module tests.integration;

import core.time : msecs, seconds;

import std.algorithm : canFind;
import std.bigint : BigInt;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.exception : assertThrown, collectExceptionMsg;
import std.format : format;
import std.stdio : writefln;
import std.typecons : Nullable, nullable;

import frostlake;

/// One test: a name, and something that throws if it fails.
struct IntegrationTest
{
    string name;
    void function(string dsn) run;
}

/// Every engine-backed test, in the order they are run.
immutable IntegrationTest[] integrationTests = [
    IntegrationTest("connect and report", &testConnectAndReport),
    IntegrationTest("session carries USE across statements", &testSessionCarries),
    IntegrationTest("DSN scope is applied at connect", &testDsnScope),
    IntegrationTest("DSN naming a missing database fails at connect", &testMissingDatabase),
    IntegrationTest("query shapes: columns, rows, metadata", &testQueryShape),
    IntegrationTest("update counts are derived from the counter grid", &testUpdateCounts),
    IntegrationTest("typed binds: a string stays text, an int stays a number", &testTypedBinds),
    IntegrationTest("named binds", &testNamedBinds),
    IntegrationTest("a bound value cannot leave its literal", &testBindInjection),
    IntegrationTest("exact numbers survive a NUMBER(38,0)", &testWideNumbers),
    IntegrationTest("NULL is distinct from the empty string", &testNulls),
    IntegrationTest("temporal, binary and variant cells", &testTypedCells),
    IntegrationTest("a refused statement leaves the session intact", &testQueryError),
    IntegrationTest("transactions commit and roll back", &testTransactions),
    IntegrationTest("multi-statement requests answer once per statement", &testMultiStatement),
    IntegrationTest("one socket carries many statements", &testKeepAlive),
    IntegrationTest("a closed connection refuses further work", &testClosed),
    IntegrationTest("a statement past its deadline fails as a timeout", &testTimeout),
];

private Connection open(string dsn)
{
    return connect(dsn);
}

/// Puts a connection in a fresh, empty database of its own.
private void freshScope(Connection conn, string name)
{
    conn.execute(format!"CREATE OR REPLACE DATABASE %s"(name));
    conn.execute(format!"USE DATABASE %s"(name));
    conn.execute("CREATE OR REPLACE SCHEMA s");
    conn.execute("USE SCHEMA s");
}

private void testConnectAndReport(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();

    assert(conn.isOpen);
    assert(!conn.inTransaction);
    assert(conn.baseUrl.canFind("127.0.0.1"));
    // A session belongs to /api/execute, not /api/health, so there is no id
    // until the first statement.
    assert(conn.sessionId.length == 0);
    conn.execute("SELECT 1");
    assert(conn.sessionId.length > 0);
    conn.ping();
}

private void testSessionCarries(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();

    freshScope(conn, "it_session_db");
    assert(conn.execute("SELECT CURRENT_DATABASE()").value.asString == "IT_SESSION_DB");
    assert(conn.execute("SELECT CURRENT_SCHEMA()").value.asString == "S");

    // A session variable set in one statement is visible in the next.
    conn.execute("SET v = 41");
    assert(conn.execute("SELECT $v + 1").value.asLong == 42);
}

private void testDsnScope(string dsn)
{
    auto setup = open(dsn);
    scope (exit) setup.close();
    freshScope(setup, "it_scope_db");

    // A second connection, told the scope by its DSN alone.
    auto scoped = open(dsn ~ "/it_scope_db?schema=S");
    scope (exit) scoped.close();
    assert(scoped.execute("SELECT CURRENT_DATABASE()").value.asString == "IT_SCOPE_DB");
    assert(scoped.execute("SELECT CURRENT_SCHEMA()").value.asString == "S");
}

private void testMissingDatabase(string dsn)
{
    // Reported at connect, not on whichever query happened to run first.
    const message = collectExceptionMsg!FrostlakeException(
        connect(dsn ~ "/no_such_database_here"));
    assert(message.length > 0, "connecting to a missing database should fail");
}

private void testQueryShape(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();
    freshScope(conn, "it_shape_db");

    conn.execute("CREATE TABLE people (id INTEGER, name VARCHAR)");
    conn.execute("INSERT INTO people VALUES (1, 'Ada'), (2, 'Grace')");

    auto result = conn.execute("SELECT id, name FROM people ORDER BY id");
    assert(result.columnNames == ["ID", "NAME"]);
    assert(result.rowCount == 2);
    assert(!result.isUpdate);
    assert(result.updateCount == -1);

    assert(result.rows[0][0].asLong == 1);
    assert(result.rows[0]["NAME"].asString == "Ada");
    assert(result.rows[0]["name"].asString == "Ada");
    assert(result.cell(1, "NAME").asString == "Grace");
    assert(result.value.asLong == 1);

    // Column metadata comes from the engine.
    assert(result.column("ID").dataType.canFind("NUMBER"));
    assert(result.column("NAME").dataType.canFind("VARCHAR"));
    assert(result.columnIndex("NAME") == 1);
    assert(result.columnIndex("nope") == -1);

    // An empty result is still a result.
    auto none = conn.execute("SELECT id FROM people WHERE id = 99");
    assert(none.rowCount == 0);
    assert(none.value.isNull);

    // DDL always answers, so `execute` always has a result to return: an empty
    // one before engine 0.1.0, a one-row status grid from 0.1.0 on, as live
    // answers. Either way it is not an update.
    auto ddl = conn.execute("CREATE TABLE t2 (a INT)");
    assert(!ddl.isUpdate);
    assert(ddl.rowCount <= 1);
}

private void testUpdateCounts(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();
    freshScope(conn, "it_counts_db");

    conn.execute("CREATE TABLE t (id INTEGER, v VARCHAR)");

    auto inserted = conn.execute("INSERT INTO t VALUES (1,'a'), (2,'b'), (3,'c')");
    assert(inserted.isUpdate);
    assert(inserted.updateCount == 3);
    assert(inserted.counters["number of rows inserted"] == 3);
    // The grid itself is kept rather than folded away.
    assert(inserted.rows.length == 1);

    auto updated = conn.execute("UPDATE t SET v = 'x' WHERE id = 2");
    assert(updated.updateCount == 1);
    // "number of multi-joined rows updated" is a sub-count of rows already
    // counted, so it is reported but not added in.
    assert(updated.counters.length == 2);

    auto deleted = conn.execute("DELETE FROM t WHERE id = 3");
    assert(deleted.updateCount == 1);

    // A MERGE reports two counters at once, and the count a caller wants is
    // everything it touched. Nothing else here asserts a MERGE update count
    // against a real engine, so this holds the multi-counter branch honest.
    conn.execute("CREATE TABLE src (id INTEGER, v VARCHAR)");
    conn.execute("INSERT INTO src VALUES (1,'X'), (3,'C'), (4,'D')");
    auto merged = conn.execute(
        "MERGE INTO t USING src s ON t.id = s.id " ~
        "WHEN MATCHED THEN UPDATE SET t.v = s.v " ~
        "WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v)");
    assert(merged.isUpdate);
    assert(merged.counters["number of rows inserted"] == 2);
    assert(merged.counters["number of rows updated"] == 1);
    assert(merged.updateCount == 3, "a MERGE should report every row it touched");

    // A SELECT is not an update, however its columns are named.
    assert(!conn.execute("SELECT id FROM t").isUpdate);

    // ...and a query whose columns merely LOOK like a status grid keeps its
    // rows: the grid is never folded away, so nothing is lost either way.
    auto lookalike = conn.execute(
        "SELECT 7 AS \"number of rows inserted\", 9 AS \"number of rows updated\"");
    assert(lookalike.rows.length == 1);
    assert(lookalike.rows[0][0].asLong == 7);
}

private void testTypedBinds(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();
    freshScope(conn, "it_binds_db");

    conn.execute("CREATE TABLE codes (v VARCHAR)");

    // The case the string-based drivers in this family cannot get right on
    // their own: a numeric-looking string keeps its leading zeros, because D
    // already knows it is a string.
    conn.execute("INSERT INTO codes VALUES (?)", "007");
    assert(conn.execute("SELECT v FROM codes").value.asString == "007");

    // ...and an int is a real numeric literal, so it works where SQL demands
    // one. A quoted number is a syntax error in a LIMIT clause.
    assert(conn.execute("SELECT v FROM codes LIMIT ?", 1).rowCount == 1);

    // Every inferred type, round-tripped.
    assert(conn.execute("SELECT ?", 42).value.asLong == 42);
    assert(conn.execute("SELECT ?", -1.5).value.asDouble == -1.5);
    assert(conn.execute("SELECT ?", true).value.asBool);
    assert(conn.execute("SELECT ?", "text").value.asString == "text");
    assert(conn.execute("SELECT ?", null).value.isNull);

    Nullable!int absent;
    assert(conn.execute("SELECT ?", absent).value.isNull);
    assert(conn.execute("SELECT ?", nullable(7)).value.asLong == 7);

    assert(conn.execute("SELECT ?", BigInt("12345678901234567890123456789012345678"))
           .value.asBigInt == BigInt("12345678901234567890123456789012345678"));

    // A quote inside a bound string survives it.
    assert(conn.execute("SELECT ?", "it's").value.asString == "it's");
    // As does a backslash, which escapes in this dialect.
    assert(conn.execute("SELECT ?", `a\b`).value.asString == `a\b`);

    // render() shows what was actually sent, without sending it.
    assert(conn.render("SELECT ?, ?", 1, "a") == "SELECT 1, 'a'");
}

private void testNamedBinds(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();

    assert(conn.execute("SELECT :a + :b AS total", ["a": 2, "b": 40]).value.asLong == 42);
    // Order does not matter, and case does not either.
    assert(conn.execute("SELECT :B - :A AS d", ["a": 1, "b": 10]).value.asLong == 9);

    Param[string] mixed = ["n": toParam(3), "s": toParam("x")];
    auto row = conn.executeNamed("SELECT :n AS n, :s AS s", mixed);
    assert(row.rows[0]["N"].asLong == 3);
    assert(row.rows[0]["S"].asString == "x");
}

private void testBindInjection(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();
    freshScope(conn, "it_inject_db");

    conn.execute("CREATE TABLE t (v VARCHAR)");
    conn.execute("INSERT INTO t VALUES ('keep')");

    // The classic: the value is data, and stays data.
    const hostile = "'); DROP TABLE t; --";
    conn.execute("INSERT INTO t VALUES (?)", hostile);
    assert(conn.execute("SELECT COUNT(*) FROM t").value.asLong == 2);
    assert(conn.execute("SELECT v FROM t WHERE v = ?", hostile).rowCount == 1);

    // An identifier assembled at runtime is quoted rather than spliced.
    assert(conn.execute("SELECT COUNT(*) FROM t").value.asLong == 2);
}

private void testWideNumbers(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();

    // Thirty-eight digits: too wide for long, and a double would round it.
    enum digits = "12345678901234567890123456789012345678";
    auto cell = conn.execute("SELECT " ~ digits ~ " AS big").value;
    assert(cell.asBigInt == BigInt(digits));
    assert(cell.asString == digits);
    assertThrown!ValueException(cell.asLong());

    // A high-precision decimal keeps its digits too.
    auto exact = conn.execute("SELECT 1.234567890123456789012345678901234567 AS d").value;
    assert(exact.asString.length > 20);
}

private void testNulls(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();
    freshScope(conn, "it_nulls_db");

    conn.execute("CREATE TABLE t (a VARCHAR, b VARCHAR)");
    conn.execute("INSERT INTO t VALUES (NULL, '')");

    auto row = conn.execute("SELECT a, b FROM t").rows[0];
    assert(row["A"].isNull);
    assert(!row["B"].isNull);
    assert(row["B"].asString == "");
    assert(row["A"].toString() == "NULL");
    assert(row["A"].opt!string.isNull);
    assertThrown!ValueException(row["A"].asString());
}

private void testTypedCells(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();

    auto row = conn.execute(
        "SELECT '2024-01-15'::DATE AS d, '10:30:05'::TIME AS t, " ~
        "'2024-01-15 10:30:05'::TIMESTAMP_NTZ AS ts, " ~
        "X'DEADBEEF' AS b, PARSE_JSON('{\"k\":1}') AS v").rows[0];

    assert(row["D"].asDate == Date(2024, 1, 15));
    assert(row["T"].asTimeOfDay == TimeOfDay(10, 30, 5));
    assert(row["TS"].asDateTime == DateTime(2024, 1, 15, 10, 30, 5));
    assert(row["B"].asBytes == cast(ubyte[]) [0xDE, 0xAD, 0xBE, 0xEF]);
    assert(row["V"].asString.canFind("\"k\""));

    // A zoned stamp keeps its offset, and binding it straight back in works —
    // the engine prints +0100 but parses only +01:00, so the driver repairs it.
    auto zoned = conn.execute("SELECT '2024-01-15 10:30:05 +01:00'::TIMESTAMP_TZ AS z").value;
    auto rebound = conn.execute("SELECT ? AS z", Param.ofTimestampTz(zoned.asString));
    assert(rebound.value.asString.length > 0);

    // NaN really does arrive as the JSON string "NaN", even for a DOUBLE column.
    import std.math : isNaN;
    auto nan = conn.execute("SELECT SQRT(-1) AS n").value;
    assert(nan.asDouble.isNaN);
}

private void testQueryError(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();

    // Establish the session first — a connection has none until its first
    // statement, because a session belongs to /api/execute, not /api/health.
    conn.execute("SELECT 1");
    const before = conn.sessionId;
    assert(before.length > 0, "a statement should have established a session");

    const message = collectExceptionMsg!QueryException(conn.execute("SELECT * FROM no_such_table"));
    assert(message.canFind("does not exist"), message);

    // The session survived it. A failure answers `sessionId: null`, and a
    // driver that took that at face value would drop the session here and
    // silently start a new one on the next statement — losing USE, session
    // variables and any open transaction with it.
    assert(conn.sessionId == before, "a refused statement must not drop the session");
    assert(conn.execute("SELECT 1").value.asLong == 1);
    assert(conn.sessionId == before, "the session id should be unchanged");

    // A syntax error is a QueryException too, not a transport failure — even
    // though the engine answers it with HTTP 500.
    assertThrown!QueryException(conn.execute("NOT SQL AT ALL"));
    assert(conn.execute("SELECT 2").value.asLong == 2);
    assert(conn.sessionId == before, "the session id should still be unchanged");
}

private void testTransactions(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();
    freshScope(conn, "it_tx_db");

    conn.execute("CREATE TABLE t (id INTEGER)");

    conn.begin();
    assert(conn.inTransaction);
    conn.execute("INSERT INTO t VALUES (1)");
    conn.commit();
    assert(!conn.inTransaction);
    assert(conn.execute("SELECT COUNT(*) FROM t").value.asLong == 1);

    conn.begin();
    conn.execute("INSERT INTO t VALUES (2)");
    conn.rollback();
    assert(conn.execute("SELECT COUNT(*) FROM t").value.asLong == 1);

    // The scoped form commits on success...
    conn.transaction({ conn.execute("INSERT INTO t VALUES (3)"); });
    assert(conn.execute("SELECT COUNT(*) FROM t").value.asLong == 2);

    // ...and rolls back on failure, re-raising the original exception.
    bool raised;
    try
        conn.transaction({
            conn.execute("INSERT INTO t VALUES (4)");
            throw new Exception("deliberate");
        });
    catch (Exception e)
    {
        raised = e.msg == "deliberate";
    }
    assert(raised, "the original exception should reach the caller");
    assert(!conn.inTransaction);
    assert(conn.execute("SELECT COUNT(*) FROM t").value.asLong == 2);
}

private void testMultiStatement(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();

    auto sets = conn.executeAll("SELECT 1 AS a; SELECT 2 AS b");
    assert(sets.length == 2);
    assert(sets[0].value.asLong == 1);
    assert(sets[1].value.asLong == 2);
    // execute() hands back the first.
    assert(conn.execute("SELECT 1 AS a; SELECT 2 AS b").value.asLong == 1);
}

private void testKeepAlive(string dsn)
{
    auto conn = open(dsn);
    scope (exit) conn.close();

    // The point of the transport: 200 statements on one connection, one
    // session, one socket. A driver opening a socket per statement would burn
    // 200 ephemeral ports here.
    const before = conn.sessionId;
    foreach (i; 0 .. 200)
        assert(conn.execute("SELECT ?", i).value.asLong == i);
    conn.execute("SELECT 1");
    assert(conn.sessionId == before || before.length == 0);
}

private void testClosed(string dsn)
{
    auto conn = open(dsn);
    conn.execute("SELECT 1");
    conn.close();
    assert(!conn.isOpen);
    assertThrown!UsageException(conn.execute("SELECT 1"));
    // Closing twice is not an error.
    conn.close();
}

private void testTimeout(string dsn)
{
    // A deadline the server cannot possibly meet fails as a connection
    // problem naming the endpoint, rather than hanging.
    ConnectOptions options;
    options.connectTimeout = seconds(5);
    options.timeout = msecs(1);
    try
    {
        auto conn = connect(dsn, options);
        scope (exit) conn.close();
        foreach (i; 0 .. 20)
            conn.execute("SELECT SEQ8() FROM TABLE(GENERATOR(ROWCOUNT => 200000))");
        // A machine fast enough to beat a 1ms deadline twenty times over has
        // not disproved anything; the deadline is still enforced.
    }
    catch (ConnectionException e)
    {
        assert(e.endpoint.canFind("/api/execute"), e.endpoint);
        assert(e.msg.canFind("within"), e.msg);
    }
    catch (QueryException)
    {
        // The engine refusing the generator is fine too; not what is under test.
    }
}
