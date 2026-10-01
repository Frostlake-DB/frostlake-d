/**
 * The tests that need a server: the scripted-transport ones, and the
 * engine-backed ones.
 *
 * The pure-logic tests live in `unittest` blocks next to the code they test and
 * are run by `dub test`, which needs nothing. These need something to talk to,
 * so they get an entry point of their own:
 *
 * ---
 * dub test                                                    # pure logic only
 * FROSTLAKE_CLASSPATH='.../lib/*' dub run -c integration      # + a real engine
 * ---
 *
 * Without `FROSTLAKE_CLASSPATH` the engine-backed tests report themselves as
 * skipped and the run still succeeds — but it says so, so a green run is never
 * mistaken for a complete one. The scripted-transport tests always run; they
 * need no engine.
 *
 * Last, with `FL_CORPUS` naming frostlake's `engine/src/test/resources/testkit`,
 * the engine's testkit corpus is replayed through the driver; without it that
 * step, too, reports itself as skipped.
 */
module tests.integration_main;

import std.process : environment;
import std.stdio : writefln, writeln;

import tests.engine;
import tests.integration;
import tests.testkit;
import tests.transport;

int main(string[] arguments)
{
    size_t failed;
    failed += runTransportTests();

    if (!engineAvailable())
    {
        writeln();
        writefln("engine-backed tests SKIPPED: %s", engineSkipReason());
        writeln("set FROSTLAKE_CLASSPATH to the engine's classpath to run them.");
        failed += replayCorpus();
        return failed ? 1 : 0;
    }

    writeln();
    writeln("booting an engine for the integration tests...");
    auto engine = startEngine();
    scope (exit) engine.stop();
    writefln("engine on %s", engine.dsn);
    writeln();

    size_t passed;
    foreach (test; integrationTests)
    {
        try
        {
            test.run(engine.dsn);
            passed++;
            writefln("  ok    %s", test.name);
        }
        catch (Throwable e)
        {
            failed++;
            writefln("  FAIL  %s\n          %s", test.name, e.msg);
        }
    }

    // A check the engine could not answer is named rather than counted as a
    // pass: a green tick would claim an engine had been checked for something
    // it never reports.
    foreach (note; skippedChecks())
        writefln("  skip  %s", note);

    writeln();
    writefln("integration: %s passed, %s failed, %s check(s) skipped",
             passed, failed, skippedChecks().length);
    engine.stop();
    failed += replayCorpus();
    return failed ? 1 : 0;
}

/**
 * The engine's testkit corpus, replayed through the driver when `FL_CORPUS`
 * names it: against `FROSTLAKE_URL`, or else an engine booted for it alone, so
 * that nothing the tests above created is in its way. Returns the failures.
 */
private size_t replayCorpus()
{
    writeln();
    const corpus = corpusDirectory();
    if (corpus.length == 0)
    {
        writefln("testkit corpus SKIPPED: %s", corpusSkipReason);
        return 0;
    }
    const problem = corpusProblem(corpus);
    if (problem.length)
    {
        writefln("testkit corpus FAILED: %s", problem);
        return 1;
    }

    auto dsn = environment.get("FROSTLAKE_URL", "");
    TestEngine engine;
    scope (exit) engine.stop();
    if (dsn.length == 0)
    {
        if (!engineAvailable())
        {
            writeln("testkit corpus SKIPPED: neither FROSTLAKE_URL nor ",
                    "FROSTLAKE_CLASSPATH names an engine");
            return 0;
        }
        writeln("booting an engine for the testkit corpus...");
        engine = startEngine();
        dsn = engine.dsn;
    }
    return runTestkit(dsn).ok ? 0 : 1;
}
