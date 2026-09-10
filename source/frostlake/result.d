/**
 * What a statement answered with.
 *
 * $(H3 Cells keep the engine's own text)
 *
 * A $(D Value) holds the text the engine sent, unconverted, and every reading
 * of it is an explicit call. That is deliberate: the engine renders temporals,
 * binary and semi-structured values as text and numbers as bare JSON numbers,
 * and a driver that eagerly turned a `NUMBER(38,0)` into a `double`, or a
 * `TIMESTAMP_TZ` into whatever the local zone made of it, would lose
 * information before the caller ever saw it.
 *
 * So `asLong`, `asDouble`, `asDate` and their kin are offered rather than
 * applied. Ask for the reading you want, and it either answers exactly or
 * throws $(D ValueException) — it never quietly rounds.
 */
module frostlake.result;

import std.algorithm : canFind;
import std.array : appender;
import std.bigint : BigInt;
import std.conv : ConvException, to;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.datetime.timezone : SimpleTimeZone, UTC;
import std.format : format;
import std.string : indexOf, startsWith, strip;
import std.typecons : Nullable, nullable;
import std.uni : toLower, toUpper;

import core.time : dur, hnsecs, minutes;

import frostlake.errors;
import frostlake.value : hexToBytes;

/// What the wire said a cell was.
enum ValueKind : ubyte
{
    null_,   /// SQL NULL
    boolean, /// a JSON boolean
    number,  /// a JSON number, kept as its digits
    text     /// a JSON string — which is also how the engine sends temporals,
             /// BINARY (as hex) and VARIANT (as JSON text)
}

/**
 * One cell.
 *
 * $(D text) is always the engine's own rendering; $(D isNull) is the only way a
 * missing value is expressed, so an empty string and NULL never collide.
 */
struct Value
{
    private ValueKind kind_ = ValueKind.null_;
    private string text_;

    @property ValueKind kind() const @safe pure nothrow @nogc { return kind_; }
    @property bool isNull() const @safe pure nothrow @nogc { return kind_ == ValueKind.null_; }

    /// The cell exactly as the engine rendered it. Empty for NULL.
    @property string text() const @safe pure nothrow @nogc { return text_; }

    static Value ofNull() @safe pure nothrow { return Value.init; }

    static Value ofBoolean(bool value) @safe pure nothrow
    {
        return Value(ValueKind.boolean, value ? "true" : "false");
    }

    static Value ofNumber(string digits) @safe pure nothrow
    {
        return Value(ValueKind.number, digits);
    }

    static Value ofText(string value) @safe pure nothrow
    {
        return Value(ValueKind.text, value);
    }

    /// For printing: the cell's text, or `NULL`.
    string toString() const @safe pure nothrow
    {
        return isNull ? "NULL" : text_;
    }

    private void requirePresent(string what) const @safe pure
    {
        if (isNull)
            throw new ValueException("the cell is NULL; it cannot be read as " ~ what);
    }

    /// The cell's text. Throws on NULL, so a missing value is never mistaken
    /// for an empty string.
    string asString() const @safe pure
    {
        requirePresent("a string");
        return text_;
    }

    /// The cell as a boolean. Accepts a JSON boolean and the text the engine
    /// uses when an expression's declared type says otherwise.
    bool asBool() const @safe pure
    {
        requirePresent("a boolean");
        switch (text_.toLower())
        {
            case "true", "t", "yes", "y", "1":  return true;
            case "false", "f", "no", "n", "0":  return false;
            default:
                throw new ValueException(
                    format!"\"%s\" is not a boolean"(text_));
        }
    }

    /// The cell as a 64-bit integer. A fractional value is a mismatch rather
    /// than a silent truncation.
    long asLong() const @safe
    {
        requirePresent("an integer");
        try
            return text_.to!long;
        catch (ConvException) { }
        // A whole number written with a fraction or an exponent still names an
        // integer; anything genuinely fractional does not.
        try
        {
            auto big = asBigInt();
            if (big >= BigInt(long.min) && big <= BigInt(long.max))
                return big.toLong();
        }
        catch (ValueException) { }
        throw new ValueException(format!"\"%s\" is not an integer"(text_));
    }

