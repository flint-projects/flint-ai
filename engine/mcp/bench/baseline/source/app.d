/// Direct Web/http and pipe reference with the same 1 KiB transfer and checksum.
module app;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.time : MonoTime, ticksToNSecs;
import flint.arena : Error, RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.http : ClientOptions, HttpClient, HttpMethod, HttpRequestView, HttpStreamField;
import flint.web : Method, Request, RequestContext, Server, ServerOptions, StreamField, StreamMode,
    StreamRoute, StreamToken;
import std.process : ProcessPipes, Redirect, pipeProcess, wait;
import std.stdio : stdin, stdout;

private enum iterations = 100_000;
private enum letters = "abcdefghijklmnopqrstuvwxyzABCDEF";
private enum argumentPrefix = `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"_meta":{`
    ~ `"io.modelcontextprotocol/protocolVersion":"2026-07-28",`
    ~ `"io.modelcontextprotocol/clientInfo":{"name":"flint-mcp","version":"1"},`
    ~ `"io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"input":"`;
private enum argumentSuffix = `"}}}`;
private enum responsePrefix = `{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","isError":false,"content":`;
private enum contentPrefix = `[{"type":"text","text":"`;
private enum contentSuffix = `"}]`;
private enum responseSuffix = `,"_meta":{"io.modelcontextprotocol/serverInfo":{`
    ~ `"name":"flint-mcp-probe","version":"1"}}}}`;
private enum bodyLength = contentPrefix.length + 1024 + contentSuffix.length;
private enum requestLength = argumentPrefix.length + 1024 + argumentSuffix.length;

private string payload() pure
{
    string output;
    foreach (index; 0 .. 32)
        output ~= letters;
    return output;
}

private bool copyResponse(scope const(ubyte)[] request, scope ubyte[] output, out size_t size) @safe nothrow @nogc
{
    if (request.length != requestLength
            || request[0 .. argumentPrefix.length] != cast(const(ubyte)[]) argumentPrefix
            || request[$ - argumentSuffix.length .. $] != cast(const(ubyte)[]) argumentSuffix)
        return false;
    size = responsePrefix.length + bodyLength + responseSuffix.length;
    output[0 .. responsePrefix.length] = cast(const(ubyte)[]) responsePrefix;
    size_t cursor = responsePrefix.length;
    output[cursor .. cursor + contentPrefix.length] = cast(const(ubyte)[]) contentPrefix;
    cursor += contentPrefix.length;
    output[cursor .. cursor + 1024] = request[argumentPrefix.length .. argumentPrefix.length + 1024];
    cursor += 1024;
    output[cursor .. cursor + contentSuffix.length] = cast(const(ubyte)[]) contentSuffix;
    cursor += contentSuffix.length;
    output[cursor .. size] = cast(const(ubyte)[]) responseSuffix;
    return true;
}

private final class Direct
{
    @safe nothrow @nogc Error respond(ref scope Request request, ref scope RequestContext context,
            scope StreamToken stream)
    {
        const source = request.body();
        if (!source.ok())
            return source.error;
        ubyte[4096] encoded;
        size_t length;
        bool valid;
        const read = context.arena.read(source.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            valid = copyResponse(bytes, encoded[], length);
        });
        if (read != Status.ok || !valid)
            return Error(Status.invalidArgument, "reference request did not match its fixed shape");
        auto result = stream.begin(200, [
            StreamField("content-type", "text/event-stream"), StreamField("x-accel-buffering", "no")
        ], context.cancellation);
        if (result.code == Status.ok)
            result = stream.send(cast(const(ubyte)[]) "data: ", context.cancellation);
        if (result.code == Status.ok)
            result = stream.send(encoded[0 .. length], context.cancellation);
        if (result.code == Status.ok)
            result = stream.send(cast(const(ubyte)[]) "\n", context.cancellation);
        if (result.code == Status.ok)
            result = stream.send(cast(const(ubyte)[]) "\n", context.cancellation);
        return result.code == Status.ok ? stream.finish([], context.cancellation) : result;
    }
}

private int serveHttp(ushort port) @safe
{
    ServerOptions limits;
    limits.port = port;
    limits.maxConnectionsPerCore = 6;
    limits.maxStreamsPerConnection = 4;
    limits.maxStreamingRequestBytes = 4096;
    Server server;
    if (server.start(limits).code != Status.ok)
        return 2;
    scope (exit)
        server.shutdown(Deadline.afterMillis(1_000).monotonicNanoseconds);
    auto direct = new Direct;
    if (server.routeStream(StreamRoute(Method.post, "/mcp", StreamMode.response, &direct.respond)).code != Status.ok)
        return 3;
    Context context;
    for (;;)
    {
        if (server.poll(context).code != Status.ok)
            return 4;
    }
}

