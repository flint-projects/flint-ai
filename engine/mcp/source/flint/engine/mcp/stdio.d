/// Bounded newline framing and MCP stdio server ownership.
module flint.engine.mcp.stdio;

import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.engine.mcp.jsonrpc : Identity, decodeEnvelope;
import flint.engine.mcp.operations : Operations, cancellation;
import flint.engine.mcp.protocol : Headers, Protocol;
import flint.engine.mcp.sys.stdio : readPipe, writePipe;
import flint.engine.mcp.sys.storage : releaseStorage, reserveStorage;
import flint.engine.mcp.types : McpOptions;

@safe:
package(flint.engine.mcp):

/// A timeout may interrupt one read without discarding its partial frame.
struct LineReader
{
    private ubyte[8192] bytes;
    private size_t first;
    private size_t last;
    private size_t used;
    private bool tooLong;

    Result!size_t receive(int file, int diagnostic, scope ubyte[] line, ref scope Context context) scope nothrow @nogc
    {
        for (;;)
        {
            while (first != last)
            {
                const current = bytes[first++];
                if (current == '\n')
                {
                    const over = tooLong;
                    auto length = used;
                    tooLong = false;
                    used = 0;
                    if (over)
                        return Result!size_t(0, Error(Status.resourceExhausted, "MCP stdio line exceeds its cap"));
                    if (length > 0 && line[length - 1] == '\r')
                        --length;
                    if (!length)
                        return Result!size_t(0, Error(Status.invalidArgument, "Empty MCP stdio line"));
                    return Result!size_t(length);
                }
                if (used < line.length)
                    line[used++] = current;
                else
                    tooLong = true;
            }
            const received = readPipe(file, diagnostic, bytes[], context);
            if (!received.ok())
                return received;
            first = 0;
            last = received.value;
            if (last == 0)
            {
                if (used != 0 || tooLong)
                {
                    used = 0;
                    tooLong = false;
                    return Result!size_t(0, Error(Status.invalidArgument, "Unterminated MCP stdio frame"));
                }
                return received;
            }
        }
    }
}

nothrow @nogc Error sendFrame(int file, int diagnostic, scope const(ubyte)[] message,
        scope ubyte[] compact, ref scope Context context)
{
    if (message.length > compact.length)
        return Error(Status.resourceExhausted, "MCP frame cannot fit its output buffer");
    size_t firstBreak = message.length;
    foreach (index, character; message)
    {
        if (character == '\r' || character == '\n')
        {
            firstBreak = index;
            break;
        }
    }
    if (firstBreak != message.length)
    {
        compact[0 .. firstBreak] = message[0 .. firstBreak];
        size_t written = firstBreak;
        foreach (character; message[firstBreak .. $])
        {
            if (character != '\r' && character != '\n')
                compact[written++] = character;
        }
        return sendPhysicalFrame(file, diagnostic, compact[0 .. written], context);
    }
    return sendPhysicalFrame(file, diagnostic, message, context);
}

nothrow @nogc private Error sendPhysicalFrame(int file, int diagnostic, scope const(ubyte)[] message,
        ref scope Context context)
{
    const sent = writePipe(file, diagnostic, message, context);
    return sent.code == Status.ok ? writePipe(file, diagnostic, cast(const(ubyte)[]) "\n", context) : sent;
}

final class StdioEndpoint
{
    private Operations operations;
    private size_t maximum;
    private ubyte[] memory;
    private LineReader reader;

    this(Protocol protocol, McpOptions options)
    {
        maximum = options.maxMessageBytes;
        operations = new Operations(protocol, maximum, options.maxInFlight, &writeResponse);
    }

    Error open()
    {
        memory = reserveStorage(maximum * 2 + 1);
        if (memory is null)
            return Error(Status.outOfMemory, "unable to reserve MCP stdio storage");
        const started = operations.open();
        if (started.code != Status.ok)
            releaseStorage(memory);
        return started;
    }

    Error run(ref Context context) nothrow @nogc
    {
        const handled = receive(context);
        Context teardown;
        const stopped = operations.close(teardown);
        return handled.code == Status.ok ? stopped : handled;
    }

    private Error receive(ref Context context) nothrow @nogc
    {
        scope line = memory[0 .. maximum + 1];
        const headers = Headers.init;
        for (;;)
        {
            const output = operations.check();
            if (output.code != Status.ok)
                return output;
            auto shorter = context.withDeadline(Deadline.afterMillis(25));
            const frame = reader.receive(0, -1, line, shorter);
            if (frame.error.code == Status.timedOut && !context.cancelled())
                continue;
            if ((!frame.ok() && frame.error.code != Status.invalidArgument
                    && frame.error.code != Status.resourceExhausted) || (frame.ok() && !frame.value))
                return frame.error;
            scope message = line[0 .. frame.value];
            // Decode once: the same envelope classifies cancellation and travels to the worker.
            const parsed = decodeEnvelope(message, maximum);
            Identity id;
            if (cancellation(message, parsed, id))
            {
                if (id.present)
                    operations.cancel(id, null);
                continue;
            }

            const posted = operations.submitDecoded(message, parsed, headers, context, false, true);
            if (!posted.ok())
                return posted.error;
        }
    }

    private Error writeResponse(scope const(ubyte)[] response, ref Context context) nothrow @nogc
    {
        return sendFrame(1, -1, response, memory[maximum + 1 .. $], context);
    }

    Error close(ref Context context) nothrow @nogc
    {
        const stopped = operations.close(context);
        if (stopped.code == Status.ok)
            releaseStorage(memory);
        return stopped;
    }
}
