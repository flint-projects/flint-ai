/// Checked ranges and bounded encoding for the two JSON-RPC bindings.
module flint.mcp.jsonrpc;

import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.serde : DecodeOptions, decodeInto;
import flint.serde.json_visit : JsonMemberName, JsonMemberRangeVisitor, visitJsonArray, visitJsonObjectRanges;
import flint.serde.json_write : JsonWriter;

@safe:
package(flint.mcp):

enum maxMessage = 4 * 1024 * 1024;
enum maxMethod = 128;
enum maxIdentity = 256;
enum maxResource = 1024;

enum parseError = -32_700;
enum invalidRequest = -32_600;
enum methodNotFound = -32_601;
enum invalidParameters = -32_602;
enum internalError = -32_603;
enum headerMismatch = -32_020;
enum missingCapability = -32_021;
enum unsupportedVersion = -32_022;

struct Range
{
    size_t offset;
    size_t length;

    bool present() const pure nothrow @nogc
    {
        return length != 0;
    }

    const(ubyte)[] get(return scope const(ubyte)[] document) const pure nothrow @nogc
    {
        return document[offset .. offset + length];
    }
}

struct Identity
{
    char[maxIdentity] text;
    size_t length;
    long number;
    bool present;
    bool quoted;

    void encode(ref scope JsonWriter result) const scope nothrow @nogc
    {
        if (!present)
            append(result, "null");
        else if (quoted)
            quote(result, text[0 .. length]);
        else
            result.signedNumber(number);
    }

    bool matches(scope const ref Identity other) const scope pure nothrow @nogc
    {
        if (present != other.present || quoted != other.quoted)
            return false;
        return quoted ? text[0 .. length] == other.text[0 .. other.length] : number == other.number;
    }
}

struct Envelope
{
    Identity id;
    char[maxMethod] method;
    size_t methodLength;
    Range params;
    Range result;
    Range fault;

    const(char)[] verb() const return pure nothrow @nogc
    {
        return method[0 .. methodLength];
    }
}

struct Fields
{
    Range protocol;
    Range id;
    Range method;
    Range params;
    Range result;
    Range fault;

    Error field(scope JsonMemberName key, size_t offset, size_t length) nothrow @nogc
    {
        const span = Range(offset, length);
        if (key.isName("jsonrpc"))
            protocol = span;
        else if (key.isName("id"))
            id = span;
        else if (key.isName("method"))
            method = span;
        else if (key.isName("params"))
            params = span;
        else if (key.isName("result"))
            result = span;
        else if (key.isName("error"))
            fault = span;
        return Error.init;
    }
}

nothrow @nogc Error inspect(scope const(ubyte)[] input, scope JsonMemberRangeVisitor visitor, size_t cap = maxMessage)
{
    DecodeOptions limits;
    limits.maxBytes = cap;
    return visitJsonObjectRanges(input, visitor, limits);
}

Result!Envelope decodeEnvelope(scope const(ubyte)[] wire, size_t maximum) nothrow @nogc
{
    Fields fields;
    const decoded = inspect(wire, &fields.field, maximum);
    if (decoded.code != Status.ok)
        return Result!Envelope(Envelope.init, wellFormedBatch(wire, maximum)
                ? malformed("JSON-RPC batches are not supported") : decoded);
    if (!isString(fields.protocol.get(wire), "2.0"))
        return Result!Envelope(Envelope.init, malformed("JSON-RPC version must be 2.0"));
    Envelope value;
    if (fields.id.present())
    {
        const encoded = fields.id.get(wire);
        const unknown = fields.fault.present() && !fields.method.present() && encoded == cast(const(ubyte)[]) "null";
        if (!unknown && !readIdentity(encoded, value.id))
            return Result!Envelope(Envelope.init, malformed("invalid JSON-RPC id"));
    }
    value.params = fields.params;
    value.result = fields.result;
    value.fault = fields.fault;
    const shape = fields.method.present() ? decodeMethod(fields.method.get(wire), value) : checkResponse(value);
    return Result!Envelope(value, shape);
}

private Error decodeMethod(scope const(ubyte)[] wire, ref Envelope value) nothrow @nogc
{
    if (value.result.present() || value.fault.present() || !readString(wire, value.method[],
            value.methodLength) || value.methodLength == 0)
        return malformed("invalid JSON-RPC request");
    return Error.init;
}

private Error checkResponse(scope const ref Envelope value) pure nothrow @nogc
{
    return !value.params.present() && value.result.present() != value.fault.present() ? Error.init
        : malformed("invalid JSON-RPC response");
}

