/// Exercise MCP stdio and HTTP against a real bounded typed registry.
module app;

import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.conc : Context, Deadline;
import flint.engine.mcp : McpClient, McpClientOptions, McpOptions, McpProcessOptions, McpResource,
    McpServer, McpTool, ProtocolRevision, ToolResult, Transport, registerMcp;
import flint.serde : JsonRequired, encodeJson;
import flint.validate : Size;
import std.conv : to;
import std.stdio : writeln;

@safe:

private struct EchoInput
{
    @JsonRequired @Size(1, 1024) Text input;
}

private struct Block
{
    string type = "text";
    Text text;
}

private final class Tools
{
    @McpTool("echo", "Echoes bounded UTF-8", true)
    nothrow @nogc Result!ToolResult echo(scope const ref EchoInput args, ref scope RequestArena arena,
            ref Context context)
    {
        Block[1] content;
        content[0].text = args.input;
        const encoded = encodeJson(content, arena);
        return encoded.ok()
            ? Result!ToolResult(ToolResult(encoded.value)) : Result!ToolResult(ToolResult.init, encoded.error);
    }

    @McpTool("fail", "Produces a checked application failure")
    nothrow @nogc Result!ToolResult fail(scope const ref EchoInput args, ref scope RequestArena arena,
            ref Context context)
    {
        return Result!ToolResult(ToolResult.init, Error(Status.conflict, "fixture failure"));
    }

    private uint cancelled;
    private uint completed;

    @McpTool("slow", "Wait for cancellation or a finite deadline")
    nothrow @nogc Result!ToolResult slow(scope const ref EchoInput args, ref scope RequestArena arena,
            ref Context context)
    {
        const end = Deadline.afterMillis(3_000);
        while (Deadline.afterMillis(0).monotonicNanoseconds < end.monotonicNanoseconds)
        {
            if (context.cancelled())
            {
                ++cancelled;
                return Result!ToolResult(ToolResult.init, context.check());
            }
            Thread.sleep(dur!"msecs"(1));
        }
        ++completed;
        return Result!ToolResult(ToolResult.init);
    }

    @McpTool("stats", "Report completed and cancelled fixture work")
    nothrow @nogc Result!ToolResult stats(scope const ref EchoInput args, ref scope RequestArena arena,
            ref Context context)
    {
        static struct Counts
        {
            uint cancelled;
            uint completed;
        }

        const summary = Counts(cancelled, completed);
        const recorded = encodeJson(summary, arena);
        return recorded.ok() ? Result!ToolResult(ToolResult(Buffer.init,
                recorded.value)) : Result!ToolResult(ToolResult.init, recorded.error);
    }

    @McpResource("local://example", "text/plain")
    Result!Buffer example(ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        return arena.copyIn(cast(const(ubyte)[]) "explicit fixture contents");
    }
}

int main(string[] arguments)
{
    if (arguments.length < 3)
        return 2;
    if (arguments[1] == "client")
        return runClient(arguments);

    McpOptions options;
    options.name = "flint-fixture";
    options.versionString = "1.0.0";
    options.maxInFlight = 4;
    options.revision = arguments[2] == "legacy" ? ProtocolRevision.legacy20251125 : ProtocolRevision.modern20260728;
    options.acceptLegacy = arguments[2] != "modern";
    options.allowedOrigins = ["https://approved.example"];
    if (arguments[1] == "http")
    {
        if (arguments.length < 4)
            return 2;
        options.transport = Transport.streamableHttp;
        options.port = to!ushort(arguments[3]);
        if (arguments.length > 4)
            options.address = arguments[4];
    }

    McpServer server;
    const opened = server.open(options);
    if (opened.code != Status.ok)
        return opened.code == Status.permissionDenied ? 42 : 3;
    Context cleanup;
    scope (exit)
        server.close(cleanup);
    auto provider = new Tools;
    if (registerMcp(server, provider).code != Status.ok)
        return 4;
    Context serve;
    const result = server.run(serve);
    return result.code == Status.ok ? 0 : 5;
}

