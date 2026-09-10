/**
 * Rendering D values as the SQL literals that stand in for bound parameters.
 *
 * The HTTP protocol has no server-side binding, so a parameter is inlined into
 * the statement here, with the same rules Frostlake's JDBC driver uses.
 *
 * $(H3 Why this driver can infer, where the string-based ones cannot)
 *
 * The Tcl, Lisp and shell-shaped drivers render every bind as a $(I string
 * literal) unless told otherwise, and they are right to: in those languages
 * `42` and `"42"` are the same value, so inferring "this looks numeric" would
 * silently turn a VARCHAR `007` into the number seven.
 *
 * D knows the difference. `007` is an `int`, `"007"` is a `string`, and the
 * compiler will not confuse them — so $(D toParam) reads the D type and renders
 * the literal the caller's own type already implies. A `string` is always
 * quoted, an `int` is always a bare numeral, and neither can be mistaken for
 * the other:
 *
 * ---
 * conn.execute("SELECT * FROM t LIMIT ?", 5);          // LIMIT 5     — a number
 * conn.execute("INSERT INTO t VALUES (?)", "007");     // VALUES('007') — text
 * ---
 *
 * $(D Param.raw) is the one escape hatch, and the one bind that can carry an
 * injection: it is inserted verbatim. It exists because the alternative —
 * callers splicing text into the statement themselves — is strictly worse.
 */
module frostlake.value;

import std.array : appender;
import std.ascii : isDigit;
import std.bigint : BigInt;
import std.conv : ConvException, to;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.format : format;
import std.math : isInfinity, isNaN;
import std.traits : OriginalType, isBoolean, isFloatingPoint, isIntegral, isSomeString, Unqual;
import std.typecons : Nullable;
import std.uni : toUpper;

import frostlake.dsn : quoteIdentifier;
import frostlake.errors;

/**
 * One bound parameter, already rendered as the literal that will replace its
 * placeholder.
 *
 * Rendering happens when the $(D Param) is built rather than when the statement
 * is sent, so a value that cannot be a literal is reported at the call that
 * supplied it.
 */
struct Param
{
    private string literal_;

    /// The SQL literal this parameter renders to.
    @property string literal() const @safe pure nothrow @nogc { return literal_; }

    /// SQL NULL.
    static Param ofNull() @safe pure nothrow
    {
        return Param("NULL");
    }

    /// A string literal. Quotes and backslashes are escaped the way the engine
    /// reads them back.
    static Param ofText(const(char)[] value) @safe pure nothrow
    {
        return Param(quoteLiteral(value));
    }

    /// A bare numeric literal, from text that must already look like a number.
    static Param ofNumber(const(char)[] text) @safe pure
    {
        if (!looksNumeric(text))
            throw new UsageException(
                format!"a number bind needs a number, got \"%s\""(text));
        return Param(parenthesized(text.idup));
    }

    /// ditto
    static Param ofNumber(T)(T value) @safe pure
    if (isIntegral!T || isFloatingPoint!T)
    {
        return Param(numberLiteral(value));
    }

    /// ditto
    static Param ofNumber(BigInt value) @safe
    {
        return Param(parenthesized(value.to!string));
    }

    static Param ofBoolean(bool value) @safe pure nothrow
    {
        return Param(value ? "TRUE" : "FALSE");
    }

    /// Bytes, rendered the way the engine writes BINARY.
    static Param ofBinary(const(ubyte)[] bytes) @safe pure nothrow
    {
        return Param("X'" ~ bytesToHex(bytes) ~ "'");
    }

    /// A `DATE` literal from `YYYY-MM-DD` text, or from a $(D Date).
    static Param ofDate(const(char)[] text) @safe pure nothrow
    {
        return Param(quoteLiteral(text) ~ "::DATE");
    }

    /// ditto
    static Param ofDate(Date value) @safe pure
    {
        return Param(quoteLiteral(value.toISOExtString()) ~ "::DATE");
    }

    /// A `TIME` literal.
    static Param ofTime(const(char)[] text) @safe pure nothrow
    {
        return Param(quoteLiteral(text) ~ "::TIME");
    }

