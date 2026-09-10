/**
 * Finding the placeholders in a statement, and replacing them with literals.
 *
 * Both marker styles are supported, and which one a statement uses is decided
 * by the $(I statement), not by the arguments: `?` markers take positional
 * arguments, `:name` markers take named ones. Mixing the two in one statement
 * is refused rather than guessed at.
 *
 * The scan that finds the markers is shared by counting and substitution, so
 * the two cannot disagree about what is a placeholder. It steps over string
 * literals, quoted identifiers, dollar-quoted bodies and comments, which is why
 * a `?` inside a procedure body stays part of the body.
 */
module frostlake.bind;

import std.algorithm : canFind, sort;
import std.array : appender, join;
import std.ascii : isDigit;
import std.format : format;
import std.uni : toUpper;

import frostlake.errors;
import frostlake.sql : isWordChar, skipEnclosure;
import frostlake.value : Param;

/// One placeholder: where it sits, and what it is called.
struct BindSite
{
    /// Index of the marker's first character.
    size_t start;
    /// Index just past the marker.
    size_t stop;
    /// The parameter's name, upper-cased — empty for a positional `?`.
    string name;

    @property bool isPositional() const @safe pure nothrow @nogc { return name.length == 0; }
}

/**
 * Every bind site in a statement, in the order they appear.
 *
 * A colon is a placeholder only where nothing else claims it. `::` is a cast
 * and `:=` an assignment; a colon $(I adjacent) to the end of an expression —
 * an identifier character, a closing bracket, or a quote — is VARIANT path
 * access (`v:field`, `PARSE_JSON('...'):k`) rather than a marker; and `:1` is a
 * positional reference, not a name.
 */
BindSite[] bindSites(const(char)[] sql) @safe pure
{
    auto result = appender!(BindSite[]);
    for (size_t i = 0; i < sql.length; i++)
    {
        const skip = skipEnclosure(sql, i);
        if (skip >= 0) { i = cast(size_t) skip - 1; continue; }

        const c = sql[i];
        if (c == '?')
        {
            result.put(BindSite(i, i + 1, ""));
            continue;
        }
        if (c != ':') continue;

        const next = i + 1 < sql.length ? sql[i + 1] : '\0';
        if (next == ':' || next == '=') { i++; continue; }

        if (i > 0)
        {
            const prev = sql[i - 1];
            if (isWordChar(prev) || prev == ')' || prev == ']' || prev == '}'
                || prev == '"' || prev == '\'')
                continue;
        }

        size_t j = i + 1;
        while (j < sql.length && isWordChar(sql[j])) j++;
        if (j == i + 1) continue;                    // a bare colon names nothing
        if (sql[i + 1].isDigit) continue;            // `:1` is a positional reference

        result.put(BindSite(i, j, sql[i + 1 .. j].toUpper().idup));
        i = j - 1;
    }
    return result.data;
}

/**
 * The parameter names a statement carries, upper-cased, in order of first
 * appearance.
 */
string[] bindNames(const(char)[] sql) @safe pure
{
    auto result = appender!(string[]);
    foreach (site; bindSites(sql))
        if (!site.isPositional && !result.data.canFind(site.name))
            result.put(site.name);
    return result.data;
}

/**
 * How many arguments a statement expects.
 *
 * Named placeholders count once each however often they appear. A statement
 * mixing the two styles answers `-1`, leaving the real complaint to the
 * substitution, which can say which style it found where.
 */
ptrdiff_t bindCount(const(char)[] sql) @safe pure
{
    size_t positional;
    string[] named;
    foreach (site; bindSites(sql))
    {
        if (site.isPositional) positional++;
        else if (!named.canFind(site.name)) named ~= site.name;
    }
    if (positional > 0 && named.length > 0) return -1;
    return named.length ? cast(ptrdiff_t) named.length : cast(ptrdiff_t) positional;
}

/**
 * Inlines positional `?` placeholders.
 *
 * The count must match in both directions: a placeholder left without an
 * argument is an error, never a silently bound NULL.
 *
 * With no arguments at all the statement passes through untouched — the `?`
 * marks are then the $(I server's), a Scripting cursor placeholder bound by
 * `OPEN c USING (...)`, and rewriting them would break a statement that was
 * never asking this driver for anything.
 */
