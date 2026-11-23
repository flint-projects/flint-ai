module flint.engine.mcp.stdio_framing_test;

version (Posix)
{
    import core.sys.posix.poll : POLLIN, poll, pollfd;
    import core.sys.posix.unistd : close, pipe, read;
}
else version (Windows)
{
    import core.stdc.stdint : intptr_t;
    import core.sys.windows.winbase : PeekNamedPipe, Sleep;
    import core.sys.windows.windef : DWORD, HANDLE;

    private extern (C) @system nothrow @nogc
    {
        int _pipe(int* descriptors, uint bytes, int mode);
        int _close(int descriptor);
        int _read(int descriptor, void* output, uint count);
        intptr_t _get_osfhandle(int descriptor);
    }

    private alias close = _close;
}
import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.engine.mcp : McpOptions, McpTool, ToolResult;
import flint.engine.mcp.jsonrpc : Identity, decodeEnvelope;
import flint.engine.mcp.operations : Operations;
import flint.engine.mcp.protocol : Headers, Protocol;
import flint.engine.mcp.stdio : sendFrame;

@safe:

private enum payload = 256 * 1024;

private struct Arguments
{
    Text note;
}

private final class LargeReply
{
    @McpTool("large", "Returns a reply larger than a pipe buffer")
    Result!ToolResult run(scope const ref Arguments, ref scope RequestArena arena, ref Context) nothrow @nogc
    {
        enum head = `[{"type":"text","text":"`;
        enum tail = `"}]`;
        const block = arena.allocate(head.length + payload + tail.length, 1);
        if (!block.ok())
            return Result!ToolResult(ToolResult.init, block.error);
        const written = arena.write(block.value, (scope ubyte[] bytes) @safe nothrow @nogc {
            bytes[0 .. head.length] = cast(const(ubyte)[]) head;
            bytes[head.length .. head.length + payload] = 'x';
            bytes[head.length + payload .. $] = cast(const(ubyte)[]) tail;
        });
        if (written != Status.ok)
            return Result!ToolResult(ToolResult.init, Error(written, "fixture output unavailable"));
        return Result!ToolResult(ToolResult(block.value));
    }
}

// SAFETY: The test owns both descriptors of the new pipe.
private bool openPipe(ref int[2] descriptors) @trusted nothrow @nogc
{
    version (Windows)
        return _pipe(descriptors.ptr, 64 * 1024, 0x8000) == 0; // _O_BINARY
    else
        return pipe(descriptors) == 0;
}

// SAFETY: Closes a test-owned descriptor once.
private void closeFile(int descriptor) @trusted nothrow @nogc
{
    close(descriptor);
}

// SAFETY: Bounded poll and read into a test-owned slice.
private long readSome(int descriptor, scope ubyte[] output, int millis) @trusted nothrow @nogc
{
    version (Windows)
    {
        // Anonymous pipes cannot be polled: peek until bytes wait, then read no more than are there.
        auto pipe = cast(HANDLE) _get_osfhandle(descriptor);
        foreach (_; 0 .. millis + 1)
        {
            DWORD waiting;
            if (!PeekNamedPipe(pipe, null, 0, null, &waiting, null))
                return 0;
            if (waiting != 0)
                return _read(descriptor, output.ptr, cast(uint)(waiting < output.length ? waiting : output.length));
            Sleep(1);
        }
        return 0;
    }
    else
    {
        pollfd watch = pollfd(descriptor, POLLIN, 0);
        if (poll(&watch, 1, millis) <= 0)
            return 0;
        return read(descriptor, output.ptr, output.length);
    }
}

private bool waitFor(scope bool delegate() @safe nothrow @nogc ready) nothrow @nogc
{
    foreach (attempt; 0 .. 400)
    {
        if (ready())
            return true;
        waitUntil(Deadline.afterMillis(5));
    }
    return false;
}

/// Drain the pipe, sending `ping` once it falls idle, until the ping frame has arrived.
private size_t drain(int descriptor, scope ubyte[] stream, scope void delegate() @safe ping)
{
    size_t received;
    bool pinged;
    foreach (attempt; 0 .. 2_000)
    {
        const count = readSome(descriptor, stream[received .. $], pinged ? 50 : 5);
        if (count > 0)
            received += cast(size_t) count;
        else if (!pinged)
        {
            ping();
            pinged = true;
        }
        else
            break;
    }
    return received;
}

/// Every line is one complete JSON-RPC envelope, and one of them answers request 8.
private bool framed(scope const(ubyte)[] stream, size_t maximum) nothrow @nogc
{
    size_t start;
    bool answered;
    foreach (index, value; stream)
    {
        if (value != '\n')
            continue;
        const parsed = decodeEnvelope(stream[start .. index], maximum);
        if (!parsed.ok())
            return false;
        answered |= parsed.value.id.present && parsed.value.id.number == 8;
        start = index + 1;
    }
    return start == stream.length && answered;
}

@("a stdio reply that has started is never truncated by per-request cancellation")
unittest
{
    enum maximum = 1024 * 1024;
    McpOptions options;
    options.name = "flint-mcp-unit";
    options.versionString = "1";
    options.maxMessageBytes = maximum;
    options.maxInFlight = 2;
    auto protocol = new Protocol(options);
    assert(protocol.registry.initialize().code == Status.ok);
    auto provider = new LargeReply;
    assert(protocol.registry.add(provider).code == Status.ok);

    int[2] channel;
    assert(openPipe(channel));
    scope (exit)
        closeFile(channel[0]);
    auto compact = new ubyte[maximum + 1];
    Error delegate(scope const(ubyte)[], ref Context) @safe nothrow @nogc output = (
            scope const(ubyte)[] reply, ref Context context) @safe nothrow @nogc {
        return sendFrame(channel[1], -1, reply, compact, context);
    };
    auto operations = new Operations(protocol, maximum, options.maxInFlight, output);
    assert(operations.open().code == Status.ok);

    enum meta = `"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",`
        ~ `"io.modelcontextprotocol/clientCapabilities":{}}`;
    enum call = `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{` ~ meta ~ `,"name":"large","arguments":{}}}`;
    enum ping = `{"jsonrpc":"2.0","id":8,"method":"ping","params":{` ~ meta ~ `}}`;
    Context context;
    const headers = Headers.init;
    const first = operations.submit(cast(const(ubyte)[]) call, headers, context, false, true);
    assert(first.ok());
    // Let the worker fill the pipe and block inside the reply frame before the cancellation.
    assert(waitFor(() => operations.entered(first.value)));
    waitUntil(Deadline.afterMillis(100));
    Identity id;
    id.present = true;
    id.number = 7;
    operations.cancel(id, null);

    auto stream = new ubyte[payload * 2];
    const received = drain(channel[0], stream, () {
        assert(operations.submit(cast(const(ubyte)[]) ping, headers, context, false, true).ok());
    });
    closeFile(channel[1]);
    Context teardown;
    assert(operations.close(teardown).code == Status.ok);
    assert(framed(stream[0 .. received], maximum), "stdio output is not one complete envelope per line");
}
