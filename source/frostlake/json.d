/**
 * A JSON reader and string encoder, owned rather than borrowed.
 *
 * Phobos ships $(D std.json), and this does not use it, for one reason that
 * matters to a database driver: $(D std.json) turns every number into a $(D long)
 * or a $(D double) as it parses. The engine sends a `NUMBER(38,0)` as a bare JSON
 * number, and thirty-eight digits fit in neither — so the value would be rounded
 * before any driver code could see it, and no later care could recover it.
 *
 * Here a number keeps the digits it arrived as. $(D JsonValue.text) is that
 * literal, and reading it as a $(D long), a $(D double) or a $(D BigInt) is the
 * caller's explicit choice, made when they know what the column holds.
 *
 * The reader is otherwise strict: trailing content, unterminated strings, bad
 * escapes and lone surrogates are all rejected rather than guessed at.
 */
module frostlake.json;

import std.array : Appender, appender;
import std.format : format;

import frostlake.errors;

/// What a JSON value is.
enum JsonKind : ubyte
{
    null_,   /// `null`
    boolean, /// `true` or `false`
    number,  /// a number, kept as the digits it arrived as
    text,    /// a string, unescaped
    array,   /// `[...]`
    object   /// `{...}`
}

/// One `"key": value` pair. Objects keep their entries in wire order.
struct JsonEntry
{
    string key;
    JsonValue value;
}

/**
 * A parsed JSON value.
 *
 * A default-constructed $(D JsonValue) is $(D JsonKind.null_), which is what
 * makes $(D at) safe to chain: asking a non-object for a member, or an object
 * for a key it has not got, answers a null value rather than throwing. Callers
 * that need to tell "absent" from "present and null" ask $(D has).
 *
 * A parsed document is read-only by convention rather than by qualifier: the
 * accessors that hand back children are unqualified, because a $(D const)
 * $(D JsonValue) could only yield its children through a cast that $(D @safe)
 * rightly refuses. Nothing in this library mutates a parsed value.
 */
struct JsonValue
{
    private JsonKind kind_ = JsonKind.null_;
    private bool boolean_;
    private string text_;
    private JsonValue[] items_;
    private JsonEntry[] entries_;

    /// What this value is.
    @property JsonKind kind() const @safe pure nothrow @nogc { return kind_; }

    @property bool isNull() const @safe pure nothrow @nogc { return kind_ == JsonKind.null_; }
    @property bool isBoolean() const @safe pure nothrow @nogc { return kind_ == JsonKind.boolean; }
    @property bool isNumber() const @safe pure nothrow @nogc { return kind_ == JsonKind.number; }
    @property bool isText() const @safe pure nothrow @nogc { return kind_ == JsonKind.text; }
    @property bool isArray() const @safe pure nothrow @nogc { return kind_ == JsonKind.array; }
    @property bool isObject() const @safe pure nothrow @nogc { return kind_ == JsonKind.object; }

    /**
     * The value as text: a string's contents, a number's literal digits, or
     * `"true"`/`"false"`. Null and the containers answer the empty string.
     *
     * This is the lossless reading of a number — every digit the engine sent,
     * in the order it sent them.
     */
    @property string text() const @safe pure nothrow @nogc
    {
        final switch (kind_)
        {
            case JsonKind.text:
            case JsonKind.number:  return text_;
            case JsonKind.boolean: return boolean_ ? "true" : "false";
            case JsonKind.null_:
            case JsonKind.array:
            case JsonKind.object:  return null;
        }
    }

    /// A boolean's value. Anything else is false.
    @property bool boolean() const @safe pure nothrow @nogc
    {
        return kind_ == JsonKind.boolean && boolean_;
    }

    /// An array's elements, or an empty slice.
    @property JsonValue[] items() @safe pure nothrow @nogc { return items_; }

    /// An object's entries in wire order, or an empty slice.
    @property JsonEntry[] entries() @safe pure nothrow @nogc { return entries_; }

    /// How many elements an array holds, or entries an object holds.
    @property size_t length() const @safe pure nothrow @nogc
    {
        if (kind_ == JsonKind.array) return items_.length;
        if (kind_ == JsonKind.object) return entries_.length;
        return 0;
    }

