/**
 * Runs the engine-owned testkit corpus through this driver.
 *
 * ---
 * FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
 * JAVA_HOME=... FROSTLAKE_CLASSPATH='.../lib/*' \
 *     dub run --config=testkit
 * ---
 *
 * Replays the testkit directory `FL_CORPUS` names, and without it says so and
 * exits 0. Boots an engine of its own — with a per-run home and data
 * directory, so a run never inherits the last one's account-level objects —
 * points the runner at it, and exits non-zero if anything failed.
 */
module tests.testkit_main;

import std.process : environment;
import std.stdio : writefln, writeln;

import tests.engine;
import tests.testkit;

int main(string[] arguments)
{
    const corpus = corpusDirectory();
    if (corpus.length == 0)
    {
        writeln(corpusSkipReason);
        return 0;
    }
    const problem = corpusProblem(corpus);
    if (problem.length)
    {
        writefln("cannot run the corpus: %s", problem);
        return 2;
    }

    // An engine already running somewhere else can be used instead, which is
    // how a corpus run gets pointed at a server under a debugger.
    const external = environment.get("FROSTLAKE_URL", "");
    if (external.length)
    {
        writefln("using the engine at %s", external);
        return runTestkit(external).ok ? 0 : 1;
    }

    if (!engineAvailable())
    {
        writefln("cannot run the corpus: %s", engineSkipReason());
        writeln("set FROSTLAKE_CLASSPATH to the engine's classpath, or FROSTLAKE_URL");
        writeln("to a server that is already running.");
        return 2;
    }

    auto engine = startEngine();
    scope (exit) engine.stop();
    writefln("engine on %s (log: %s)", engine.dsn, engine.logPath);

    auto report = runTestkit(engine.dsn);
    return report.ok ? 0 : 1;
}
