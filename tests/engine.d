/**
 * A real `DatabaseHttpServer`, booted from an engine classpath for the tests
 * that need one.
 *
 * Nothing here is mocked: every statement the integration tests send travels
 * the driver's own HTTP path to a live engine. Without
 * `FROSTLAKE_CLASSPATH` there is no server, and the tests that need one skip
 * themselves rather than passing against a stub — a green suite that never
 * reached an engine would be worse than a skipped one.
 */
module tests.engine;

import core.thread : Thread;
import core.time : msecs, seconds;

import std.array : appender;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.file : exists, mkdirRecurse, tempDir;
import std.format : format;
import std.path : buildPath;
import std.process : Config, environment, Pid, ProcessException, spawnProcess, wait;
import std.socket : InternetAddress, TcpSocket;
import std.stdio : File, stdin;

/// The engine classpath the tests were given, or "" when they were given none.
string engineClasspath()
{
    return environment.get("FROSTLAKE_CLASSPATH", "");
}

/// Why the engine-backed tests cannot run, or "" when they can.
string engineSkipReason()
{
    if (engineClasspath().length == 0)
        return "FROSTLAKE_CLASSPATH is not set, so no engine can be started";
    return "";
}

/// Whether an engine can be started at all.
bool engineAvailable()
{
    return engineSkipReason().length == 0;
}

/// The `java` to boot it with: `JAVA_HOME` when that names one, else the PATH's.
private string javaCommand()
{
    const home = environment.get("JAVA_HOME", "");
    if (home.length)
    {
        version (Windows)
            const candidate = buildPath(home, "bin", "java.exe");
        else
            const candidate = buildPath(home, "bin", "java");
        if (candidate.exists) return candidate;
    }
    return "java";
}

/// A running engine, and how to reach it.
struct TestEngine
{
    Pid pid;
    ushort port;
    string dsn;
    string logPath;
    string homeDirectory;

    /// Whether the process is still up.
    bool alive()
    {
        if (pid is null) return false;
        import std.process : tryWait;
        return !tryWait(pid).terminated;
    }

    void stop()
    {
        if (pid is null) return;
        import std.process : kill;
        try
        {
            kill(pid);
            wait(pid);
        }
        catch (Exception) { }
        pid = null;
    }
}

/// A port nothing is listening on, named by the OS.
private ushort freePort()
{
    auto probe = new TcpSocket();
    scope (exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

/**
 * Boots a server on a free port and waits for it to answer.
 *
 * The engine keeps its catalog under `~/.frostlake_engine/data` and its
 * internal stages under `~/.frostlake_stages`, so consecutive runs would
 * otherwise inherit each other's warehouses, databases and stages — and the
 * tests create account-level objects that outlive a per-test reset. Both
 * are pointed at a directory of this run's own, which is what makes a run
 * repeatable.
 */
TestEngine startEngine()
{
    const classpath = engineClasspath();
    if (classpath.length == 0)
        throw new Exception("FROSTLAKE_CLASSPATH is not set");

    const port = freePort();
    const home = buildPath(tempDir(), format!"frostlake-d-%s"(port));
    mkdirRecurse(buildPath(home, "data"));
    const logPath = buildPath(home, "server.log");

    auto arguments = [
        javaCommand(),
        // The JDK's HTTP server leaves Nagle's algorithm on unless told
        // otherwise, which costs a keep-alive client like this one ~45 ms a
        // statement on Linux and macOS.
        "-Dsun.net.httpserver.nodelay=true",
        "-Duser.home=" ~ home,
        "-cp", classpath,
        "dev.frostlake.http.DatabaseHttpServer",
        port.to!string,
    ];

    auto env = environment.toAA();
    env["SQL_ENGINE_DATA_DIR"] = buildPath(home, "data");

    // A real log file, not a null sink: the log is what says why a boot failed.
    auto log = File(logPath, "w");
    auto pid = spawnProcess(arguments, stdin, log, log, env, Config.none);

    auto engine = TestEngine(pid, port, format!"frostlake://127.0.0.1:%s"(port),
                             logPath, home);
    if (!waitUntilHealthy(engine))
    {
        engine.stop();
        throw new Exception(format!
            "the engine did not answer /api/health within 60s; see %s"(logPath));
    }
    return engine;
}

/// Polls the engine's health endpoint through the driver itself, so "healthy"
/// means "this driver can talk to it", not merely "something is listening".
private bool waitUntilHealthy(ref TestEngine engine, int limitSeconds = 60)
{
    import core.time : MonoTime;
    import frostlake : connect, ConnectOptions;

    ConnectOptions options;
    options.connectTimeout = seconds(5);
    options.timeout = seconds(5);

    const deadline = MonoTime.currTime + seconds(limitSeconds);
    while (MonoTime.currTime < deadline)
    {
        if (!engine.alive) return false;
        try
        {
            auto conn = connect(engine.dsn, options);
            conn.close();
            return true;
        }
        catch (Exception)
            Thread.sleep(msecs(200));
    }
    return false;
}
