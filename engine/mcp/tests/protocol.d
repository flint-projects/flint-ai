module flint.mcp.protocol_test;

import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.conc : Context;
import flint.mcp : McpOptions, McpServer, McpTool, ToolResult, registerMcp;
import flint.mcp.header_values : encodeHeader, matchesHeader;
import flint.mcp.jsonrpc : decodeEnvelope, isString, member;
import flint.mcp.params : EncodedField, ParamRules, maximumHeaders;
import flint.mcp.protocol : Headers, Protocol;
import flint.serde : JsonRequired;

@safe:

private struct Args
{
    @JsonRequired Text input;
}

private final class Provider(size_t index)
{
    @McpTool("tool-" ~ index.stringof, "Pagination fixture")
    Result!ToolResult run(scope const ref Args input, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        return Result!ToolResult(ToolResult.init);
    }
}

unittest
{
    McpOptions options;
    options.name = "flint-mcp-unit";
    options.versionString = "1";
    auto first = new Protocol(options);
    auto second = new Protocol(options);
    assert(first.registry.initialize().code == Status.ok);
    assert(second.registry.initialize().code == Status.ok);
    static foreach (index; 0 .. 19)
    {
        {
            auto provider = new Provider!index;
            assert(first.registry.add(provider).code == Status.ok);
            assert(second.registry.add(provider).code == Status.ok);
        }
    }
    auto duplicate = new Provider!0;
    assert(first.registry.add(duplicate).code == Status.conflict);
    assert(first.registry.count(true) == 19);
    assert(first.registry.position("t0000000000000000000000000000000016", true) == size_t.max);

    ubyte[64 * 1024] requestMemory;
    ubyte[64 * 1024] responseMemory;
    auto work = RequestArena(requestMemory[]);
    auto output = RequestArena(responseMemory[]);
    Context context;
    const headers = Headers.init;
    enum list = `{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{`;
    enum meta = `"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",`
        ~ `"io.modelcontextprotocol/clientCapabilities":{}}`;
    const request = cast(const(ubyte)[])(list ~ meta ~ "}}");
    const response = first.dispatch(request, headers, work, output, context);
    assert(response.status == 200 && response.error.code == Status.ok);

    size_t length;
    char[256] joined;
    const status = output.read(response.body, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        const decoded = decodeEnvelope(bytes, 65_536);
        assert(decoded.ok() && decoded.value.id.text[0 .. decoded.value.id.length] == "list");
        const wire = decoded.value.result.get(bytes);
        const cursor = member(wire, "nextCursor");
        const literal = cursor.value.get(wire);
        assert(cursor.ok() && literal.length > 2);
        length = literal[1 .. $ - 1].length;
        joined[0 .. length] = cast(const(char)[]) literal[1 .. $ - 1];
    });
    assert(status == Status.ok);
    assert(first.registry.position(joined[0 .. length], true) == 16);
    assert(first.registry.position(joined[0 .. length], false) == size_t.max);
    assert(second.registry.position(joined[0 .. length], true) == size_t.max);

    string page = list ~ meta ~ `,"cursor":"` ~ joined[0 .. length].idup ~ `"}}`;
    work.reset();
    output.reset();
    assert(first.dispatch(cast(const(ubyte)[]) page, headers, work, output, context).status == 200);
    work.reset();
    output.reset();
    assert(second.dispatch(cast(const(ubyte)[]) page, headers, work, output, context).status == 400);
}

unittest
{
    char[64] encoded;
    size_t length;
    assert(encodeHeader(" padded ", encoded[], length));
    assert(encoded[0 .. length] == "=?base64?IHBhZGRlZCA=?=");
    assert(matchesHeader(encoded[0 .. length], " padded "));
    assert(matchesHeader("=?base64?WA==?=", "X"));
    assert(!matchesHeader("=?base64?WB==?=", "X"));
    assert(!matchesHeader("=?base64?W===?=", "X"));
    assert(!matchesHeader(" plain ", " plain "));
    assert(encodeHeader("=?base64?literal?=", encoded[], length));
    assert(matchesHeader(encoded[0 .. length], "=?base64?literal?="));

    ParamRules rules;
    const schema = cast(const(ubyte)[]) `{"type":"object","properties":{
        "flags":{"properties":{"region":{"type":"string","x-mcp-header":"Region"}}},
        "enabled":{"type":"boolean","x-mcp-header":"Enabled"},
        "limit":{"type":"integer","x-mcp-header":"Limit"}}}`;
    assert(rules.readSchema(schema).code == Status.ok);
    EncodedField[maximumHeaders] values;
    const arguments = cast(const(ubyte)[]) `{"flags":{"region":"hello\n世界"},"enabled":false,"limit":42}`;
    assert(rules.apply(arguments, values[], length).code == Status.ok && length == 3);
    assert(values[0].name[0 .. values[0].nameLength] == "Mcp-Param-Region");
    assert(matchesHeader(values[0].value[0 .. values[0].valueLength], "hello\n世界"));
    assert(values[1].value[0 .. values[1].valueLength] == "false");
    assert(values[2].value[0 .. values[2].valueLength] == "42");
    assert(rules.apply(cast(const(ubyte)[]) `{"limit":9007199254740992}`, values[], length)
            .code == Status.invalidArgument);

    const duplicate = cast(const(ubyte)[]) `{"properties":{"a":{"type":"string","x-mcp-header":"A"},
        "b":{"type":"boolean","x-mcp-header":"a"}}}`;
    assert(rules.readSchema(duplicate).code == Status.invalidArgument);
    const hidden = cast(const(ubyte)[]) `{"properties":{"a":{"items":{"type":"string","x-mcp-header":"A"}}}}`;
    assert(rules.readSchema(hidden).code == Status.invalidArgument);
}