    /**
     * The member named `key`, or a null value when this is not an object or has
     * no such key. Duplicate keys answer the first, which is the one a
     * streaming reader would have seen first.
     */
    JsonValue at(string key) @safe pure nothrow
    {
        if (kind_ == JsonKind.object)
            foreach (ref entry; entries_)
                if (entry.key == key)
                    return entry.value;
        return JsonValue.init;
    }

    /// The element at `index`, or a null value when there is none.
    JsonValue at(size_t index) @safe pure nothrow
    {
        if (kind_ == JsonKind.array && index < items_.length)
            return items_[index];
        return JsonValue.init;
    }

    /// Whether this object carries `key` at all — `null` counts as present.
    bool has(string key) const @safe pure nothrow @nogc
    {
        if (kind_ != JsonKind.object) return false;
        foreach (ref entry; entries_)
            if (entry.key == key)
                return true;
        return false;
    }

    // ------------------------------------------------------------ builders

    static JsonValue ofNull() @safe pure nothrow { return JsonValue.init; }

    static JsonValue ofBoolean(bool value) @safe pure nothrow
    {
        JsonValue v;
        v.kind_ = JsonKind.boolean;
        v.boolean_ = value;
        return v;
    }

    /// A number carrying `literal` verbatim. The caller owns its well-formedness.
    static JsonValue ofNumber(string literal) @safe pure nothrow
    {
        JsonValue v;
        v.kind_ = JsonKind.number;
        v.text_ = literal;
        return v;
    }

    static JsonValue ofText(string value) @safe pure nothrow
    {
        JsonValue v;
        v.kind_ = JsonKind.text;
        v.text_ = value;
        return v;
    }

    static JsonValue ofArray(JsonValue[] items) @safe pure nothrow
    {
        JsonValue v;
        v.kind_ = JsonKind.array;
        v.items_ = items;
        return v;
    }

    static JsonValue ofObject(JsonEntry[] entries) @safe pure nothrow
    {
        JsonValue v;
        v.kind_ = JsonKind.object;
        v.entries_ = entries;
        return v;
    }
}

/**
 * Parses one JSON document.
 *
 * Throws: $(D UsageException) when `source` is not one well-formed JSON value.
 * The message names the byte offset, because a driver reporting "malformed
 * JSON" without saying where is a driver that cannot be debugged.
 */
JsonValue parseJson(const(char)[] source) @safe pure
{
    auto parser = Parser(source);
    parser.skipSpace();
    auto value = parser.readValue(0);
    parser.skipSpace();
    if (parser.pos != source.length)
        parser.fail("trailing content after the JSON value");
    return value;
}

/// The maximum nesting a document may use, so a hostile one cannot exhaust the stack.
private enum maxDepth = 200;

private struct Parser
{
    const(char)[] source;
    size_t pos;

    this(const(char)[] source) @safe pure nothrow @nogc
    {
        this.source = source;
    }

    void fail(string what) @safe pure
    {
        throw new UsageException(
            format!"the JSON is malformed at offset %s: %s"(pos, what));
    }