    /// The cell as a double. Precision beyond a double's is lost here, which is
    /// why it is asked for rather than applied.
    double asDouble() const @safe pure
    {
        requirePresent("a number");
        // The engine spells the non-finite doubles `NaN`, `Infinity` and
        // `-Infinity` — the same spellings this driver binds them with — and
        // `to!double` knows only `nan` and `inf`.
        switch (text_)
        {
            case "NaN", "nan":                             return double.nan;
            case "Infinity", "+Infinity", "Inf", "inf":    return double.infinity;
            case "-Infinity", "-Inf", "-inf":              return -double.infinity;
            default: break;
        }
        try
            return text_.to!double;
        catch (ConvException)
            throw new ValueException(format!"\"%s\" is not a number"(text_));
    }

    /**
     * The cell as an exact integer of any width.
     *
     * This is the reading a `NUMBER(38,0)` needs: thirty-eight digits fit in
     * neither a `long` nor a `double`, and they arrive here intact.
     */
    BigInt asBigInt() const @safe
    {
        import frostlake.value : parseDecimal;

        requirePresent("an integer");
        // An exact integer may still have been written `1E3`, `1.0E7` or
        // `12.000` — Jackson spells a double past 1e7 the middle way.
        BigInt digits;
        long exponent;
        bool negative;
        if (!parseDecimal(text_, digits, exponent, negative))
            throw new ValueException(format!"\"%s\" is not an integer"(text_));
        if (exponent > 100)
            throw new ValueException(format!"\"%s\" is not an integer"(text_));
        for (; exponent < 0; exponent++)
        {
            // Whole only if every digit right of the point is a zero.
            if (digits % 10 != 0)
                throw new ValueException(
                    format!"\"%s\" is not a whole number"(text_));
            digits /= 10;
        }
        if (exponent > 0)
            digits *= BigInt(10) ^^ cast(ulong) exponent;
        return negative ? -digits : digits;
    }

    /// A BINARY cell, decoded from the hex the engine writes it as.
    ubyte[] asBytes() const @safe
    {
        requirePresent("bytes");
        return hexToBytes(text_);
    }

    /// A DATE cell.
    Date asDate() const @safe
    {
        requirePresent("a date");
        try
            return Date.fromISOExtString(text_.strip());
        catch (Exception)
            throw new ValueException(format!"\"%s\" is not a date"(text_));
    }

    /// A TIME cell.
    TimeOfDay asTimeOfDay() const @safe
    {
        requirePresent("a time");
        try
            return TimeOfDay.fromISOExtString(text_.strip());
        catch (Exception)
            throw new ValueException(format!"\"%s\" is not a time"(text_));
    }

    /// A TIMESTAMP_NTZ cell — an instant with no zone attached.
    DateTime asDateTime() const @safe
    {
        requirePresent("a timestamp");
        const parsed = parseStamp(text_);
        return parsed.stamp;
    }

    /**
     * A TIMESTAMP_TZ cell, with the offset the engine printed.
     *
     * A value that names no offset is read as UTC, which is the only reading
     * that does not depend on where the program happens to be running.
     */
    SysTime asSysTime() const @safe
    {
        requirePresent("a timestamp");
        const parsed = parseStamp(text_);
        auto zone = parsed.hasOffset
            ? cast(immutable SimpleTimeZone) new immutable SimpleTimeZone(minutes(parsed.offsetMinutes))
            : UTC();
        auto result = SysTime(parsed.stamp, zone);
        if (parsed.nanos != 0)
            result += hnsecs(parsed.nanos / 100);
        return result;
    }

    /// The reading `T` names, or an empty $(D Nullable) when the cell is NULL.
    Nullable!T opt(T)() const @safe
    {
        if (isNull) return Nullable!T.init;
        static if (is(T == string))        return nullable(asString());
        else static if (is(T == bool))     return nullable(asBool());
        else static if (is(T == long))     return nullable(asLong());
        else static if (is(T == double))   return nullable(asDouble());
        else static if (is(T == BigInt))   return nullable(asBigInt());
        else static if (is(T == Date))     return nullable(asDate());
        else static if (is(T == TimeOfDay)) return nullable(asTimeOfDay());
        else static if (is(T == DateTime)) return nullable(asDateTime());
        else static if (is(T == SysTime))  return nullable(asSysTime());
        else static assert(false, "frostlake: no reading of a cell as " ~ T.stringof);
    }
}