private int serveStdio()
{
    char[] frame;
    ubyte[4096] encoded;
    while (stdin.readln(frame))
    {
        size_t length;
        if (frame.length != requestLength + 1 || frame[$ - 1] != '\n'
                || !copyResponse(cast(const(ubyte)[]) frame[0 .. $ - 1], encoded[], length))
            return 3;
        encoded[length] = '\n';
        stdout.rawWrite(encoded[0 .. length + 1]);
        stdout.flush();
    }
    return 0;
}

private bool consume(scope const(ubyte)[] actual, size_t prefix, ref ulong checksum) @safe nothrow @nogc
{
    if (actual.length < prefix + responsePrefix.length + bodyLength + responseSuffix.length)
        return false;
    const data = actual[prefix .. $];
    const content = data[responsePrefix.length .. responsePrefix.length + bodyLength];
    if (content[0 .. contentPrefix.length] != cast(const(ubyte)[]) contentPrefix
            || content[$ - contentSuffix.length .. $] != cast(const(ubyte)[]) contentSuffix)
        return false;
    foreach (character; content)
        checksum = (checksum ^ character) * 1_099_511_628_211UL;
    return true;
}

private int measure(string endpoint)
{
    const wire = cast(const(ubyte)[])(argumentPrefix ~ payload() ~ argumentSuffix);
    const pipe = endpoint[0] == '/';
    ProcessPipes child;
    HttpClient http;
    Context root;
    auto deadline = root.withDeadline(Deadline.afterMillis(3_900_000));
    if (pipe)
        child = pipeProcess([endpoint, "stdio"], Redirect.stdin | Redirect.stdout);
    else
    {
        ClientOptions options;
        options.maxConnections = 2;
        options.maxConnectionsPerOrigin = 2;
        options.maxResponseBytes = 69_632;
        if (http.open(options).code != Status.ok)
            return 5;
    }
    scope (exit)
    {
        if (pipe)
        {
            child.stdin.close();
            wait(child.pid);
        }
        else
            http.close();
    }

    ubyte[69_632] memory;
    auto arena = RequestArena(memory[]);
    char[] line;
    ulong checksum;
    bool operation()
    {
        if (pipe)
        {
            child.stdin.rawWrite(wire);
            child.stdin.rawWrite("\n");
            child.stdin.flush();
            return child.stdout.readln(line) && consume(cast(const(ubyte)[]) line, 0, checksum);
        }
        static immutable HttpStreamField[] fields = [
            HttpStreamField("content-type", "application/json"),
            HttpStreamField("accept", "application/json, text/event-stream"),
            HttpStreamField("mcp-protocol-version", "2026-07-28"),
            HttpStreamField("mcp-method", "tools/call"), HttpStreamField("mcp-name", "echo"),
        ];
        arena.reset();
        const request = HttpRequestView(HttpMethod.post, endpoint, fields, wire);
        const received = http.sendView(request, arena, deadline);
        if (!received.ok() || received.value.status != 200)
            return false;
        bool valid;
        const accepted = arena.read(received.value.body, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            valid = consume(bytes, "data: ".length, checksum);
        });
        return accepted == Status.ok && valid;
    }

    if (!operation())
        return 6;
    checksum = 14_695_981_039_346_656_037UL;
    const allocated = GC.stats().allocatedInCurrentThread;
    const collections = GC.profileStats().numCollections;
    const started = MonoTime.currTime;
    foreach (index; 0 .. iterations)
    {
        if (!operation())
            return 7;
    }
    const elapsed = ticksToNSecs(MonoTime.currTime.ticks - started.ticks);
    printf("calls=%d payload=1024 checksum=%llu elapsed_ns=%lld gc_bytes=%llu gc_collections=%zu\n",
            iterations, checksum,
            elapsed, GC.stats().allocatedInCurrentThread - allocated, GC.profileStats().numCollections - collections);
    return checksum != 0 && elapsed >= 100_000_000 ? 0 : 8;
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
        return serveStdio();
    if (argv.length == 3 && argv[1] == "http")
        return serveHttp(parsePort(argv[2]));
    if (argv.length == 3 && argv[1] == "measure")
        return measure(argv[2]);
    return 1;
}