    void skipSpace() @safe pure nothrow @nogc
    {
        while (pos < source.length)
        {
            const c = source[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') pos++;
            else break;
        }
    }

    char peek() @safe pure nothrow @nogc
    {
        return pos < source.length ? source[pos] : '\0';
    }

    JsonValue readValue(int depth) @safe pure
    {
        if (depth > maxDepth)
            fail("the JSON nests deeper than this reader will follow");
        if (pos >= source.length)
            fail("the JSON ended where a value was expected");

        switch (source[pos])
        {
            case '{':  return readObject(depth);
            case '[':  return readArray(depth);
            case '"':  return JsonValue.ofText(readString());
            case 't':  expect("true");  return JsonValue.ofBoolean(true);
            case 'f':  expect("false"); return JsonValue.ofBoolean(false);
            case 'n':  expect("null");  return JsonValue.ofNull();
            default:   return JsonValue.ofNumber(readNumber());
        }
    }

    void expect(string word) @safe pure
    {
        if (pos + word.length > source.length || source[pos .. pos + word.length] != word)
            fail(format!"expected `%s`"(word));
        pos += word.length;
    }

    JsonValue readObject(int depth) @safe pure
    {
        pos++; // '{'
        Appender!(JsonEntry[]) entries;
        skipSpace();
        if (peek() == '}') { pos++; return JsonValue.ofObject(entries.data); }
        for (;;)
        {
            skipSpace();
            if (peek() != '"') fail("an object key must be a string");
            const key = readString();
            skipSpace();
            if (peek() != ':') fail("expected `:` after an object key");
            pos++;
            skipSpace();
            entries.put(JsonEntry(key, readValue(depth + 1)));
            skipSpace();
            const c = peek();
            if (c == ',') { pos++; continue; }
            if (c == '}') { pos++; break; }
            fail("expected `,` or `}` in an object");
        }
        return JsonValue.ofObject(entries.data);
    }

    JsonValue readArray(int depth) @safe pure
    {
        pos++; // '['
        Appender!(JsonValue[]) items;
        skipSpace();
        if (peek() == ']') { pos++; return JsonValue.ofArray(items.data); }
        for (;;)
        {
            skipSpace();
            items.put(readValue(depth + 1));
            skipSpace();
            const c = peek();
            if (c == ',') { pos++; continue; }
            if (c == ']') { pos++; break; }
            fail("expected `,` or `]` in an array");
        }
        return JsonValue.ofArray(items.data);
    }

    /// Reads a string literal, resolving escapes. Surrogate pairs become one code point.
    string readString() @safe pure
    {
        pos++; // opening quote
        Appender!(char[]) result;
        for (;;)
        {
            if (pos >= source.length) fail("the string was never closed");
            const c = source[pos];
            if (c == '"') { pos++; break; }
            if (c != '\\')
            {
                // Control characters are illegal unescaped, but the engine is
                // the only writer here and rejecting its output helps nobody;
                // they are passed through as the bytes they are.
                result.put(c);
                pos++;
                continue;
            }
            pos++;
            if (pos >= source.length) fail("the string ended inside an escape");
            const e = source[pos++];
            switch (e)
            {
                case '"':  result.put('"');  break;
                case '\\': result.put('\\'); break;
                case '/':  result.put('/');  break;
                case 'b':  result.put('\b'); break;
                case 'f':  result.put('\f'); break;
                case 'n':  result.put('\n'); break;
                case 'r':  result.put('\r'); break;
                case 't':  result.put('\t'); break;
                case 'u':  putCodePoint(result); break;
                default:   fail(format!"unknown escape `\\%s`"(e)); break;
            }
        }
        return result.data.idup;
    }

    /// Reads `\uXXXX`, joining a surrogate pair into the code point it names.
    void putCodePoint(ref Appender!(char[]) result) @safe pure
    {
        uint value = readHex4();
        if (value >= 0xD800 && value <= 0xDBFF)
        {
            // A high surrogate must be followed by its low half; alone it names
            // no character, and writing it out would produce invalid UTF-8.
            if (pos + 1 < source.length && source[pos] == '\\' && source[pos + 1] == 'u')
            {
                const save = pos;
                pos += 2;
                const low = readHex4();
                if (low >= 0xDC00 && low <= 0xDFFF)
                    value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00);
                else
                {
                    pos = save;
                    fail("a high surrogate is not followed by a low surrogate");
                }
            }
            else
                fail("a high surrogate is not followed by a low surrogate");
        }
        else if (value >= 0xDC00 && value <= 0xDFFF)
            fail("a low surrogate appears without a high surrogate");

        encodeUtf8(result, value);
    }

    uint readHex4() @safe pure
    {
        if (pos + 4 > source.length) fail("a `\\u` escape needs four hex digits");
        uint value = 0;
        foreach (i; 0 .. 4)
        {
            const c = source[pos + i];
            uint digit;
            if (c >= '0' && c <= '9') digit = c - '0';
            else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
            else { fail("a `\\u` escape needs four hex digits"); }
            value = (value << 4) | digit;
        }
        pos += 4;
        return value;
    }

    /**
     * Reads a number and answers its literal text, unparsed.
     *
     * The grammar is checked so that a malformed document is still rejected —
     * what is not done is turning the digits into a machine number, because
     * that is where a `NUMBER(38,0)` would lose its tail.
     */
    string readNumber() @safe pure
    {
        const start = pos;
        if (peek() == '-') pos++;
        if (pos >= source.length) fail("a number needs at least one digit");

        if (peek() == '0') pos++;
        else if (peek() >= '1' && peek() <= '9')
            while (pos < source.length && source[pos] >= '0' && source[pos] <= '9') pos++;
        else
            fail("a number needs at least one digit");

        if (peek() == '.')
        {
            pos++;
            if (!(peek() >= '0' && peek() <= '9')) fail("a decimal point needs a digit after it");
            while (pos < source.length && source[pos] >= '0' && source[pos] <= '9') pos++;
        }
        if (peek() == 'e' || peek() == 'E')
        {
            pos++;
            if (peek() == '+' || peek() == '-') pos++;
            if (!(peek() >= '0' && peek() <= '9')) fail("an exponent needs a digit");
            while (pos < source.length && source[pos] >= '0' && source[pos] <= '9') pos++;
        }
        return source[start .. pos].idup;
    }
}