unittest
{
    static immutable string[] invalid = [
        "[]", "{}", "{", `{"jsonrpc":"2.0","id":null,"method":"tools/list"}`,
        `{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}`,
        `{"jsonrpc":"2.0","id":1,"method":"tools/list","meth\u006fd":"resources/list"}`,
        `{"jsonrpc":"2.0","id":1,"method":"tools/list","result":{}}`,
        `{"jsonrpc":"2.0","id":"\udc00","method":"tools/list"}`
    ];
    foreach (wire; invalid)
        assert(!decodeEnvelope(cast(const(ubyte)[]) wire, 4_194_304).ok());
}

private struct Sized
{
    import flint.validate : Size;

    @JsonRequired @Size(1, 16) Text input;
}

private final class Counting
{
    uint invoked;

    @McpTool("count", "Counts invocations")
    Result!ToolResult run(scope const ref Sized input, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        ++invoked;
        return Result!ToolResult(ToolResult.init);
    }

    @McpTool("broken", "Reports an application failure")
    Result!ToolResult broken(scope const ref Sized, ref scope RequestArena, ref Context) nothrow @nogc
    {
        ++invoked;
        return Result!ToolResult(ToolResult.init, Error(Status.conflict, "application failure"));
    }
}

private enum unitMeta = `"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",`
    ~ `"io.modelcontextprotocol/clientCapabilities":{}}`;

private bool replyHas(ref scope RequestArena output, Buffer body, scope const(char)[] needle) nothrow @nogc
{
    bool found;
    const status = output.read(body, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        const text = cast(const(char)[]) bytes;
        if (text.length >= needle.length)
            foreach (index; 0 .. text.length - needle.length + 1)
                found |= text[index .. index + needle.length] == needle;
    });
    return status == Status.ok && found;
}