    /// ditto
    static Param ofTime(TimeOfDay value) @safe pure
    {
        return Param(quoteLiteral(value.toISOExtString()) ~ "::TIME");
    }

    /// A `TIMESTAMP_NTZ` literal — an instant with no zone.
    static Param ofTimestamp(const(char)[] text) @safe pure nothrow
    {
        return Param(quoteLiteral(text) ~ "::TIMESTAMP_NTZ");
    }

    /// ditto
    static Param ofTimestamp(DateTime value) @safe pure
    {
        return Param(quoteLiteral(renderDateTime(value)) ~ "::TIMESTAMP_NTZ");
    }

    /**
     * A `TIMESTAMP_TZ` literal — an instant that names its offset.
     *
     * The offset is colonised on the way in. The engine $(I prints) an offset
     * as `+0100` but parses only `+01:00` (measured against engine 0.0.7: the
     * bare form is refused outright), so a value read straight out of a result
     * and bound back in would otherwise fail.
     */
    static Param ofTimestampTz(const(char)[] text) @safe pure nothrow
    {
        return Param(quoteLiteral(colonizeOffset(text)) ~ "::TIMESTAMP_TZ");
    }

    /// ditto
    static Param ofTimestampTz(SysTime value) @safe
    {
        return Param(quoteLiteral(renderSysTime(value)) ~ "::TIMESTAMP_TZ");
    }

    /// Semi-structured JSON text, parsed by the engine into a VARIANT.
    static Param ofVariant(const(char)[] json) @safe pure nothrow
    {
        return Param("PARSE_JSON(" ~ quoteLiteral(json) ~ ")");
    }

    /**
     * SQL inserted verbatim, with no quoting at all.
     *
     * Warning: this is the one bind that can carry SQL syntax, and so the one
     * that can carry an injection. Whatever it says becomes part of the
     * statement.
     */
    static Param raw(const(char)[] sql) @safe pure nothrow
    {
        return Param(sql.idup);
    }

    /// An identifier — a table or column name assembled at runtime — quoted so
    /// it can be spliced in safely.
    static Param identifier(const(char)[] name) @safe pure
    {
        return Param(quoteIdentifier(name));
    }
}

/**
 * Renders one D value as the parameter its own static type implies.
 *
 * $(TABLE
 * $(TR $(TH D type) $(TH literal))
 * $(TR $(TD `typeof(null)`) $(TD `NULL`))
 * $(TR $(TD `bool`) $(TD `TRUE` / `FALSE`))
 * $(TR $(TD any integer, `BigInt`) $(TD a bare numeral))
 * $(TR $(TD `float`, `double`, `real`) $(TD a numeric literal; NaN and the
 *      infinities become the `'NaN'::DOUBLE` form the engine accepts))
 * $(TR $(TD any string) $(TD a quoted string literal))
 * $(TR $(TD `ubyte[]`) $(TD `X'...'`))
 * $(TR $(TD `Date`, `TimeOfDay`, `DateTime`, `SysTime`) $(TD the matching
 *      temporal literal))
 * $(TR $(TD `Nullable!T`) $(TD `NULL` when empty, otherwise `T`'s rendering))
 * $(TR $(TD `Param`) $(TD itself — an explicit choice is never second-guessed))
 * )
 */
Param toParam(T)(auto ref T value) @safe
{
    alias U = Unqual!T;

    static if (is(U == Param))
        return value;
    else static if (is(U == typeof(null)))
        return Param.ofNull();
    else static if (is(U == Nullable!Inner, Inner))
        return value.isNull ? Param.ofNull() : toParam(value.get);
    else static if (isBoolean!U)
        return Param.ofBoolean(value);
    else static if (is(U == BigInt))
        return Param.ofNumber(value);
    else static if (is(U == enum))
        // An enum's `to!string` is its member's NAME, which would bind `jan`
        // rather than `1` — a bare identifier in the SQL. The value it stands
        // for is what the caller means.
        return toParam(cast(OriginalType!U) value);
    else static if (isIntegral!U || isFloatingPoint!U)
        return Param.ofNumber(value);
    else static if (isSomeString!U)
        return Param.ofText(value.to!string);
    else static if (is(U == Date))
        return Param.ofDate(value);
    else static if (is(U == TimeOfDay))
        return Param.ofTime(value);
    else static if (is(U == DateTime))
        return Param.ofTimestamp(value);
    else static if (is(U == SysTime))
        return Param.ofTimestampTz(value);
    else static if (is(U : const(ubyte)[]))
        return Param.ofBinary(value);
    else
        static assert(false,
            "frostlake: " ~ T.stringof ~ " has no default SQL literal. Bind it " ~
            "explicitly with Param.ofText, Param.ofNumber, Param.ofVariant or " ~
            "Param.raw.");
}

