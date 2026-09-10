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
 */
module tests.integration_main;

import std.stdio : writefln, writeln;

import tests.engine;
import tests.integration;
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

    writeln();
    writefln("integration: %s passed, %s failed", passed, failed);
    return failed ? 1 : 0;
}
