/**
 * Lexical helpers shared by parameter binding and session-scope tracking.
 *
 * Both need to walk a statement while stepping over the places where SQL stops
 * meaning what it says — string literals, quoted identifiers, dollar-quoted
 * bodies and comments — so both read the same scanner here and cannot disagree
 * about what is inside one. A `?` inside a procedure body is part of the body;
 * a `;` inside a string is not a statement break.
 *
 * Positions are byte indices. Every character the scanner reacts to is ASCII,
 * and a UTF-8 continuation byte is never mistaken for one, so scanning bytes is
 * safe on any text the engine will accept.
 */
module frostlake.sql;

import std.array : appender;
import std.ascii : isAlphaNum, isWhite;
import std.uni : toUpper;

/// Whether `c` may appear in an unquoted identifier.
bool isWordChar(char c) @safe pure nothrow @nogc
{
    return c.isAlphaNum || c == '_' || c == '$';
}

/**
 * Whether a comment or a quoted region opens at `i`, and where it ends.
 *
 * Returns: the index just past the region, or `-1` when `i` opens none.
 *
 * Every walk over a statement starts here, so none of them can forget a case.
 */
ptrdiff_t skipEnclosure(const(char)[] sql, size_t i) @safe pure nothrow @nogc
{
    if (i >= sql.length) return -1;
    switch (sql[i])
    {
        case '\'': return skipString(sql, i);
        case '"':  return skipQuoted(sql, i);
        case '$':
            if (opensDollarQuote(sql, i)) return skipDollarQuoted(sql, i);
            return -1;
        case '-':
            if (i + 1 < sql.length && sql[i + 1] == '-') return skipLine(sql, i);
            return -1;
        case '/':
            if (i + 1 < sql.length && sql[i + 1] == '/') return skipLine(sql, i);
            if (i + 1 < sql.length && sql[i + 1] == '*') return skipBlockComment(sql, i);
            return -1;
        default:
            return -1;
    }
}

/// Just past the single-quoted literal at `i`. Both `''` and backslash escapes
/// stay inside the literal — a backslash always escapes in Frostlake's dialect.
private ptrdiff_t skipString(const(char)[] sql, size_t i) @safe pure nothrow @nogc
{
    size_t j = i + 1;
    while (j < sql.length)
    {
        const c = sql[j];
        if (c == '\\')
            j += 2;
        else if (c == '\'')
        {
            if (j + 1 < sql.length && sql[j + 1] == '\'')
                j += 2;
            else
                return j + 1;
        }
        else
            j++;
    }
    return sql.length;
}

/// Just past the double-quoted identifier at `i`.
private ptrdiff_t skipQuoted(const(char)[] sql, size_t i) @safe pure nothrow @nogc
{
    size_t j = i + 1;
    while (j < sql.length)
    {
        if (sql[j] == '"')
        {
            if (j + 1 < sql.length && sql[j + 1] == '"') { j += 2; continue; }
            return j + 1;
        }
        j++;
    }
    return sql.length;
}

/// Whether the `$` at `i` opens a dollar-quoted body. A `$` is legal inside an
/// unquoted identifier, so `A$$B` is a name — a real delimiter is never
/// preceded by an identifier character.
private bool opensDollarQuote(const(char)[] sql, size_t i) @safe pure nothrow @nogc
{
    if (i + 1 >= sql.length || sql[i + 1] != '$') return false;
    if (i == 0) return true;
    return !isWordChar(sql[i - 1]);
}

/// Just past the dollar-quoted body at `i`. Function and procedure bodies are
/// written this way, and their contents are not SQL — a `?` inside one is part
/// of the body, never a placeholder.
private ptrdiff_t skipDollarQuoted(const(char)[] sql, size_t i) @safe pure nothrow @nogc
{
    for (size_t j = i + 2; j + 1 < sql.length; j++)
        if (sql[j] == '$' && sql[j + 1] == '$')
            return j + 2;
    return sql.length;
}

