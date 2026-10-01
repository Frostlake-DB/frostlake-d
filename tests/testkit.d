/**
 * Runs the engine-owned, language-neutral JSON test suites through THIS driver.
 *
 * The definitions live in the frostlake repo
 * (`engine/src/test/resources/testkit/suites/*.json`, spec in `SCHEMA.md` next
 * to them); every statement travels connect → HTTP → `DatabaseHttpServer`. The
 * engine owns the definitions and this file is only the D driver's runner, so
 * suites added on the engine side are picked up here with no driver change.
 *
 * Semantics (mirrors SCHEMA.md and the Tcl, Go, Ruby, dotnet, Julia and Dart
 * runners):
 *
 * $(UL
 * $(LI backend name for a suite's skip clause: `d`; `http` entries are honoured
 *      too, because this driver rides the HTTP transport and the same engine.)
 * $(LI per-test isolation: `CREATE OR REPLACE DATABASE test_db` → `USE` →
 *      `CREATE OR REPLACE SCHEMA test_schema` → `USE`, then the steps, in order,
 *      on ONE connection — which is what keeps `USE`, variables and transactions
 *      on a single session.)
 * $(LI capabilities: SESSION, COLUMN_NAMES, UPDATE_COUNT. No ERROR_CODE — the
 *      HTTP protocol carries a message only, so expected-error code/sqlState
 *      checks are recorded as missing-API notes instead of failing.)
 * $(LI suite files run in name order, because the corpus is order-sensitive by
 *      design: account-level objects outlive the per-test reset, so a suite
 *      whose fixture does a bare `CREATE WAREHOUSE` has to run before the ones
 *      that create the same name with `IF NOT EXISTS`.)
 * )
 *
 * Environment:
 * $(UL
 * $(LI `FL_CORPUS` — the testkit directory to replay, frostlake's
 *      `engine/src/test/resources/testkit`, its suites in `suites/*.json`.
 *      Without it the corpus is not replayed.)
 * $(LI `FROSTLAKE_TESTKIT_FILTER` — run only the suites whose file name
 *      contains this.)
 * $(LI `FROSTLAKE_TESTKIT_SESSION` — how much of the corpus one engine session
 *      spans: `suite` (the default, one connection per file), `test` (one per
 *      case, the strictest isolation) or `run` (one for the whole corpus, which
 *      is the harshest on session leaks and the kindest to the machine's TCP
 *      ports).)
 * )
 */
module tests.testkit;

import core.time : MonoTime, msecs;

import std.algorithm : canFind, sort;
import std.array : appender, join, replace;
import std.conv : ConvException, to;
import std.file : dirEntries, exists, isDir, mkdirRecurse, readText, SpanMode, write;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.process : environment;
import std.stdio : stdout, writef, writefln, writeln;
import std.string : indexOf, strip, toLower, toUpper;

import frostlake;
import frostlake.json : JsonValue, parseJson;

import tests.engine;

/// The name a suite's `skip.backends` uses for this driver.
private enum backendName = "d";

/// How the corpus went.
struct KitReport
{
    size_t passed;
    size_t failed;
    size_t skipped;
    size_t suites;
    /// Capability gaps met along the way, one line each, deduplicated.
    string[] notes;
    /// Set when the engine stopped answering; everything after that point would
    /// fail for the same reason.
    string aborted;

    bool ok() const @safe pure nothrow @nogc { return failed == 0 && aborted.length == 0; }
}

private struct StepOutcome
{
    string[] columns;
    Value[][] rows;
    long updateCount = -1;
    string error;
    /// Whether the transport broke, as opposed to the engine refusing.
    bool broken;
}

private struct Runner
{
    string dsn;
    string sessionMode = "suite";
    Connection shared_;
    KitReport report;
    string[] records;

    // --------------------------------------------------------- connections

    Connection newConnection()
    {
        auto conn = connect(dsn);
        // A session runs one statement per request until it asks for more, so a
        // case whose step sends several would be refused on the count rather
        // than answered; 0 means any number of them.
        conn.execute("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0");
        return conn;
    }

    /// The connection a case runs on, per the session mode.
    Connection acquire()
    {
        if (sessionMode == "test") return newConnection();
        if (shared_ is null) shared_ = newConnection();
        return shared_;
    }

    void releaseCase(Connection conn)
    {
        if (sessionMode == "test") conn.close();
    }