private struct ParsedStamp
{
    DateTime stamp;
    long nanos;
    bool hasOffset;
    int offsetMinutes;
}

/// Reads the timestamp forms the engine prints: `YYYY-MM-DD HH:MM:SS[.frac][ ±HH[:]MM]`.
private ParsedStamp parseStamp(string text) @safe
{
    auto body_ = text.strip();
    ParsedStamp result;

    // The offset, when there is one, is the tail after the last space or a
    // trailing Z. A date alone has neither.
    if (body_.length && (body_[$ - 1] == 'Z' || body_[$ - 1] == 'z'))
    {
        result.hasOffset = true;
        body_ = body_[0 .. $ - 1].strip();
    }
    else if (body_.length > 11)
    {
        // The offset begins at the last `+` or `-` that sits after the date.
        // Every hyphen the date itself carries is at index 10 or less, so
        // scanning back from the end cannot mistake one for a sign — and it
        // finds the offset in both spellings the engine uses, the
        // space-separated `... +0100` and the ISO `...T10:30:05+01:00`.
        foreach_reverse (i; 11 .. body_.length)
        {
            const c = body_[i];
            if (c != '+' && c != '-') continue;
            result.hasOffset = true;
            result.offsetMinutes = parseOffset(body_[i .. $].strip(), text);
            body_ = body_[0 .. i].strip();
            break;
        }
    }

    long nanos;
    const dot = body_.indexOf('.');
    if (dot >= 0)
    {
        auto fraction = body_[dot + 1 .. $];
        body_ = body_[0 .. dot];
        foreach (char c; fraction)
            if (c < '0' || c > '9')
                throw new ValueException(format!"\"%s\" is not a timestamp"(text));
        // Padded to nanoseconds so `.5` is half a second, not five.
        auto padded = fraction.length >= 9 ? fraction[0 .. 9] : fraction ~ "000000000"[0 .. 9 - fraction.length];
        nanos = padded.to!long;
    }
    result.nanos = nanos;

    try
        result.stamp = DateTime.fromISOExtString(body_.length > 10 && body_[10] == ' '
            ? body_[0 .. 10] ~ "T" ~ body_[11 .. $]
            : body_);
    catch (Exception)
        throw new ValueException(format!"\"%s\" is not a timestamp"(text));
    return result;
}

private int parseOffset(string tail, string whole) @safe
{
    auto digits = tail[1 .. $];
    int hours, mins;
    try
    {
        const colon = digits.indexOf(':');
        if (colon >= 0)
        {
            hours = digits[0 .. colon].to!int;
            mins = digits[colon + 1 .. $].to!int;
        }
        else if (digits.length == 4)
        {
            hours = digits[0 .. 2].to!int;
            mins = digits[2 .. 4].to!int;
        }
        else
            hours = digits.to!int;
    }
    catch (ConvException)
        throw new ValueException(format!"\"%s\" is not a timestamp"(whole));
    const total = hours * 60 + mins;
    return tail[0] == '-' ? -total : total;
}

/// One column's metadata, as the engine described it.
struct Column
{
    string name;
    /// The declared type, e.g. `NUMBER(38,0)` or `VARCHAR`.
    string dataType;
    /// Whether the column admits NULL. Meaningless unless $(D nullableKnown).
    bool nullable;
    /// Whether the engine said anything about nullability at all — an engine
    /// that predates the field reports nothing rather than `false`.
    bool nullableKnown;
    long precision;
    long scale;
}

/// One row: its cells, and the columns they line up with.
struct Row
{
    private Value[] cells_;
    private const(Column)[] columns_;

    @property size_t length() const @safe pure nothrow @nogc { return cells_.length; }
    @property Value[] cells() @safe pure nothrow @nogc { return cells_; }

    /// The cell at `index`.
    Value opIndex(size_t index) const @safe pure
    {
        if (index >= cells_.length)
            throw new UsageException(format!
                "this row has %s cell(s); there is no cell %s"(cells_.length, index));
        return cells_[index];
    }

    /// The cell in the column called `name`, matched exactly first and
    /// case-insensitively after.
    Value opIndex(string name) const @safe pure
    {
        const i = indexOfColumn(columns_, name);
        if (i < 0)
            throw new UsageException(format!"this row has no column \"%s\""(name));
        return cells_[i];
    }