/**
 * Escapes `text` as a single-quoted SQL string literal, quotes included.
 *
 * Mirrors the engine's own literal encoder: backslashes are doubled — a
 * backslash always escapes in this dialect, so `'a\b'` really does mean a
 * backspace — and quotes are doubled.
 */
string quoteLiteral(const(char)[] text) @safe pure nothrow
{
    auto result = appender!string();
    result.reserve(text.length + 2);
    result.put('\'');
    foreach (char c; text)
    {
        if (c == '\\') result.put('\\');
        if (c == '\'') result.put('\'');
        result.put(c);
    }
    result.put('\'');
    return result.data;
}

/// The hex the engine writes BINARY as.
string bytesToHex(const(ubyte)[] bytes) @safe pure nothrow
{
    static immutable digits = "0123456789ABCDEF";
    auto result = appender!string();
    result.reserve(bytes.length * 2);
    foreach (b; bytes)
    {
        result.put(digits[b >> 4]);
        result.put(digits[b & 0x0F]);
    }
    return result.data;
}

/// The inverse: an even run of hex digits read back as bytes.
ubyte[] hexToBytes(const(char)[] text) @safe pure
{
    if (text.length % 2 != 0)
        throw new ValueException(
            format!"\"%s\" is not an even run of hex digits"(text));
    auto result = new ubyte[text.length / 2];
    foreach (i; 0 .. result.length)
    {
        const hi = hexDigit(text[i * 2]);
        const lo = hexDigit(text[i * 2 + 1]);
        if (hi > 15 || lo > 15)
            throw new ValueException(
                format!"\"%s\" is not an even run of hex digits"(text));
        result[i] = cast(ubyte)((hi << 4) | lo);
    }
    return result;
}

private ubyte hexDigit(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
    if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return cast(ubyte)(c - 'A' + 10);
    return 255;
}

/**
 * Renders a number as a literal.
 *
 * A float keeps a decimal point even when it is whole, so binding `1.0` names a
 * float rather than the integer `1`; and the non-finite values become the
 * quoted-and-cast form the engine parses. Measured against engine 0.0.7:
 * `'NaN'::DOUBLE`, `'Infinity'::DOUBLE` and `'-Infinity'::DOUBLE` are accepted,
 * while a bare `NaN` or the shorter `'Inf'` are not.
 */
private string numberLiteral(T)(T value) @safe pure
{
    static if (isFloatingPoint!T)
    {
        if (value.isNaN) return "'NaN'::DOUBLE";
        if (value.isInfinity) return value > 0 ? "'Infinity'::DOUBLE" : "'-Infinity'::DOUBLE";
        // %.17g always round-trips but is noisy; the shortest form that reads
        // back identically is the one a human would have written. Whether a
        // candidate reads back is decided exactly, not by asking Phobos'
        // parser: that parser is not correctly rounded, and confirmed a wrong
        // candidate about once in sixteen thousand doubles — a silent 1-ulp
        // corruption of the bound value. (It also overflowed on `%.1g` of
        // 1.7e308, which spells `2e+308`.)
        foreach (precision; 1 .. 18)
        {
            auto candidate = format("%." ~ precision.to!string ~ "g", value);
            if (roundTripsTo(candidate, value)) return parenthesized(withPoint(candidate));
        }
        return parenthesized(withPoint(format!"%.17g"(value)));
    }
    else
        return parenthesized(value.to!string);
}