    void releaseSuite()
    {
        if (sessionMode != "run" && shared_ !is null)
        {
            shared_.close();
            shared_ = null;
        }
    }

    void releaseAll()
    {
        if (shared_ !is null)
        {
            shared_.close();
            shared_ = null;
        }
    }

    /// Whether an engine is still answering at all. Asked only after a
    /// transport failure, to tell "this one statement broke the connection"
    /// apart from "the engine is gone".
    bool engineAlive()
    {
        try
        {
            auto conn = newConnection();
            conn.close();
            return true;
        }
        catch (Exception)
            return false;
    }

    // ------------------------------------------------------------- one step

    StepOutcome runStep(Connection conn, string sql)
    {
        StepOutcome outcome;
        try
        {
            auto result = conn.execute(sql);
            outcome.columns = result.columnNames;
            auto semi = appender!(bool[]);
            foreach (column; result.columns)
                semi.put(isSemiStructured(column.dataType));
            const flags = semi.data;
            auto rows = appender!(Value[][]);
            foreach (row; result.rows)
            {
                auto cells = row.cells.dup;
                foreach (i, ref cell; cells)
                    if (i < flags.length && flags[i])
                        cell = semiStructuredValue(cell);
                rows.put(cells);
            }
            outcome.rows = rows.data;
            outcome.updateCount = result.updateCount;
        }
        catch (ConnectionException e)
        {
            outcome.error = e.msg;
            outcome.broken = true;
        }
        catch (FrostlakeException e)
        {
            // A refused statement, or one this driver would not send.
            outcome.error = e.msg;
        }
        return outcome;
    }

    /// The reset sequence SCHEMA.md prescribes: every case starts in an empty
    /// `test_db.test_schema`.
    private string resetContext(Connection conn, out bool broken)
    {
        static immutable string[] sequence = [
            "CREATE OR REPLACE DATABASE test_db",
            "USE DATABASE test_db",
            "CREATE OR REPLACE SCHEMA test_schema",
            "USE SCHEMA test_schema",
        ];
        foreach (sql; sequence)
        {
            auto outcome = runStep(conn, sql);
            if (outcome.error.length)
            {
                broken = outcome.broken;
                return format!"resetContext failed on \"%s\": %s"(sql, outcome.error);
            }
        }
        return "";
    }

    // ------------------------------------------------------------ one case

    /// Runs one case. An empty problem means it passed.
    private string runCase(JsonValue entry, out bool broken)
    {
        auto conn = acquire();
        scope (exit) releaseCase(conn);

        auto problem = resetContext(conn, broken);
        if (problem.length) return problem;

        auto steps = entry.at("steps");
        if (!steps.isArray) return "";

        size_t number;
        foreach (raw; steps.items)
        {
            auto step = raw;
            number++;
            if (!step.isObject) continue;
            const sql = step.at("sql").text;
            auto outcome = runStep(conn, sql);
            if (outcome.broken)
            {
                broken = true;
                return format!"step %s: %s\n  [sql: %s]"(number, outcome.error, sql);
            }
            auto complaint = check(step.at("expect"), outcome, sql);
            if (complaint.length)
                return format!"step %s: %s\n  [sql: %s]"(number, complaint, sql);
        }
        return "";
    }

    // ------------------------------------------------------------ one suite

    void runSuite(string path)
    {
        JsonValue document;
        try
            document = parseJson(readText(path));
        catch (Exception e)
        {
            record(baseName(path), "-", "ERROR", "", "cannot read the suite: " ~ e.msg, 0);
            report.failed++;
            return;
        }

        const suiteName = document.at("suite").isText
            ? document.at("suite").text : baseName(path);
        auto tests = document.at("tests");
        if (!tests.isArray) return;

        report.suites++;
        scope (exit) releaseSuite();

        foreach (raw; tests.items)
        {
            if (report.aborted.length) return;
            auto entry = raw;
            if (!entry.isObject) continue;
            const caseName = entry.at("name").isText ? entry.at("name").text : "-";

            const reason = skipReason(entry);
            if (reason.length)
            {
                report.skipped++;
                record(suiteName, caseName, "SKIP", "", reason, 0);
                continue;
            }

            auto clock = MonoTime.currTime;
            bool broken;
            string problem;
            try
                problem = runCase(entry, broken);
            catch (Exception e)
            {
                problem = "the runner itself failed: " ~ e.msg;
                broken = true;
            }
            const elapsed = (MonoTime.currTime - clock).total!"msecs";

            if (problem.length == 0)
            {
                report.passed++;
                record(suiteName, caseName, "PASS", "", "", elapsed);
                continue;
            }

            // Several hundred identical "connection refused" lines bury the one
            // fact worth reporting, so a dead engine stops the run instead.
            if (broken && !engineAlive())
            {
                report.aborted = format!
                    "the engine stopped answering during %s/%s: %s"(suiteName, caseName, problem);
                record(suiteName, caseName, "ERROR", "", problem, elapsed);
                return;
            }

            report.failed++;
            record(suiteName, caseName, broken ? "ERROR" : "FAIL", "", problem, elapsed);
            writefln("  FAIL %s / %s\n    %s", suiteName, caseName, problem);
        }
    }