    /// Iteration over the cells, so a row works in a `foreach`.
    int opApply(scope int delegate(Value) @safe dg) const @safe
    {
        foreach (cell; cells_)
        {
            const result = dg(cell);
            if (result) return result;
        }
        return 0;
    }

    /// The row keyed by column name. A self-join reporting `ID` twice keeps the
    /// later one, so $(D cells) stays the lossless view.
    Value[string] byName() const @safe pure
    {
        Value[string] result;
        foreach (i, column; columns_)
            if (i < cells_.length)
                result[column.name] = cells_[i];
        return result;
    }
}

private ptrdiff_t indexOfColumn(const(Column)[] columns, string name) @safe pure
{
    foreach (i, column; columns)
        if (column.name == name)
            return i;
    const folded = name.toUpper();
    foreach (i, column; columns)
        if (column.name.toUpper() == folded)
            return i;
    return -1;
}

/**
 * One statement's answer: its columns, its rows, and — for DML — how many rows
 * it affected.
 */
struct Result
{
    private Column[] columns_;
    private Row[] rows_;
    private long updateCount_ = -1;
    private long[string] counters_;

    static Result make(Column[] columns, Value[][] cells,
                       long updateCount = -1, long[string] counters = null) @safe pure
    {
        Result result;
        result.columns_ = columns;
        result.updateCount_ = updateCount;
        result.counters_ = counters;
        auto rows = appender!(Row[]);
        foreach (row; cells)
            rows.put(Row(row, columns));
        result.rows_ = rows.data;
        return result;
    }

    @property const(Column)[] columns() const @safe pure nothrow @nogc { return columns_; }
    @property Row[] rows() @safe pure nothrow @nogc { return rows_; }

    /// The column names, in order.
    @property string[] columnNames() const @safe pure nothrow
    {
        auto result = appender!(string[]);
        foreach (column; columns_) result.put(column.name);
        return result.data;
    }

    /// Rows returned, or rows affected for a DML statement.
    @property size_t rowCount() const @safe pure nothrow @nogc
    {
        return updateCount_ >= 0 ? cast(size_t) updateCount_ : rows_.length;
    }

    /// Rows affected by DML, or `-1` when the statement returned data.
    @property long updateCount() const @safe pure nothrow @nogc { return updateCount_; }

    /// Whether this came from a DML statement rather than a query.
    @property bool isUpdate() const @safe pure nothrow @nogc { return updateCount_ >= 0; }

    /// The raw `number of rows ...` counters behind $(D updateCount), keyed by
    /// the name the engine gave each one.
    @property const(long[string]) counters() const @safe pure nothrow @nogc { return counters_; }

    /**
     * The first cell of the first row — what a single-value query
     * (`SELECT COUNT(*)`, `SELECT CURRENT_VERSION()`) is after.
     *
     * A result with no rows answers a NULL $(D Value), so a caller can ask
     * without checking first.
     */
    @property Value value() const @safe pure nothrow
    {
        if (rows_.length == 0 || rows_[0].length == 0) return Value.ofNull();
        return rows_[0].cells_[0];
    }

    /// The position of a column, or `-1` when there is none. Matched exactly
    /// first and case-insensitively after.
    ptrdiff_t columnIndex(string name) const @safe pure
    {
        return indexOfColumn(columns_, name);
    }

    /// One column's metadata, by name.
    Column column(string name) const @safe pure
    {
        const i = columnIndex(name);
        if (i < 0)
            throw new UsageException(format!"this result has no column \"%s\""(name));
        return columns_[i];
    }

    /// One cell, by row number and column name.
    Value cell(size_t row, string name) const @safe pure
    {
        if (row >= rows_.length)
            throw new UsageException(format!
                "this result has %s row(s); there is no row %s"(rows_.length, row));
        return rows_[row][name];
    }

    /// ditto
    Value cell(size_t row, size_t column) const @safe pure
    {
        if (row >= rows_.length)
            throw new UsageException(format!
                "this result has %s row(s); there is no row %s"(rows_.length, row));
        return rows_[row][column];
    }

    /// Iteration over the rows, so a result works in a `foreach`.
    int opApply(scope int delegate(Row) @safe dg) @safe
    {
        foreach (row; rows_)
        {
            const result = dg(row);
            if (result) return result;
        }
        return 0;
    }
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    // NULL is its own thing, never an empty string.
    auto n = Value.ofNull();
    assert(n.isNull && n.kind == ValueKind.null_);
    assert(n.text == "");
    assert(n.toString() == "NULL");