@("tool_errors: protocol faults use JSON-RPC errors and never run tool code; tool failures set isError")
unittest
{
    McpOptions options;
    options.name = "flint-mcp-unit";
    options.versionString = "1";
    auto protocol = new Protocol(options);
    assert(protocol.registry.initialize().code == Status.ok);
    auto tools = new Counting;
    assert(protocol.registry.add(tools).code == Status.ok);
    ubyte[16 * 1024] requestMemory;
    ubyte[16 * 1024] responseMemory;
    auto work = RequestArena(requestMemory[]);
    auto output = RequestArena(responseMemory[]);
    Context context;
    const headers = Headers.init;
    enum call = `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{` ~ unitMeta;
    static struct Case
    {
        string wire;
        ushort status;
        string code;
    }

    static immutable Case[] faults = [
        Case(call ~ `,"name":"count","arguments":{}}}`, 400, `"code":-32602`),
        Case(call ~ `,"name":"count","arguments":{"input":7}}}`, 400, `"code":-32602`),
        Case(call ~ `,"name":"count","arguments":{"input":""}}}`, 400, `"code":-32602`),
        Case(call ~ `,"name":"count","arguments":{"input":"seventeen-bytes!!"}}}`, 400,
                `"code":-32602`),
        Case(call ~ `,"name":"count","arguments":"input"}}`, 400, `"code":-32602`),
        Case(call ~ `,"name":"absent","arguments":{"input":"x"}}}`, 400, `"code":-32602`),
        Case(call ~ `,"arguments":{"input":"x"}}}`, 400, `"code":-32602`),
        Case(`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"count","arguments":{"input":"x"}}}`,
                400, `"code":-32602`),
        Case(`{"jsonrpc":"2.0","id":5,"method":"tools/unknown","params":{` ~ unitMeta ~ `}}`, 404, `"code":-32601`),
        Case(call ~ `,"name":"count","arguments":{"input":"x"`, 400, `"code":-32700`),
        // Batches are refused by both pinned revisions: a well-formed batch is valid JSON but not a
        // valid request (-32600), while a malformed array stays a parse error (-32700).
        Case(`[` ~ call ~ `,"name":"count","arguments":{"input":"x"}}}]`, 400, `"code":-32600`),
        Case(` [` ~ call ~ `,"name":"count","arguments":{"input":"x"}}},` ~ call ~ `,"name":"count","arguments":{}}}]`,
                400, `"code":-32600`),
        Case(`[` ~ call ~ `,"name":"count","arguments":{"input":"x"}}}`, 400, `"code":-32700`),
        Case(`[]`, 400, `"code":-32600`),
    ];
    foreach (fault; faults)
    {
        work.reset();
        output.reset();
        const reply = protocol.dispatch(cast(const(ubyte)[]) fault.wire, headers, work, output, context);
        assert(reply.status == fault.status, fault.wire);
        assert(replyHas(output, reply.body, fault.code), fault.wire);
        assert(tools.invoked == 0, fault.wire);
    }

    work.reset();
    output.reset();
    const valid = protocol.dispatch(cast(const(ubyte)[])(call ~ `,"name":"count","arguments":{"input":"x"}}}`),
            headers, work, output, context);
    assert(valid.status == 200 && replyHas(output, valid.body, `"isError":false`) && tools.invoked == 1);
    work.reset();
    output.reset();
    const failed = protocol.dispatch(cast(const(ubyte)[])(call ~ `,"name":"broken","arguments":{"input":"x"}}}`),
            headers, work, output, context);
    assert(failed.status == 200 && replyHas(output, failed.body, `"isError":true`));
    assert(replyHas(output, failed.body, "application failure") && !replyHas(output, failed.body, `"error":`));
    assert(tools.invoked == 2);
}

@("registry_pagination: following every cursor lists each registered tool exactly once")
unittest
{
    McpOptions options;
    options.name = "flint-mcp-unit";
    options.versionString = "1";
    auto protocol = new Protocol(options);
    assert(protocol.registry.initialize().code == Status.ok);
    static foreach (index; 0 .. 37)
    {
        {
            auto provider = new Provider!index;
            assert(protocol.registry.add(provider).code == Status.ok);
        }
    }
    ubyte[64 * 1024] requestMemory;
    ubyte[64 * 1024] responseMemory;
    auto work = RequestArena(requestMemory[]);
    auto output = RequestArena(responseMemory[]);
    Context context;
    const headers = Headers.init;
    uint[37] seen;
    char[64] cursor;
    size_t cursorLength;
    uint pages;
    for (bool more = true; more; ++pages)
    {
        assert(pages < 10, "pagination did not terminate");
        work.reset();
        output.reset();
        string page = `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{` ~ unitMeta;
        if (pages)
            page ~= `,"cursor":"` ~ cursor[0 .. cursorLength].idup ~ `"`;
        page ~= "}}";
        const reply = protocol.dispatch(cast(const(ubyte)[]) page, headers, work, output, context);
        assert(reply.status == 200 && reply.error.code == Status.ok);
        more = false;
        const status = output.read(reply.body, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            const decoded = decodeEnvelope(bytes, 65_536);
            assert(decoded.ok());
            const wire = cast(const(char)[]) decoded.value.result.get(bytes);
            enum key = `"name":"tool-`;
            foreach (after; key.length .. wire.length + 1)
            {
                if (wire[after - key.length .. after] != key)
                    continue;
                size_t end = after;
                uint number;
                while (wire[end] >= '0' && wire[end] <= '9')
                    number = number * 10 + (wire[end++] - '0');
                assert(number < seen.length);
                ++seen[number];
            }
            const next = member(cast(const(ubyte)[]) wire, "nextCursor");
            if (next.ok())
            {
                const literal = next.value.get(cast(const(ubyte)[]) wire);
                if (literal.length > 2 && literal[0] == '"')
                {
                    const inner = cast(const(char)[]) literal[1 .. $ - 1];
                    cursorLength = inner.length;
                    cursor[0 .. cursorLength] = inner;
                    more = true;
                }
            }
        });
        assert(status == Status.ok);
    }
    assert(pages >= 3, "37 tools must span several pages");
    foreach (count; seen)
        assert(count == 1);
}