    /// A suite may declare that a backend cannot run a case.
    private string skipReason(JsonValue entry)
    {
        auto skip = entry.at("skip");
        if (!skip.isObject) return "";
        auto backends = skip.at("backends");
        if (!backends.isArray) return "";
        bool named;
        foreach (raw; backends.items)
        {
            auto backend = raw;
            const name = backend.text.toLower();
            if (name == backendName || name == "http") named = true;
        }
        if (!named) return "";
        const reason = skip.at("reason");
        return "declared in the suite: "
            ~ (reason.isText && reason.text.length ? reason.text : "no reason given");
    }

    // ----------------------------------------------------------- assertions

    private string check(JsonValue expectation, ref StepOutcome outcome, string sql)
    {
        if (!expectation.isObject)
            return outcome.error.length ? "unexpected error: " ~ outcome.error : "";

        if (expectation.has("error"))
        {
            if (outcome.error.length == 0)
                return "expected an error, the statement succeeded";
            auto expected = expectation.at("error");
            if (expected.isObject)
            {
                if (expected.has("messageContains"))
                {
                    const wanted = expected.at("messageContains").text;
                    if (outcome.error.toLower().indexOf(wanted.toLower()) < 0)
                    {
                        // Engines before 0.1.0 refuse a blank statement at the
                        // HTTP endpoint itself — 400, "SQL is required" — so the
                        // engine never runs it and never produces its own
                        // wording. Newer ones answer with it and the check above
                        // passes; against an older one it is a capability gap
                        // rather than a mismatch. The statement did fail.
                        if (sql.strip().length == 0)
                        {
                            note("EMPTY_STATEMENT: this engine's HTTP API refuses a blank " ~
                                 "statement itself (HTTP 400 \"SQL is required\"), so its own " ~
                                 "\"Empty SQL statement.\" error cannot be observed over this " ~
                                 "transport");
                            return "";
                        }
                        return format!"the error [%s] does not contain [%s]"(outcome.error, wanted);
                    }
                }
                if (expected.has("code") || expected.has("sqlState"))
                    note("ERROR_CODE: failures carry a message only, so an error code or " ~
                         "SQLSTATE cannot be checked");
            }
            return "";
        }

        if (outcome.error.length)
            return "unexpected error: " ~ outcome.error;

        if (expectation.has("value"))
        {
            const actual = outcome.rows.length && outcome.rows[0].length
                ? cellText(outcome.rows[0][0]) : "";
            const wanted = scalarText(expectation.at("value"));
            if (normalize(wanted) != normalize(actual))
                return format!"value [%s] != expected [%s]"(actual, wanted);
        }

        auto wantedRows = expectation.at("rows");
        if (wantedRows.isArray)
        {
            auto want = appender!(string[]);
            foreach (raw; wantedRows.items)
            {
                auto row = raw;
                if (!row.isArray) continue;
                auto cells = appender!(string[]);
                foreach (cell; row.items)
                    cells.put(normalize(scalarText(cell)));
                want.put(cells.data.join(" | "));
            }
            auto got = appender!(string[]);
            foreach (row; outcome.rows)
            {
                auto cells = appender!(string[]);
                foreach (cell; row)
                    cells.put(normalize(cellText(cell)));
                got.put(cells.data.join(" | "));
            }
            auto wantList = want.data;
            auto gotList = got.data;
            auto ordered = expectation.at("ordered");
            if (!(ordered.isBoolean && ordered.boolean))
            {
                wantList.sort();
                gotList.sort();
            }
            if (wantList != gotList)
                return format!"rows differ:\n    expected %s\n    got      %s"(wantList, gotList);
        }

        if (expectation.has("rowCount"))
        {
            const wanted = asInteger(expectation.at("rowCount"));
            if (wanted >= 0 && outcome.rows.length != wanted)
                return format!"rowCount %s != expected %s"(outcome.rows.length, wanted);
        }

        auto wantedColumns = expectation.at("columns");
        if (wantedColumns.isArray)
        {
            auto want = appender!(string[]);
            foreach (raw; wantedColumns.items)
            {
                auto column = raw;
                want.put(scalarText(column).toUpper());
            }
            auto got = appender!(string[]);
            foreach (name; outcome.columns)
                got.put(name.toUpper());
            if (want.data != got.data)
                return format!"columns %s != expected %s"(got.data, want.data);
        }

        if (expectation.has("updateCount"))
        {
            const wanted = asInteger(expectation.at("updateCount"));
            if (wanted >= 0 && outcome.updateCount != wanted)
                return format!"updateCount %s != expected %s"(outcome.updateCount, wanted);
        }

        return "";
    }