string bindPositional(const(char)[] sql, const(Param)[] params) @safe pure
{
    auto sites = bindSites(sql);
    size_t named;
    foreach (site; sites)
        if (!site.isPositional) named++;

    if (named > 0 && named != sites.length)
        throw new UsageException("a statement may use ? or :name placeholders, not both");
    if (named > 0)
    {
        if (params.length == 0) return sql.idup;
        throw new UsageException(
            "the statement uses :name placeholders; pass named parameters instead");
    }
    if (params.length == 0) return sql.idup;
    if (sites.length != params.length)
        throw new UsageException(format!
            "the statement has %s placeholder(s), got %s argument(s)"(
            sites.length, params.length));

    auto literals = appender!(string[]);
    foreach (param; params) literals.put(param.literal);
    return render(sql, sites, literals.data);
}

/**
 * Inlines `:name` placeholders.
 *
 * Names match case-insensitively and their order does not matter. An argument
 * that no placeholder mentions is an error rather than a silent no-op — it
 * almost always means the name was misspelled on one side or the other.
 */
string bindNamed(const(char)[] sql, const(Param[string]) params) @safe pure
{
    auto sites = bindSites(sql);
    size_t positional;
    foreach (site; sites)
        if (site.isPositional) positional++;

    if (positional > 0 && positional != sites.length)
        throw new UsageException("a statement may use ? or :name placeholders, not both");
    if (positional > 0)
        throw new UsageException(
            "the statement uses positional ? placeholders; pass a list of parameters instead");

    Param[string] byName;
    foreach (key, value; params)
        byName[key.toUpper().idup] = value;

    if (sites.length == 0)
    {
        if (byName.length == 0) return sql.idup;
        throw new UsageException(format!
            "the statement has no placeholders, got %s named argument(s)"(byName.length));
    }

    bool[string] used;
    auto literals = appender!(string[]);
    foreach (site; sites)
    {
        auto found = site.name in byName;
        if (found is null)
        {
            import std.uni : toLower;
            throw new UsageException("no argument bound for :" ~ site.name.toLower().idup);
        }
        used[site.name] = true;
        literals.put(found.literal);
    }

    string[] unused;
    foreach (key; byName.byKey)
        if (key !in used)
        {
            import std.uni : toLower;
            unused ~= ":" ~ key.toLower().idup;
        }
    if (unused.length)
    {
        unused.sort();
        throw new UsageException(format!
            "argument(s) %s do not appear in the statement"(unused.join(", ")));
    }

    return render(sql, sites, literals.data);
}

/// Rebuilds the statement with each bind site replaced by its literal.
private string render(const(char)[] sql, const(BindSite)[] sites, const(string)[] literals) @safe pure
{
    auto result = appender!string();
    size_t cursor;
    foreach (i, site; sites)
    {
        if (site.start > cursor) result.put(sql[cursor .. site.start]);
        result.put(literals[i]);
        cursor = site.stop;
    }
    result.put(sql[cursor .. $]);
    return result.data;
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    // Positional markers, found and counted.
    auto sites = bindSites("SELECT ? , ?");
    assert(sites.length == 2);
    assert(sites[0].start == 7 && sites[0].stop == 8 && sites[0].isPositional);
    assert(bindCount("SELECT ?, ?, ?") == 3);
    assert(bindCount("SELECT 1") == 0);
}

@safe unittest
{
    // Named markers, upper-cased, counted once each.
    assert(bindNames("SELECT :a + :b") == ["A", "B"]);
    assert(bindNames("SELECT :x, :x, :y") == ["X", "Y"]);
    assert(bindCount("SELECT :x, :x, :y") == 2);
    assert(bindCount("SELECT ?, :a") == -1);       // mixed styles
}

@safe unittest
{
    // A colon that is not a placeholder stays out of the way.
    assert(bindSites("SELECT 1::NUMBER").length == 0);            // a cast
    assert(bindSites("SET v := 1").length == 0);                  // an assignment
    assert(bindSites("SELECT v:field FROM t").length == 0);       // VARIANT path
    assert(bindSites(`SELECT PARSE_JSON('{}'):k`).length == 0);   // path off a string
    assert(bindSites("SELECT OBJECT_CONSTRUCT('a',1):a").length == 0);
    assert(bindSites(`SELECT "V":k FROM t`).length == 0);         // path off an identifier
    assert(bindSites("SELECT :1").length == 0);                   // positional reference
    assert(bindSites("SELECT a : b").length == 0);                // a bare colon
}