private ptrdiff_t skipLine(const(char)[] sql, size_t i) @safe pure nothrow @nogc
{
    for (size_t j = i; j < sql.length; j++)
        if (sql[j] == '\n')
            return j + 1;
    return sql.length;
}

private ptrdiff_t skipBlockComment(const(char)[] sql, size_t i) @safe pure nothrow @nogc
{
    for (size_t j = i + 2; j + 1 < sql.length; j++)
        if (sql[j] == '*' && sql[j + 1] == '/')
            return j + 2;
    return sql.length;
}

/**
 * Splits a request on its top-level semicolons, leaving alone any that sit
 * inside a string literal, a quoted identifier, a dollar-quoted body or a
 * comment.
 *
 * A procedural block is split along with everything else, which only makes the
 * scope check below more willing to flag — the safe direction.
 */
const(char)[][] splitStatements(return const(char)[] sql) @safe pure nothrow
{
    auto result = appender!(const(char)[][]);
    size_t start;
    for (size_t i = 0; i < sql.length; i++)
    {
        const skip = skipEnclosure(sql, i);
        if (skip >= 0) { i = cast(size_t) skip - 1; continue; }
        if (sql[i] == ';')
        {
            result.put(sql[start .. i]);
            start = i + 1;
        }
    }
    result.put(sql[start .. $]);
    return result.data;
}

/**
 * Up to `n` words from the start of a statement, upper-cased, skipping
 * whitespace and comments and stopping at the first thing that is not a word.
 */
string[] leadingWords(const(char)[] statement, size_t n) @safe pure
{
    auto result = appender!(string[]);
    size_t i;
    while (i < statement.length && result.data.length < n)
    {
        const c = statement[i];
        if (c.isWhite) { i++; continue; }
        // Only comments are stepped over here: a leading string literal or
        // quoted identifier means the statement does not start with a keyword.
        if (c == '-' || c == '/')
        {
            const skip = skipEnclosure(statement, i);
            if (skip >= 0) { i = cast(size_t) skip; continue; }
        }
        if (!isWordChar(c)) break;
        const start = i;
        while (i < statement.length && isWordChar(statement[i])) i++;
        result.put(statement[start .. i].toUpper().idup);
    }
    return result.data;
}

/// Modifiers that may sit between `CREATE`/`DROP`/`ALTER` and the kind of
/// object being named.
private immutable string[] objectModifiers = [
    "OR", "REPLACE", "TRANSIENT", "TEMPORARY", "TEMP", "VOLATILE",
    "LOCAL", "GLOBAL", "SECURE", "IF", "NOT", "EXISTS"
];

/**
 * Whether a request can move the session off the scope the DSN established.
 *
 * A request may hold more than one statement, and a `USE` riding behind a
 * leading `SELECT` moves the scope just as surely as one standing alone, so
 * every statement is examined rather than only the first.
 */
bool changesScope(const(char)[] sql) @safe pure
{
    foreach (statement; splitStatements(sql))
        if (statementChangesScope(statement))
            return true;
    return false;
}

private bool statementChangesScope(const(char)[] statement) @safe pure
{
    const words = leadingWords(statement, 6);
    if (words.length == 0) return false;
    switch (words[0])
    {
        // Only USE, the SET family, ALTER SESSION, and CREATE/DROP of a
        // DATABASE or SCHEMA move the session. CREATE TABLE and its kind leave
        // the scope exactly where it was, and counting those would mark the
        // session dirty for every DDL statement a caller runs.
        case "USE", "SET", "UNSET":
            return true;
        case "ALTER":
            return namesObject(words[1 .. $], ["SESSION"]);
        case "CREATE", "DROP":
            return namesObject(words[1 .. $], ["DATABASE", "SCHEMA"]);
        default:
            return false;
    }
}