    private void note(string text)
    {
        const line = format!"missing-API [%s] %s"(backendName, text);
        if (!report.notes.canFind(line)) report.notes ~= line;
    }

    private void record(string suite, string name, string status, string step,
                        string detail, long millis)
    {
        auto clean = detail.replace("\n", " ").replace("\t", " ").replace("\r", "");
        records ~= [suite, name, status, step, clean, millis.to!string].join("\t");
    }
}

// ------------------------------------------------------------- comparisons

/// A JSON scalar as the text the comparison works on. `null` becomes the empty
/// string, which $(D normalize) then reads as NULL.
private string scalarText(JsonValue value) @safe
{
    return value.isNull ? "" : value.text;
}

/// A cell as text, with NULL rendered the same way an expected `null` is.
private string cellText(Value cell) @safe
{
    return cell.isNull ? "" : cell.text;
}

/**
 * Whether a column carries semi-structured values, read from the type the
 * engine reported. The gate is the column's type and never the cell's shape: a
 * VARCHAR whose content happens to look like `"quoted"` is that text, and stays
 * it.
 */
private bool isSemiStructured(string dataType) @safe
{
    auto name = dataType.strip();
    const paren = name.indexOf('(');
    if (paren >= 0)
        name = name[0 .. paren].strip();
    switch (name.toUpper())
    {
        case "VARIANT", "OBJECT", "ARRAY": return true;
        default: return false;
    }
}

/**
 * The value a semi-structured cell carries, as the suites record it.
 *
 * A client is handed a VARIANT, OBJECT or ARRAY cell as its JSON $(I text) — a
 * string's own quotes included — which is what the account's own drivers do.
 * The suites record the value instead: `a` rather than `"a"`, and an object as
 * its own text rather than as a string holding that text. One level of decoding
 * covers both: a cell that is a JSON string becomes that string's contents, and
 * anything else — a number, a boolean, text that is not JSON at all — is left
 * exactly as it came.
 */
private Value semiStructuredValue(Value cell) @safe
{
    if (cell.isNull)
        return cell;
    try
    {
        auto decoded = parseJson(cell.text);
        if (decoded.isText)
            return Value.ofText(decoded.text);
    }
    catch (UsageException)
    {
        // Text that is not JSON at all is a value in its own right.
    }
    return cell;
}

/**
 * SCHEMA.md's value normalization, applied to both sides before comparing:
 * null/empty becomes NULL, booleans compare case-insensitively, anything
 * numeric compares as a number rounded to 10 significant digits, and everything
 * else is an exact trimmed string.
 */
string normalize(string value) @safe
{
    const text = value.strip();
    if (text.length == 0) return "NULL";
    switch (text.toLower())
    {
        case "null":  return "NULL";
        case "true":  return "TRUE";
        case "false": return "FALSE";
        default: break;
    }
    // Checked by shape first: D would happily read "nan" and "inf" as doubles,
    // and those are not numbers to round — they compare as the text they are.
    if (looksNumeric(text))
    {
        try
        {
            const number = text.to!double;
            if (number == 0) return "0";
            // Ten significant digits, which is what makes 2 and 2.000000 equal
            // and 3.5 and 3.500000 equal.
            return format!"%.10g"(number);
        }
        catch (ConvException) { }
    }
    return text;
}