private void encodeUtf8(ref Appender!(char[]) result, uint code) @safe pure nothrow
{
    if (code < 0x80)
        result.put(cast(char) code);
    else if (code < 0x800)
    {
        result.put(cast(char)(0xC0 | (code >> 6)));
        result.put(cast(char)(0x80 | (code & 0x3F)));
    }
    else if (code < 0x10000)
    {
        result.put(cast(char)(0xE0 | (code >> 12)));
        result.put(cast(char)(0x80 | ((code >> 6) & 0x3F)));
        result.put(cast(char)(0x80 | (code & 0x3F)));
    }
    else
    {
        result.put(cast(char)(0xF0 | (code >> 18)));
        result.put(cast(char)(0x80 | ((code >> 12) & 0x3F)));
        result.put(cast(char)(0x80 | ((code >> 6) & 0x3F)));
        result.put(cast(char)(0x80 | (code & 0x3F)));
    }
}

/**
 * Renders `text` as a JSON string literal, quotes included.
 *
 * UTF-8 passes through as itself — the engine reads UTF-8 and escaping it to
 * ASCII would only make the request bigger. What must be escaped is escaped:
 * quote, backslash, and every C0 control character.
 */
string encodeJsonString(const(char)[] text) @safe pure nothrow
{
    auto result = appender!string();
    result.reserve(text.length + 2);
    result.put('"');
    foreach (char c; text)
    {
        switch (c)
        {
            case '"':  result.put(`\"`);   break;
            case '\\': result.put(`\\`);   break;
            case '\b': result.put(`\b`);   break;
            case '\f': result.put(`\f`);   break;
            case '\n': result.put(`\n`);   break;
            case '\r': result.put(`\r`);   break;
            case '\t': result.put(`\t`);   break;
            default:
                if (c < 0x20)
                {
                    static immutable hex = "0123456789abcdef";
                    result.put(`\u00`);
                    result.put(hex[(c >> 4) & 0xF]);
                    result.put(hex[c & 0xF]);
                }
                else
                    result.put(c);
                break;
        }
    }
    result.put('"');
    return result.data;
}

// ---------------------------------------------------------------- unittests

@safe unittest
{
    // The reason this module exists: thirty-eight digits survive the trip.
    auto doc = parseJson(`{"rows":[[12345678901234567890123456789012345678]]}`);
    auto cell = doc.at("rows").at(0).at(0);
    assert(cell.isNumber);
    assert(cell.text == "12345678901234567890123456789012345678");
}

@safe unittest
{
    // The engine's own answer shape, decoded the way the driver reads it.
    auto doc = parseJson(
        `{"errorMessage":null,"resultSets":[{"columns":[{"dataType":"NUMBER",` ~
        `"name":"A","nullable":false,"precision":1,"scale":0}],"rowCount":1,` ~
        `"rows":[[1]]}],"sessionId":"abc","success":true}`);
    assert(doc.isObject);
    assert(doc.at("success").boolean);
    assert(doc.at("sessionId").text == "abc");
    assert(doc.at("errorMessage").isNull);
    assert(doc.has("errorMessage"));          // present, and null
    assert(!doc.has("nosuchkey"));
    auto set = doc.at("resultSets").at(0);
    assert(set.at("columns").length == 1);
    assert(set.at("columns").at(0).at("name").text == "A");
    assert(set.at("columns").at(0).at("nullable").boolean == false);
    assert(set.at("rows").at(0).at(0).text == "1");
}

@safe unittest
{
    // Chaining through what is not there answers null rather than throwing.
    auto doc = parseJson(`{"a":1}`);
    assert(doc.at("b").isNull);
    assert(doc.at("b").at("c").at(7).isNull);
    assert(doc.at("a").at("b").isNull);       // a number has no members
    assert(doc.at(3).isNull);                 // an object has no elements
}