private bool namesObject(const(string)[] words, const(string)[] want) @safe pure nothrow
{
    import std.algorithm : canFind;
    foreach (word; words)
    {
        if (objectModifiers.canFind(word)) continue;
        return want.canFind(word);
    }
    return false;
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    // Nothing opens at a plain character.
    assert(skipEnclosure("SELECT 1", 0) == -1);
    assert(skipEnclosure("a-b", 1) == -1);       // a lone dash is subtraction
    assert(skipEnclosure("a/b", 1) == -1);       // a lone slash is division
}

@safe unittest
{
    // String literals, with both escape conventions.
    assert(skipEnclosure("'abc' rest", 0) == 5);
    assert(skipEnclosure("'it''s' rest", 0) == 7);
    assert(skipEnclosure(`'a\'b' rest`, 0) == 6);
    assert(skipEnclosure("'unterminated", 0) == 13);   // runs to the end
}

@safe unittest
{
    // Quoted identifiers, comments and dollar-quoted bodies.
    assert(skipEnclosure(`"col" rest`, 0) == 5);
    assert(skipEnclosure(`"a""b" rest`, 0) == 6);
    assert(skipEnclosure("-- note\nSELECT", 0) == 8);
    assert(skipEnclosure("// note\nSELECT", 0) == 8);
    assert(skipEnclosure("/* note */ SELECT", 0) == 10);
    assert(skipEnclosure("$$body$$ rest", 0) == 8);
    // A `$` inside a name does not open a body.
    assert(skipEnclosure("A$$B", 1) == -1);
}

@safe unittest
{
    // Statement splitting ignores semicolons that are not statement breaks.
    assert(splitStatements("SELECT 1").length == 1);
    assert(splitStatements("SELECT 1; SELECT 2").length == 2);
    assert(splitStatements("SELECT ';'").length == 1);
    assert(splitStatements(`SELECT "a;b"`).length == 1);
    assert(splitStatements("SELECT 1 -- ; not a break\n").length == 1);
    assert(splitStatements("SELECT 1 /* ; */").length == 1);
    assert(splitStatements("CREATE FUNCTION f() AS $$ a; b; c $$").length == 1);
}

@safe unittest
{
    // Leading words, past whitespace and comments.
    assert(leadingWords("select * from t", 3) == ["SELECT"]);
    assert(leadingWords("  create or replace database d", 4)
           == ["CREATE", "OR", "REPLACE", "DATABASE"]);
    assert(leadingWords("/* c */ -- c\n USE DATABASE d", 2) == ["USE", "DATABASE"]);
    assert(leadingWords("", 3).length == 0);
    assert(leadingWords("'literal' first", 3).length == 0);
}

@safe unittest
{
    // What moves the session, and what does not.
    assert(changesScope("USE DATABASE d"));
    assert(changesScope("use schema s"));
    assert(changesScope("SET v = 1"));
    assert(changesScope("UNSET v"));
    assert(changesScope("ALTER SESSION SET TIMEZONE = 'UTC'"));
    assert(changesScope("CREATE DATABASE d"));
    assert(changesScope("CREATE OR REPLACE DATABASE d"));
    assert(changesScope("DROP SCHEMA IF EXISTS s"));
    assert(changesScope("CREATE TRANSIENT SCHEMA s"));

    assert(!changesScope("SELECT 1"));
    assert(!changesScope("CREATE TABLE t (id INT)"));
    assert(!changesScope("CREATE OR REPLACE TABLE t (id INT)"));
    assert(!changesScope("DROP TABLE IF EXISTS t"));
    assert(!changesScope("ALTER TABLE t ADD COLUMN c INT"));
    assert(!changesScope("INSERT INTO t VALUES (1)"));
    assert(!changesScope(""));
}

@safe unittest
{
    // A USE riding behind another statement still moves the scope...
    assert(changesScope("SELECT 1; USE DATABASE other"));
    // ...but the same words inside a literal do not.
    assert(!changesScope("SELECT 'USE DATABASE other'"));
    assert(!changesScope("SELECT 1 -- USE DATABASE other"));
    assert(!changesScope("CREATE FUNCTION f() AS $$ USE DATABASE other $$"));
}