bool readIdentity(scope const(ubyte)[] wire, out Identity identity) nothrow @nogc
{
    if (wire.length == 0)
        return false;
    identity.present = true;
    identity.quoted = wire[0] == '"';
    if (identity.quoted)
        return readString(wire, identity.text[], identity.length);
    RequestArena unused;
    return decodeInto(wire, identity.number, unused).code == Status.ok;
}

bool readString(scope const(ubyte)[] source, scope char[] output, out size_t length) nothrow @nogc
{
    ubyte[maxResource + 8] scratch;
    auto arena = RequestArena(scratch[]);
    Text decoded;
    if (decodeInto(source, decoded, arena).code != Status.ok || decoded.bytes.length > output.length)
        return false;
    length = decoded.bytes.length;
    return arena.read(decoded.bytes, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        output[0 .. bytes.length] = cast(const(char)[]) bytes;
    }) == Status.ok;
}

bool isString(scope const(ubyte)[] wire, scope const(char)[] expected) nothrow @nogc
{
    if (wire.length == expected.length + 2 && wire[0] == '"' && wire[$ - 1] == '"'
            && cast(const(char)[]) wire[1 .. $ - 1] == expected)
        return true;
    char[maxResource] bytes;
    size_t length;
    return readString(wire, bytes[], length) && bytes[0 .. length] == expected;
}

Result!Range member(scope const(ubyte)[] document, scope const(char)[] expected) nothrow @nogc
{
    Range field;
    const checked = inspect(document, (scope JsonMemberName name, size_t offset, size_t length) @safe nothrow @nogc {
        if (name.isName(expected))
            field = Range(offset, length);
        return Error.init;
    });
    return Result!Range(field, checked);
}

bool isObject(scope const(ubyte)[] bytes) nothrow @nogc
{
    Error accept(scope JsonMemberName, size_t, size_t) @safe nothrow @nogc
    {
        return Error.init;
    }

    return inspect(bytes, &accept).code == Status.ok;
}

alias Emit = void delegate(ref scope JsonWriter) @safe nothrow @nogc;

Result!Buffer pack(ref scope RequestArena arena, size_t maximum, scope Emit emit) nothrow @nogc
{
    JsonWriter measure;
    emit(measure);
    if (measure.error.code != Status.ok)
        return Result!Buffer(Buffer.init, measure.error);
    if (measure.length > maximum)
        return Result!Buffer(Buffer.init, Error(Status.resourceExhausted, "MCP envelope exceeds its byte limit"));
    const encoded = arena.allocate(measure.length, 1);
    if (!encoded.ok())
        return encoded;
    Status written;
    const status = arena.write(encoded.value, (scope ubyte[] bytes) @safe nothrow @nogc {
        auto writer = JsonWriter(bytes);
        emit(writer);
        written = writer.error.code;
        if (written == Status.ok && writer.length != bytes.length)
            written = Status.conflict;
    });
    if (status != Status.ok || written != Status.ok)
        return Result!Buffer(Buffer.init, Error(status != Status.ok ? status : written,
                "MCP output could not be written"));
    return encoded;
}

void append(ref scope JsonWriter writer, scope const(char)[] bytes) nothrow @nogc
{
    writer.append(cast(const(ubyte)[]) bytes);
}

void quote(ref scope JsonWriter writer, scope const(char)[] value) nothrow @nogc
{
    writer.stringValue(cast(const(ubyte)[]) value);
}

void writeId(ref scope JsonWriter writer, scope const ref Identity id) nothrow @nogc
{
    append(writer, `{"jsonrpc":"2.0","id":`);
    id.encode(writer);
}

/// A syntactically valid JSON array: a batch, which is valid JSON but not a valid request (-32600).
private bool wellFormedBatch(scope const(ubyte)[] wire, size_t maximum) nothrow @nogc
{
    size_t start;
    while (start < wire.length && (wire[start] == ' ' || wire[start] == '\t' || wire[start] == '\r'
            || wire[start] == '\n'))
        ++start;
    if (start == wire.length || wire[start] != '[')
        return false;
    DecodeOptions limits;
    limits.maxBytes = maximum;
    return visitJsonArray(wire, (scope const(ubyte)[]) @safe nothrow @nogc => Error.init, limits).code == Status.ok;
}

Error malformed(string reason) pure nothrow @nogc
{
    return Error(Status.invalidArgument, reason);
}