private int runClient(string[] arguments)
{
    if (arguments.length < 4 || arguments.length > 5)
        return 2;
    McpClient client;
    Context root;
    auto context = root.withDeadline(Deadline.afterMillis(8_000));
    const mode = arguments[3];
    const script = arguments.length == 5 ? arguments[4] : null;
    const opened = connectFixture(client, arguments[2], mode, script, context);
    if (opened.code != Status.ok)
    {
        writeln(opened.code, " ", opened.message);
        return 11;
    }
    scope (exit)
        client.close(context);

    ubyte[64 * 1024] memory;
    auto arena = RequestArena(memory[]);
    const echo = checkEcho(client, mode, arena, context);
    if (echo || mode == "bounded-mrtr" || mode == "reject-mrtr" || mode == "reject-headers")
        return echo;
    if (mode != "mrtr" && mode != "headers")
    {
        const checked = checkResourceAndError(client, arena, context);
        if (checked)
            return checked;
    }
    return client.close(context).code == Status.ok ? 0 : 16;
}

private Error connectFixture(ref McpClient client, string endpoint, string mode, string script, ref Context context)
{
    McpClientOptions options;
    options.revision = mode == "legacy" ? ProtocolRevision.legacy20251125 : ProtocolRevision.modern20260728;
    options.acceptLegacy = mode != "modern";
    if (mode == "mrtr")
        options.elicitation = (scope const(ubyte)[] message, ref scope RequestArena arena, ref Context call) {
        return answerFixture(message, arena, call);
    };
    if (mode == "bounded-mrtr")
        options.maxInputRounds = 1;
    if (endpoint[0] != '/')
        return client.connectWith(endpoint, options, context);

    const childMode = mode == "fallback" ? "legacy" : "dual";
    const argv = script.length ? [script, "--stdio", mode] : ["stdio", childMode];
    return client.connectProcess(McpProcessOptions(endpoint, argv, ["FLINT_MCP_FIXTURE=true"]), options, context);
}

private Result!Buffer answerFixture(scope const(ubyte)[], ref scope RequestArena arena, ref Context) nothrow @nogc
{
    return arena.copyIn(cast(const(ubyte)[]) `{"action":"accept","content":{"answer":"explicit"}}`);
}

private int checkEcho(ref McpClient client, string mode, ref scope RequestArena arena, ref Context context)
{
    if (!client.listTools(arena, context).ok())
        return 12;
    enum mirrored = `{"input":"hello","nested":{"region":" padded 世界 "},"enabled":false,"limit":42}`;
    const fields = mode == "headers" ? mirrored : `{"input":"hello"}`;
    const echo = client.callTool("echo", cast(const(ubyte)[]) fields, arena, context);
    switch (mode)
    {
    case "reject-headers":
        return echo.error.code == Status.invalidArgument ? 0 : 19;
    case "bounded-mrtr":
        return echo.error.code == Status.resourceExhausted ? 0 : 17;
    case "reject-mrtr":
        return echo.error.code == Status.unsupported ? 0 : 18;
    default:
        return echo.ok() && !echo.value.isError && contains(arena, echo.value.content, "hello") ? 0 : 13;
    }
}

private int checkResourceAndError(ref McpClient client, ref scope RequestArena arena, ref Context context)
{
    const fails = client.callTool("fail", cast(const(ubyte)[]) `{"input":"hello"}`, arena, context);
    if (!fails.ok() || !fails.value.isError || !contains(arena, fails.value.content, "fixture failure"))
        return 14;
    const resource = client.readResource("local://example", arena, context);
    return resource.ok() && contains(arena, resource.value, "explicit fixture contents") ? 0 : 15;
}

private bool contains(ref scope RequestArena arena, Buffer handle, string expected) nothrow @nogc
{
    bool found;
    const read = arena.read(handle, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        if (bytes.length >= expected.length)
        {
            foreach (index; 0 .. bytes.length - expected.length + 1)
            {
                if (cast(const(char)[]) bytes[index .. index + expected.length] == expected)
                    found = true;
            }
        }
    });
    return read == Status.ok && found;
}