/// A negative numeral goes in parentheses: spliced straight after a minus it
/// would otherwise open a `--` comment, so `SELECT 3-?` bound -5 became
/// `SELECT 3--5`, which the engine reads as `SELECT 3`.
private string parenthesized(string numeral) @safe pure nothrow
{
    return numeral.length && numeral[0] == '-' ? "(" ~ numeral ~ ")" : numeral;
}

/**
 * Reads a decimal numeral — `[+-]digits[.digits][e[+-]digits]` — into its
 * digits and decimal exponent, so `12.50e1` is `1250 × 10^-1`. Returns false
 * for anything else.
 */
package(frostlake) bool parseDecimal(string text, out BigInt digits, out long exponent,
                                     out bool negative) @safe pure
{
    size_t i = 0;
    if (i < text.length && (text[i] == '-' || text[i] == '+'))
    {
        negative = text[i] == '-';
        i++;
    }
    bool afterPoint = false;
    bool sawDigit = false;
    for (; i < text.length; i++)
    {
        const c = text[i];
        if (c >= '0' && c <= '9')
        {
            digits = digits * 10 + (c - '0');
            if (afterPoint) exponent--;
            sawDigit = true;
        }
        else if (c == '.' && !afterPoint)
            afterPoint = true;
        else if ((c == 'e' || c == 'E') && sawDigit && i + 1 < text.length)
        {
            try
                exponent += text[i + 1 .. $].to!long;
            catch (ConvException)
                return false;
            return true;
        }
        else
            return false;
    }
    return sawDigit;
}

/**
 * Whether a correctly rounding parser reads `text` back as exactly `value`.
 *
 * The candidate d·10^k has to fall strictly between the midpoints to the two
 * doubles neighbouring `value`; everything is cross-multiplied into integers,
 * so no floating-point parser takes part. A candidate sitting exactly on a
 * midpoint is refused — the tie rule is not worth modelling, and the next
 * precision up never sits on one.
 */
package(frostlake) bool roundTripsTo(string text, double value) @safe pure
{
    import std.math : frexp, nextDown, nextUp, isFinite;

    BigInt digits;
    long k;
    bool negative;
    if (!parseDecimal(text, digits, k, negative) || !isFinite(value)) return false;
    if (value == 0) return digits == 0;
    if (negative != (value < 0)) return false;
    const magnitude = value < 0 ? -value : value;

    // Every double, subnormals included, is an integer once scaled by 2^scale.
    enum int scale = 1200;
    static BigInt exact(double x) @safe pure
    {
        if (x == 0) return BigInt(0);
        int exp;
        const fraction = frexp(x, exp); // x = fraction · 2^exp, fraction in [0.5, 1)
        auto mantissa = BigInt(cast(long)(fraction * 9007199254740992.0)); // · 2^53
        return mantissa << cast(uint)(exp - 53 + scale);
    }

    auto below = exact(nextDown(magnitude));
    auto here = exact(magnitude);
    // Past the largest double the upper neighbour is infinity; mirror the gap.
    const up = nextUp(magnitude);
    auto above = isFinite(up) ? exact(up) : here + (here - below);

    // Candidate = digits · 10^k · 2^scale, kept over a common denominator 10^p.
    const long p = k < 0 ? -k : 0;
    const long q = k > 0 ? k : 0;
    auto candidate = (digits * (BigInt(10) ^^ cast(ulong) q)) << scale;
    auto tenP = BigInt(10) ^^ cast(ulong) p;
    auto twice = candidate * 2;
    return (below + here) * tenP < twice && twice < (here + above) * tenP;
}