private bool looksNumeric(const(char)[] text) @safe pure nothrow @nogc
{
    import std.ascii : isDigit;
    size_t i;
    if (i < text.length && (text[i] == '+' || text[i] == '-')) i++;
    size_t digits;
    while (i < text.length && text[i].isDigit) { i++; digits++; }
    if (i < text.length && text[i] == '.')
    {
        i++;
        while (i < text.length && text[i].isDigit) { i++; digits++; }
    }
    if (digits == 0) return false;
    if (i < text.length && (text[i] == 'e' || text[i] == 'E'))
    {
        i++;
        if (i < text.length && (text[i] == '+' || text[i] == '-')) i++;
        size_t exponent;
        while (i < text.length && text[i].isDigit) { i++; exponent++; }
        if (exponent == 0) return false;
    }
    return i == text.length;
}

private long asInteger(JsonValue value) @safe
{
    try
        return value.text.to!long;
    catch (Exception)
        return -1;
}

// ------------------------------------------------------------ finding things

/// What a run says instead of replaying the corpus when `FL_CORPUS` is not set.
enum corpusSkipReason =
    "set FL_CORPUS to frostlake's engine/src/test/resources/testkit to replay the testkit corpus";

/// The testkit directory to replay — frostlake's
/// `engine/src/test/resources/testkit` — as `FL_CORPUS` names it, or "" when
/// it names none.
string corpusDirectory()
{
    return environment.get("FL_CORPUS", "");
}

/// Why the testkit directory `corpus` cannot be replayed, or "" when it can:
/// its suites are the `*.json` files in its `suites` directory.
string corpusProblem(string corpus)
{
    const directory = buildPath(corpus, "suites");
    if (directory.exists && directory.isDir
        && !dirEntries(directory, "*.json", SpanMode.shallow).empty)
        return "";
    return format!"FL_CORPUS=%s holds no suites/*.json"(corpus);
}

/// Every suite file, in name order, narrowed by `FROSTLAKE_TESTKIT_FILTER`.
string[] suiteFiles(string directory)
{
    if (!directory.exists || !directory.isDir) return [];
    auto files = appender!(string[]);
    foreach (entry; dirEntries(directory, "*.json", SpanMode.shallow))
        files.put(entry.name);
    auto paths = files.data;
    paths.sort();

    const filter = environment.get("FROSTLAKE_TESTKIT_FILTER", "");
    if (filter.length == 0) return paths;
    auto narrowed = appender!(string[]);
    foreach (path; paths)
        if (baseName(path).canFind(filter))
            narrowed.put(path);
    return narrowed.data;
}

// ------------------------------------------------------------------- driving

/// Runs the whole corpus against `dsn` and writes the results out.
KitReport runTestkit(string dsn, string resultsDirectory = "results")
{
    auto runner = Runner(dsn);
    runner.sessionMode = environment.get("FROSTLAKE_TESTKIT_SESSION", "suite");
    if (!["run", "suite", "test"].canFind(runner.sessionMode))
        runner.sessionMode = "suite";

    const directory = buildPath(corpusDirectory(), "suites");
    auto files = suiteFiles(directory);
    if (files.length == 0)
    {
        writefln("no testkit suites found in %s", directory);
        return runner.report;
    }

    writefln("testkit: %s suite file(s) from %s (session=%s)",
             files.length, directory, runner.sessionMode);

    scope (exit) runner.releaseAll();
    auto clock = MonoTime.currTime;
    foreach (i, path; files)
    {
        if (runner.report.aborted.length) break;
        runner.runSuite(path);
        if ((i + 1) % 50 == 0)
        {
            writefln("  ... %s/%s files, %s pass / %s fail / %s skip",
                     i + 1, files.length, runner.report.passed,
                     runner.report.failed, runner.report.skipped);
            stdout.flush();
        }
    }
    const elapsed = (MonoTime.currTime - clock).total!"seconds";

    writeResults(runner, resultsDirectory);

    writeln();
    writefln("testkit [%s]: %s pass, %s fail, %s skip across %s suite(s) in %ss",
             backendName, runner.report.passed, runner.report.failed,
             runner.report.skipped, runner.report.suites, elapsed);
    if (runner.report.aborted.length)
        writefln("ABORTED: %s", runner.report.aborted);
    foreach (line; runner.report.notes)
        writefln("  %s", line);
    return runner.report;
}