    auto empty = Value.ofText("");
    assert(!empty.isNull);
    assert(empty.asString() == "");
}

@safe unittest
{
    import std.exception : assertThrown;
    // Reading a NULL as anything is refused rather than defaulted.
    auto n = Value.ofNull();
    assertThrown!ValueException(n.asString());
    assertThrown!ValueException(n.asLong());
    assertThrown!ValueException(n.asDouble());
    assertThrown!ValueException(n.asBool());
    assert(n.opt!long.isNull);
    assert(n.opt!string.isNull);
}

@safe unittest
{
    // Numbers, read the way the caller asks for them.
    auto v = Value.ofNumber("42");
    assert(v.asLong == 42);
    assert(v.asDouble == 42.0);
    assert(v.asString == "42");
    assert(v.asBigInt == BigInt(42));
    assert(v.opt!long.get == 42);

    assert(Value.ofNumber("-7").asLong == -7);
    assert(Value.ofNumber("3.5").asDouble == 3.5);
    assert(Value.ofNumber("12.000").asLong == 12);     // whole, written with a fraction
}

@safe unittest
{
    import std.exception : assertThrown;
    // The reason the JSON reader keeps digits: this width has no machine type.
    auto wide = Value.ofNumber("12345678901234567890123456789012345678");
    assert(wide.asBigInt == BigInt("12345678901234567890123456789012345678"));
    assert(wide.asString == "12345678901234567890123456789012345678");
    // Asking for a long is refused rather than silently truncated.
    assertThrown!ValueException(wide.asLong());
    // A genuinely fractional value is not an integer.
    assertThrown!ValueException(Value.ofNumber("3.5").asLong());
    assertThrown!ValueException(Value.ofNumber("3.5").asBigInt());
}

@safe unittest
{
    // Booleans arrive both as JSON booleans and as text, because a boolean
    // expression can declare its column VARCHAR and still send `true`.
    assert(Value.ofBoolean(true).asBool);
    assert(!Value.ofBoolean(false).asBool);
    assert(Value.ofText("true").asBool);
    assert(Value.ofText("TRUE").asBool);
    assert(!Value.ofText("false").asBool);
    assert(Value.ofBoolean(true).text == "true");
}

@safe unittest
{
    import std.exception : assertThrown;
    assertThrown!ValueException(Value.ofText("maybe").asBool());
    assertThrown!ValueException(Value.ofText("abc").asLong());
    assertThrown!ValueException(Value.ofText("abc").asDouble());
}

@safe unittest
{
    // NaN really does arrive as the JSON string "NaN", even for a DOUBLE column.
    import std.math : isNaN;
    auto nan = Value.ofText("NaN");
    assert(nan.asDouble.isNaN);
    assert(nan.text == "NaN");
}

@safe unittest
{
    // Temporals, parsed only when asked for.
    assert(Value.ofText("2024-01-15").asDate == Date(2024, 1, 15));
    assert(Value.ofText("10:30:05").asTimeOfDay == TimeOfDay(10, 30, 5));
    assert(Value.ofText("2024-01-15 10:30:05").asDateTime == DateTime(2024, 1, 15, 10, 30, 5));
    assert(Value.ofText("2024-01-15 10:30:05.123").asDateTime == DateTime(2024, 1, 15, 10, 30, 5));
}

@safe unittest
{
    // A zoned stamp keeps the offset the engine printed, in either spelling.
    auto zoned = Value.ofText("2024-01-15 10:30:05.000 +0100").asSysTime();
    assert(zoned.year == 2024 && zoned.hour == 10);
    assert(zoned.utcOffset == minutes(60));

    auto colon = Value.ofText("2024-01-15 10:30:05 +01:00").asSysTime();
    assert(colon.utcOffset == minutes(60));

    auto negative = Value.ofText("2024-01-15 10:30:05 -0530").asSysTime();
    assert(negative.utcOffset == minutes(-330));

    // No offset means UTC, rather than wherever this program happens to run.
    auto naive = Value.ofText("2024-01-15 10:30:05").asSysTime();
    assert(naive.utcOffset == minutes(0));
}