@safe unittest
{
    import std.math : nextUp;

    // Phobos' parser reads this literal as the NEXT double, so the shortest
    // search used to hand back a literal naming the wrong value.
    union Bits { ulong bits; double value; }
    Bits tricky = { bits: 0x3fd08f1699908f16 };
    assert(!roundTripsTo("0.2587334155707465", tricky.value));
    assert(roundTripsTo("0.2587334155707465", nextUp(tricky.value)));
    const literal = numberLiteral(tricky.value);
    assert(roundTripsTo(literal, tricky.value), literal);
    assert(!roundTripsTo(literal, nextUp(tricky.value)), literal);

    assert(roundTripsTo("0.1", 0.1));
    assert(roundTripsTo("1e+21", 1e21));
    assert(!roundTripsTo("0.10000000000000002", 0.1));
    assert(numberLiteral(0.1) == "0.1");
    assert(numberLiteral(1.5) == "1.5");
    assert(numberLiteral(-1.5) == "(-1.5)");
    assert(numberLiteral(-7L) == "(-7)");
    assert(numberLiteral(7L) == "7");
    // Used to escape as a ConvException from the `2e+308` candidate.
    assert(roundTripsTo(numberLiteral(double.max), double.max));
    assert(numberLiteral(-double.max) == "(-" ~ numberLiteral(double.max) ~ ")");
    assert(roundTripsTo(numberLiteral(double.min_normal / 8), double.min_normal / 8));

    enum Color { red = 1, green = 2 }
    assert(toParam(Color.green).literal == "2");
}

/// Gives a whole float a decimal point, so it is not read back as an integer.
private string withPoint(string text) @safe pure nothrow
{
    foreach (char c; text)
        if (c == '.' || c == 'e' || c == 'E' || c == 'n' || c == 'i')
            return text;
    return text ~ ".0";
}