@safe unittest
{
    // Scalars, containers and whitespace.
    assert(parseJson("  null  ").isNull);
    assert(parseJson("true").boolean);
    assert(parseJson(`""`).text == "");
    assert(parseJson("[]").isArray && parseJson("[]").length == 0);
    assert(parseJson("{}").isObject && parseJson("{}").length == 0);
    assert(parseJson(" [ 1 , 2 ,\n3 ] ").length == 3);
    assert(parseJson(`{"k":[{"n":[[]]}]}`).at("k").at(0).at("n").at(0).isArray);
}

@safe unittest
{
    // Number literals keep their exact spelling — no normalising, no rounding.
    foreach (literal; ["0", "-0", "1", "-1", "3.5", "1e10", "1E+10", "-2.5e-3",
                       "0.0000000000000000000000001", "9007199254740993"])
        assert(parseJson(literal).text == literal, literal);
}

@safe unittest
{
    // Escapes, including a surrogate pair for an astral character.
    assert(parseJson(`"a\"b"`).text == `a"b`);
    assert(parseJson(`"\\"`).text == "\\");
    assert(parseJson(`"\/"`).text == "/");
    assert(parseJson(`"\b\f\n\r\t"`).text == "\b\f\n\r\t");
    assert(parseJson(`"A"`).text == "A");
    assert(parseJson(`"é"`).text == "é");
    assert(parseJson(`"中"`).text == "中");
    assert(parseJson(`"😀"`).text == "\U0001F600");
    // UTF-8 already in the source is left exactly as it is.
    assert(parseJson(`"éx"`).text == "éx");
}

@safe unittest
{
    import std.exception : assertThrown;
    // Malformed documents are refused, not guessed at.
    assertThrown!UsageException(parseJson(""));
    assertThrown!UsageException(parseJson("{"));
    assertThrown!UsageException(parseJson("[1,]"));
    assertThrown!UsageException(parseJson(`{"a" 1}`));
    assertThrown!UsageException(parseJson(`{a:1}`));
    assertThrown!UsageException(parseJson(`"unterminated`));
    assertThrown!UsageException(parseJson(`"\q"`));
    assertThrown!UsageException(parseJson(`"\ud83d"`));      // lone high surrogate
    assertThrown!UsageException(parseJson(`"\ude00"`));      // lone low surrogate
    assertThrown!UsageException(parseJson("01"));            // leading zero
    assertThrown!UsageException(parseJson("1."));
    assertThrown!UsageException(parseJson(".5"));
    assertThrown!UsageException(parseJson("1e"));
    assertThrown!UsageException(parseJson("tru"));
    assertThrown!UsageException(parseJson("1 2"));           // trailing content
}

@safe unittest
{
    import std.array : replicate;
    import std.exception : assertThrown;
    // Nesting is bounded, so a hostile document cannot exhaust the stack.
    auto deep = replicate("[", maxDepth + 5) ~ replicate("]", maxDepth + 5);
    assertThrown!UsageException(parseJson(deep));
    auto fine = replicate("[", 20) ~ replicate("]", 20);
    assert(parseJson(fine).isArray);
}

@safe unittest
{
    // Encoding is the inverse of reading, for everything that must be escaped.
    assert(encodeJsonString("") == `""`);
    assert(encodeJsonString("plain") == `"plain"`);
    assert(encodeJsonString(`say "hi"`) == `"say \"hi\""`);
    assert(encodeJsonString("a\\b") == `"a\\b"`);
    assert(encodeJsonString("line\nbreak") == `"line\nbreak"`);
    // A C0 control becomes a u-escape. Checked by character code, so this
    // test carries no escape sequence of its own to be misread.
    const ctrl = [cast(char) 1];
    const encoded = encodeJsonString(ctrl);
    assert(encoded.length == 8);
    assert(encoded[0] == '"' && encoded[7] == '"');
    assert(encoded[1] == cast(char) 92);        // a backslash
    assert(encoded[2 .. 7] == "u0001");
    assert(parseJson(encoded).text == ctrl);    // and it reads back
    // UTF-8 rides through unescaped, and comes back the same.
    assert(parseJson(encodeJsonString("café \U0001F600")).text == "café \U0001F600");
    // A statement with a quoted identifier survives the round trip intact.
    enum sql = `SELECT "col" FROM t WHERE v = 'a\b' AND w = '` ~ "\n" ~ `'`;
    assert(parseJson(encodeJsonString(sql)).text == sql);
}