private void writeResults(ref Runner runner, string directory)
{
    try
    {
        mkdirRecurse(directory);
        auto rows = appender!string();
        rows.put("suite\ttest\tstatus\tfailedStep\tdetail\tms\n");
        foreach (line; runner.records)
        {
            rows.put(line);
            rows.put('\n');
        }
        write(buildPath(directory, "testkit-" ~ backendName ~ ".tsv"), rows.data);

        if (runner.report.notes.length)
        {
            auto notes = appender!string();
            notes.put("# APIs this transport does not expose\n\n");
            notes.put("Recorded by the D driver's testkit runner. Each line is a check the\n");
            notes.put("suites ask for that the HTTP protocol cannot answer; the expectations\n");
            notes.put("are already in the suite files, so the day the API exists the checks\n");
            notes.put("light up without touching a single test.\n\n");
            foreach (line; runner.report.notes)
            {
                notes.put("- ");
                notes.put(line);
                notes.put('\n');
            }
            write(buildPath(directory, "missing-apis-" ~ backendName ~ ".md"), notes.data);
        }
    }
    catch (Exception e)
        writefln("could not write results: %s", e.msg);
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    // SCHEMA.md's normalization, on both sides of every comparison.
    assert(normalize("") == "NULL");
    assert(normalize("   ") == "NULL");
    assert(normalize("null") == "NULL");
    assert(normalize("NULL") == "NULL");
    assert(normalize("true") == "TRUE");
    assert(normalize("TRUE") == "TRUE");
    assert(normalize("False") == "FALSE");

    // Numbers compare as numbers.
    assert(normalize("2") == normalize("2.000000"));
    assert(normalize("3.5") == normalize("3.500000"));
    assert(normalize("-0") == normalize("0"));
    assert(normalize("1e3") == normalize("1000"));

    // ...but the non-numbers that D would read as doubles do not.
    assert(normalize("NaN") == "NaN");
    assert(normalize("Infinity") == "Infinity");
    assert(normalize("inf") == "inf");
    assert(normalize("nan") == "nan");

    // Everything else is exact, trimmed.
    assert(normalize("  Ada  ") == "Ada");
    assert(normalize("2024-01-15") == "2024-01-15");
    assert(normalize("abc") == "abc");
}

@safe unittest
{
    // What counts as numeric for the rule above.
    assert(looksNumeric("1"));
    assert(looksNumeric("-1.5"));
    assert(looksNumeric("+2e10"));
    assert(looksNumeric(".5"));
    assert(!looksNumeric("NaN"));
    assert(!looksNumeric("inf"));
    assert(!looksNumeric("0x10"));
    assert(!looksNumeric("1e"));
    assert(!looksNumeric(""));
    assert(!looksNumeric("2024-01-15"));
}

@safe unittest
{
    // A NULL cell and an expected `null` normalise to the same thing, and an
    // empty string is not distinguishable from NULL by this rule — which is
    // what SCHEMA.md prescribes.
    assert(normalize(cellText(Value.ofNull())) == "NULL");
    assert(normalize(cellText(Value.ofText(""))) == "NULL");
    assert(normalize(cellText(Value.ofNumber("2"))) == "2");
    assert(normalize(cellText(Value.ofBoolean(true))) == "TRUE");
}

@safe unittest
{
    // Which columns are read as semi-structured, ignoring the type's (p,s) tail.
    assert(isSemiStructured("VARIANT"));
    assert(isSemiStructured("object"));
    assert(isSemiStructured(" Array "));
    assert(!isSemiStructured("VARCHAR"));
    assert(!isSemiStructured("VARCHAR(16)"));
    assert(!isSemiStructured(""));
}

@safe unittest
{
    // One level of decoding: a JSON string becomes its contents — which for a
    // container is the container's own text — and every other cell is left
    // exactly as it came.
    assert(semiStructuredValue(Value.ofText(`"a"`)).text == "a");
    assert(semiStructuredValue(Value.ofText(`"{\"k\":1}"`)).text == `{"k":1}`);
    assert(semiStructuredValue(Value.ofText("5")).text == "5");
    assert(semiStructuredValue(Value.ofText("true")).text == "true");
    assert(semiStructuredValue(Value.ofText("{\"k\":1}")).text == `{"k":1}`);
    assert(semiStructuredValue(Value.ofText("not json")).text == "not json");
    assert(semiStructuredValue(Value.ofNull()).isNull);
}