private bool looksNumeric(const(char)[] text) @safe pure nothrow @nogc
{
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

/// Puts the colon back into a `+0100`-style offset, leaving `+01:00` and `Z` alone.
string colonizeOffset(const(char)[] text) @safe pure nothrow
{
    if (text.length < 5) return text.idup;
    const tail = text[$ - 5 .. $];
    if ((tail[0] == '+' || tail[0] == '-')
        && tail[1].isDigit && tail[2].isDigit && tail[3].isDigit && tail[4].isDigit)
        return text[0 .. $ - 2].idup ~ ":" ~ text[$ - 2 .. $].idup;
    return text.idup;
}

private string renderDateTime(DateTime value) @safe pure
{
    return format!"%04d-%02d-%02d %02d:%02d:%02d"(
        value.year, value.month, value.day, value.hour, value.minute, value.second);
}

private string renderSysTime(SysTime value) @safe
{
    const offset = value.utcOffset;
    const total = offset.total!"minutes";
    const sign = total < 0 ? '-' : '+';
    const magnitude = total < 0 ? -total : total;
    auto text = format!"%04d-%02d-%02d %02d:%02d:%02d"(
        value.year, value.month, value.day, value.hour, value.minute, value.second);
    const fraction = value.fracSecs.total!"nsecs";
    if (fraction != 0)
        text ~= trimZeros(format!"%09d"(fraction));
    return format!"%s %s%02d:%02d"(text, sign, magnitude / 60, magnitude % 60);
}

private string trimZeros(string digits) @safe pure nothrow
{
    size_t end = digits.length;
    while (end > 1 && digits[end - 1] == '0') end--;
    return "." ~ digits[0 .. end];
}

// ------------------------------------------------------------- type names

/// Strips any `(p,s)` suffix, so `NUMBER(38,0)` and `NUMBER` answer alike.
string baseType(const(char)[] dataType) @safe pure
{
    auto name = dataType.toUpper();
    foreach (i, char c; name)
        if (c == '(')
            return name[0 .. i].idup.stripSpace;
    return name.idup.stripSpace;
}

private string stripSpace(string text) @safe pure nothrow
{
    size_t start, end = text.length;
    while (start < end && (text[start] == ' ' || text[start] == '\t')) start++;
    while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t')) end--;
    return text[start .. end];
}

/// Which temporal shape a declared type names, or $(D Temporal.none).
enum Temporal : ubyte { none, date, time, naive, zoned }

/// ditto
Temporal temporalKind(const(char)[] dataType) @safe pure
{
    switch (baseType(dataType))
    {
        case "DATE": return Temporal.date;
        case "TIME": return Temporal.time;
        case "TIMESTAMP", "TIMESTAMP_NTZ", "TIMESTAMPNTZ", "DATETIME": return Temporal.naive;
        case "TIMESTAMP_LTZ", "TIMESTAMPLTZ", "TIMESTAMP_TZ", "TIMESTAMPTZ": return Temporal.zoned;
        default: return Temporal.none;
    }
}

/// Whether a declared type holds bytes.
bool isBinaryType(const(char)[] dataType) @safe pure
{
    const name = baseType(dataType);
    return name == "BINARY" || name == "VARBINARY";
}

/// Whether a declared type holds semi-structured data.
bool isVariantType(const(char)[] dataType) @safe pure
{
    switch (baseType(dataType))
    {
        case "VARIANT", "OBJECT", "ARRAY", "MAP", "GEOGRAPHY", "GEOMETRY": return true;
        default: return false;
    }
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    // The point of the module: a D type already says what the literal is.
    assert(toParam(5).literal == "5");
    assert(toParam("007").literal == "'007'");
    assert(toParam(true).literal == "TRUE");
    assert(toParam(false).literal == "FALSE");
    assert(toParam(null).literal == "NULL");
    assert(toParam(-42).literal == "(-42)");
    assert(toParam(cast(long) 9_007_199_254_740_993).literal == "9007199254740993");
}

@safe unittest
{
    // A string is always quoted, so a numeric-looking one keeps its zeros —
    // the case that forces the string-based drivers to quote everything.
    assert(toParam("007").literal == "'007'");
    assert(toParam("").literal == "''");
    assert(toParam("it's").literal == "'it''s'");
    // A backslash escapes in this dialect, so it is doubled on the way in.
    assert(toParam(`a\b`).literal == `'a\\b'`);
    // Which means a hostile value cannot leave its literal.
    assert(toParam("'; DROP TABLE t; --").literal == "'''; DROP TABLE t; --'");
    assert(toParam(`\'; DROP TABLE t; --`).literal == `'\\''; DROP TABLE t; --'`);
}

@safe unittest
{
    // Floats keep a point, so binding 1.0 does not become the integer 1.
    assert(toParam(1.0).literal == "1.0");
    assert(toParam(3.5).literal == "3.5");
    assert(toParam(0.1).literal == "0.1");         // shortest round-tripping form
    assert(toParam(-2.5).literal == "(-2.5)");
    // ...and every finite double reads back as itself.
    foreach (v; [0.1, 1.0 / 3.0, 1e-300, 1e300, 123.456, -0.000001])
    {
        const rendered = toParam(v).literal;
        // A negative is parenthesized; strip that before reading it back.
        const bare = rendered[0] == '(' ? rendered[1 .. $ - 1] : rendered;
        assert(bare.to!double == v, rendered);
    }
}

@safe unittest
{
    import std.math : isNaN;
    // The non-finite doubles, in the spellings engine 0.0.7 actually parses.
    assert(toParam(double.nan).literal == "'NaN'::DOUBLE");
    assert(toParam(double.infinity).literal == "'Infinity'::DOUBLE");
    assert(toParam(-double.infinity).literal == "'-Infinity'::DOUBLE");
}

@safe unittest
{
    import std.typecons : Nullable, nullable;
    // Nullable carries absence without needing a sentinel value, which is what
    // the string-based drivers have to use for the same job.
    Nullable!int empty;
    assert(toParam(empty).literal == "NULL");
    assert(toParam(nullable(7)).literal == "7");
    Nullable!string emptyText;
    assert(toParam(emptyText).literal == "NULL");
    assert(toParam(nullable("x")).literal == "'x'");
}

@safe unittest
{
    // Bytes, both directions.
    assert(toParam(cast(ubyte[]) [0xDE, 0xAD, 0xBE, 0xEF]).literal == "X'DEADBEEF'");
    assert(toParam(cast(ubyte[]) []).literal == "X''");
    assert(bytesToHex([cast(ubyte) 0x00, 0x0F, 0xF0]) == "000FF0");
    assert(hexToBytes("DEADBEEF") == cast(ubyte[]) [0xDE, 0xAD, 0xBE, 0xEF]);
    assert(hexToBytes("deadbeef") == cast(ubyte[]) [0xDE, 0xAD, 0xBE, 0xEF]);
    assert(hexToBytes("") == cast(ubyte[]) []);
}

@safe unittest
{
    import std.exception : assertThrown;
    assertThrown!ValueException(hexToBytes("ABC"));    // odd length
    assertThrown!ValueException(hexToBytes("ZZ"));     // not hex
}

@safe unittest
{
    // Temporals, from D's own date types.
    assert(toParam(Date(2024, 1, 15)).literal == "'2024-01-15'::DATE");
    assert(toParam(TimeOfDay(10, 30, 5)).literal == "'10:30:05'::TIME");
    assert(toParam(DateTime(2024, 1, 15, 10, 30, 5)).literal
           == "'2024-01-15 10:30:05'::TIMESTAMP_NTZ");
}

@safe unittest
{
    // The engine prints an offset as +0100 but parses only +01:00, so a value
    // read out of a result and bound straight back in is repaired on the way.
    assert(colonizeOffset("2024-01-15 10:30:05.000 +0100") == "2024-01-15 10:30:05.000 +01:00");
    assert(colonizeOffset("2024-01-15 10:30:05 -0530") == "2024-01-15 10:30:05 -05:30");
    assert(colonizeOffset("2024-01-15 10:30:05 +01:00") == "2024-01-15 10:30:05 +01:00");
    assert(colonizeOffset("2024-01-15") == "2024-01-15");
    assert(colonizeOffset("") == "");
    assert(Param.ofTimestampTz("2024-01-15 10:30:05.000 +0100").literal
           == "'2024-01-15 10:30:05.000 +01:00'::TIMESTAMP_TZ");
}

@safe unittest
{
    // The explicit constructors, for the cases inference cannot reach.
    assert(Param.ofVariant(`{"k":1}`).literal == `PARSE_JSON('{"k":1}')`);
    assert(Param.raw("CURRENT_TIMESTAMP()").literal == "CURRENT_TIMESTAMP()");
    assert(Param.identifier("my col").literal == `"my col"`);
    assert(Param.ofNumber("42").literal == "42");
    assert(Param.ofNumber("-1.5e10").literal == "(-1.5e10)");
    // Parenthesised like every other negative numeral, or `3-?` bound -5
    // would open a `--` comment.
    assert(Param.ofNumber("-5").literal == "(-5)");
    assert(toParam(BigInt(-5)).literal == "(-5)");
    assert(toParam(BigInt(5)).literal == "5");
    // An explicit Param is never second-guessed by inference.
    assert(toParam(Param.raw("NOW()")).literal == "NOW()");
    assert(toParam(Param.ofText("5")).literal == "'5'");
}

@safe unittest
{
    import std.exception : assertThrown;
    assertThrown!UsageException(Param.ofNumber("abc"));
    assertThrown!UsageException(Param.ofNumber(""));
    assertThrown!UsageException(Param.ofNumber("1e"));
    assertThrown!UsageException(Param.ofNumber("1 OR 1=1"));
}

@safe unittest
{
    // BigInt reaches the digits a long cannot hold — the width a NUMBER(38,0)
    // actually has.
    auto huge = BigInt("12345678901234567890123456789012345678");
    assert(toParam(huge).literal == "12345678901234567890123456789012345678");
}

@safe unittest
{
    // Declared-type helpers.
    assert(baseType("NUMBER(38,0)") == "NUMBER");
    assert(baseType("varchar") == "VARCHAR");
    assert(baseType("  TIMESTAMP_NTZ(9)  ") == "TIMESTAMP_NTZ");
    assert(temporalKind("DATE") == Temporal.date);
    assert(temporalKind("TIME(9)") == Temporal.time);
    assert(temporalKind("TIMESTAMP_NTZ") == Temporal.naive);
    assert(temporalKind("TIMESTAMP_TZ") == Temporal.zoned);
    assert(temporalKind("VARCHAR") == Temporal.none);
    assert(isBinaryType("BINARY") && isBinaryType("varbinary(16)"));
    assert(!isBinaryType("VARCHAR"));
    assert(isVariantType("VARIANT") && isVariantType("OBJECT") && isVariantType("ARRAY"));
    assert(!isVariantType("NUMBER"));
}