@safe unittest
{
    import std.exception : assertThrown;
    assertThrown!ValueException(Value.ofText("not-a-date").asDate());
    assertThrown!ValueException(Value.ofText("2024-13-45").asDate());
    assertThrown!ValueException(Value.ofText("nope").asDateTime());
}

@safe unittest
{
    // BINARY arrives as hex.
    assert(Value.ofText("DEADBEEF").asBytes == cast(ubyte[]) [0xDE, 0xAD, 0xBE, 0xEF]);
}

@safe unittest
{
    // A result, read by position and by name.
    auto columns = [
        Column("ID", "NUMBER", false, true, 38, 0),
        Column("NAME", "VARCHAR", true, true, 0, 0),
    ];
    auto result = Result.make(columns, [
        [Value.ofNumber("1"), Value.ofText("Ada")],
        [Value.ofNumber("2"), Value.ofNull()],
    ]);

    assert(result.rowCount == 2);
    assert(!result.isUpdate);
    assert(result.updateCount == -1);
    assert(result.columnNames == ["ID", "NAME"]);
    assert(result.value.asLong == 1);

    assert(result.rows[0][0].asLong == 1);
    assert(result.rows[0]["NAME"].asString == "Ada");
    assert(result.rows[0]["name"].asString == "Ada");    // case-insensitive fallback
    assert(result.rows[1]["NAME"].isNull);
    assert(result.cell(1, "ID").asLong == 2);
    assert(result.cell(0, 1).asString == "Ada");

    assert(result.columnIndex("ID") == 0);
    assert(result.columnIndex("nope") == -1);
    assert(result.column("NAME").dataType == "VARCHAR");
    assert(result.rows[0].byName["ID"].asLong == 1);
}

@safe unittest
{
    import std.exception : assertThrown;
    auto result = Result.make([Column("A", "NUMBER")], [[Value.ofNumber("1")]]);
    assertThrown!UsageException(result.rows[0][5]);
    assertThrown!UsageException(result.rows[0]["nope"]);
    assertThrown!UsageException(result.cell(9, "A"));
    assertThrown!UsageException(result.column("nope"));
}

@safe unittest
{
    // An empty result answers without anyone having to check first.
    auto empty = Result.make([], []);
    assert(empty.rowCount == 0);
    assert(empty.value.isNull);
    assert(empty.columnNames.length == 0);
}

@safe unittest
{
    // A DML answer reports its count, and keeps the grid it derived it from.
    long[string] counters = ["number of rows inserted": 2L];
    auto result = Result.make([Column("number of rows inserted", "NUMBER")],
                              [[Value.ofNumber("2")]], 2, counters);
    assert(result.isUpdate);
    assert(result.updateCount == 2);
    assert(result.rowCount == 2);
    assert(result.counters["number of rows inserted"] == 2);
    assert(result.rows.length == 1);            // the grid is still there
}

@safe unittest
{
    // Both containers iterate.
    auto result = Result.make([Column("A", "NUMBER")],
                              [[Value.ofNumber("1")], [Value.ofNumber("2")]]);
    long total;
    foreach (row; result)
        foreach (cell; row)
            total += cell.asLong;
    assert(total == 3);
}

@safe unittest
{
    import std.math : isNaN, isInfinity;

    // Whole numbers in the spellings the engine uses.
    assert(Value.ofNumber("1E3").asLong == 1000);
    assert(Value.ofNumber("1.0E7").asLong == 10_000_000);
    assert(Value.ofNumber("1e2").asBigInt == BigInt(100));
    assert(Value.ofNumber("-12.000").asLong == -12);
    assert(Value.ofNumber("12345678901234567890E2").asBigInt == BigInt("1234567890123456789000"));
    bool refused;
    try { Value.ofNumber("1.5E1").asLong; } catch (ValueException) { refused = false; }
    assert(Value.ofNumber("1.5E1").asLong == 15);
    try { Value.ofNumber("1.25E1").asLong; refused = false; } catch (ValueException) { refused = true; }
    assert(refused);

    // The engine's own non-finite spellings.
    assert(Value.ofNumber("Infinity").asDouble.isInfinity);
    assert(Value.ofNumber("-Infinity").asDouble < 0);
    assert(Value.ofNumber("NaN").asDouble.isNaN);
}
