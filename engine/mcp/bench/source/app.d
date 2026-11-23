/// Fixed 100,000-call MCP probe. One executable supplies both owned roles.
module app;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.time : MonoTime, ticksToNSecs;
import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.conc : Context, Deadline;
import flint.engine.mcp : McpClient, McpClientOptions, McpOptions, McpProcessOptions, McpServer,
    McpTool, ToolResult, Transport, registerMcp;
import flint.serde : JsonRequired, encodeJson;
import flint.validate : Size;

@safe:

private enum iterations = 100_000;
private enum payload = "abcdefghijklmnopqrstuvwxyzABCDEF" ~ "abcdefghijklmnopqrstuvwxyzABCDEF"
    ~ "abcdefghijklmnopqrstuvwxyzABCDEF" ~ "abcdefghijklmnopqrstuvwxyzABCDEF";

private string arguments() pure
{
    string input = `{"input":"`;
    foreach (index; 0 .. 8)
        input ~= payload;
    return input ~ `"}`;
}

private struct EchoArgs
{
    @JsonRequired @Size(1024, 1024) Text input;
}

private struct Block
{
    string type = "text";
    Text text;
}

private final class Tools
{
    @McpTool("echo", "Echo a 1 KiB byte payload")
    nothrow @nogc Result!ToolResult echo(scope const ref EchoArgs fields, ref scope RequestArena arena,
            ref Context context)
    {
        Block[1] content;
        content[0].text = fields.input;
        const result = encodeJson(content, arena);
        return result.ok()
            ? Result!ToolResult(ToolResult(result.value)) : Result!ToolResult(ToolResult.init, result.error);
    }
}

private int serve(ushort port)
{
    McpOptions options;
    options.name = "flint-mcp-probe";
    options.versionString = "1";
    options.maxInFlight = 4;
    options.maxMessageBytes = 4096;
    options.acceptLegacy = false;
    if (port)
    {
        options.port = port;
        options.transport = Transport.streamableHttp;
    }
    McpServer server;
    if (server.open(options).code != Status.ok)
        return 2;
    Context context;
    scope (exit)
        server.close(context);
    auto provider = new Tools;
    if (registerMcp(server, provider).code != Status.ok)
        return 3;
    return server.run(context).code == Status.ok ? 0 : 4;
}

private bool call(ref McpClient client, scope const(ubyte)[] input, ref scope RequestArena arena,
        ref Context context, ref ulong checksum) nothrow @nogc
{
    if (arena.reset() != Status.ok)
        return false;
    const result = client.callTool("echo", input, arena, context);
    if (!result.ok() || result.value.isError || result.value.content.length() != 1051)
        return false;
    return arena.read(result.value.content, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        foreach (character; bytes)
            checksum = (checksum ^ character) * 1_099_511_628_211UL;
    }) == Status.ok;
}

private int measure(string endpoint)
{
    McpClientOptions options;
    options.maxMessageBytes = 4096;
    options.acceptLegacy = false;
    Context root;
    auto deadline = root.withDeadline(Deadline.afterMillis(3_900_000));
    McpClient client;
    const opened = endpoint[0] == '/' ? client.connectProcess(McpProcessOptions(endpoint,
            ["stdio"]), options, deadline) : client.connectWith(endpoint, options, deadline);
    if (opened.code != Status.ok)
        return 5;
    scope (exit)
        client.close(root);
    const input = cast(const(ubyte)[]) arguments();
    ubyte[16_384] backing;
    auto arena = RequestArena(backing[]);
    ulong checksum;
    if (!call(client, input, arena, deadline, checksum))
        return 6;
    checksum = 14_695_981_039_346_656_037UL;
    const before = GC.stats().allocatedInCurrentThread;
    const collections = GC.profileStats().numCollections;
    const started = MonoTime.currTime;
    foreach (index; 0 .. iterations)
    {
        if (!call(client, input, arena, deadline, checksum))
            return 7;
    }
    const elapsed = ticksToNSecs(MonoTime.currTime.ticks - started.ticks);
    const gcBytes = GC.stats().allocatedInCurrentThread - before;
    const gcCollections = GC.profileStats().numCollections - collections;
    report(checksum, elapsed, gcBytes, gcCollections);
    return elapsed >= 100_000_000 && gcBytes == 0 && gcCollections == 0 && checksum != 0 ? 0 : 8;
}

// SAFETY: The C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void report(ulong checksum, long elapsed, ulong gcBytes, size_t gcCollections) @trusted nothrow @nogc
{
    printf("calls=%d payload=1024 checksum=%llu elapsed_ns=%lld gc_bytes=%llu gc_collections=%zu\n",
            iterations, checksum, elapsed, gcBytes, gcCollections);
}

/// Parse a decimal TCP port, rejecting empty, non-digit and out-of-range text.
private ushort parsePort(string text)
{
    if (text.length == 0)
        throw new Exception("port is empty");
    uint value;
    foreach (character; text)
    {
        if (character < '0' || character > '9')
            throw new Exception("port is not a decimal number");
        value = value * 10 + (character - '0');
        if (value > ushort.max)
            throw new Exception("port is out of range");
    }
    return cast(ushort) value;
}

int main(string[] argv)
{
    if (argv.length == 2 && argv[1] == "stdio")
        return serve(0);
    if (argv.length == 3 && argv[1] == "http")
        return serve(parsePort(argv[2]));
    if (argv.length == 3 && argv[1] == "measure")
        return measure(argv[2]);
    return 1;
}