@safe unittest
{
    // Markers inside quoted or commented text are not markers.
    assert(bindSites("SELECT '?'").length == 0);
    assert(bindSites(`SELECT "?"`).length == 0);
    assert(bindSites("SELECT 1 -- ?").length == 0);
    assert(bindSites("SELECT 1 /* :name */").length == 0);
    assert(bindSites("CREATE FUNCTION f() AS $$ return x ? 1 : 2 $$").length == 0);
    assert(bindSites("SELECT ':name'").length == 0);
}

@safe unittest
{
    import frostlake.value : toParam;
    // Substitution, with the D types deciding each literal.
    assert(bindPositional("SELECT ?", [toParam(1)]) == "SELECT 1");
    assert(bindPositional("SELECT ?, ?", [toParam(1), toParam("a")]) == "SELECT 1, 'a'");
    assert(bindPositional("INSERT INTO t VALUES (?, ?)", [toParam(1), toParam(null)])
           == "INSERT INTO t VALUES (1, NULL)");
    // A literal next to a marker is left exactly as it was.
    assert(bindPositional("SELECT '?', ?", [toParam(2)]) == "SELECT '?', 2");
}

@safe unittest
{
    import frostlake.value : toParam;
    // Named substitution: order does not matter, case does not matter, and a
    // name used twice is bound twice.
    Param[string] p = ["a": toParam(2), "b": toParam(40)];
    assert(bindNamed("SELECT :a + :b", p) == "SELECT 2 + 40");
    assert(bindNamed("SELECT :B + :A", p) == "SELECT 40 + 2");

    Param[string] one = ["x": toParam(7)];
    assert(bindNamed("SELECT :x, :x", one) == "SELECT 7, 7");
}

@safe unittest
{
    import std.exception : assertThrown, collectExceptionMsg;
    import frostlake.value : toParam;

    // Counts must match in both directions.
    assertThrown!UsageException(bindPositional("SELECT ?, ?", [toParam(1)]));
    assertThrown!UsageException(bindPositional("SELECT ?", [toParam(1), toParam(2)]));
    assertThrown!UsageException(bindPositional("SELECT 1", [toParam(1)]));

    // The two styles cannot be mixed.
    assertThrown!UsageException(bindPositional("SELECT ?, :a", [toParam(1), toParam(2)]));

    // A named statement given positional arguments says so.
    assert(collectExceptionMsg(bindPositional("SELECT :a", [toParam(1)]))
           .canFind("pass named parameters"));

    // A misspelled name is reported rather than silently ignored.
    Param[string] wrong = ["nmae": toParam(1)];
    assert(collectExceptionMsg(bindNamed("SELECT :name", wrong)).canFind(":name"));

    Param[string] extra = ["a": toParam(1), "b": toParam(2)];
    assert(collectExceptionMsg(bindNamed("SELECT :a", extra)).canFind(":b"));
}

@safe unittest
{
    // With no arguments at all a marker belongs to the SERVER and the statement
    // passes through verbatim: Scripting variables and cursor placeholders are
    // bound by the engine, not here.
    assert(bindPositional("EXECUTE IMMEDIATE :v", []) == "EXECUTE IMMEDIATE :v");
    assert(bindPositional("OPEN c USING (?)", []) == "OPEN c USING (?)");
    assert(bindPositional("SELECT IFF(:flag, 1, 2)", []) == "SELECT IFF(:flag, 1, 2)");
    Param[string] none;
    assert(bindNamed("SELECT 1", none) == "SELECT 1");
}

@safe unittest
{
    import frostlake.value : toParam;
    // A bound value carrying SQL syntax stays inside its literal.
    const sql = bindPositional("SELECT * FROM t WHERE name = ?",
                               [toParam("'; DROP TABLE t; --")]);
    assert(sql == "SELECT * FROM t WHERE name = '''; DROP TABLE t; --'");
    // And binding into a statement does not create new bind sites.
    assert(bindSites(sql).length == 0);
}
