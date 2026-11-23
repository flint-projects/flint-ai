/// Bounded owner/worker handoff for cooperative tool cancellation.
module flint.engine.mcp.operations;

import core.atomic : atomicLoad, atomicStore;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Background, CancelSource, Channel, Context, Deadline, startBackground;
import flint.conc.wait : waitUntil;
import flint.engine.mcp.jsonrpc : Envelope, Identity, decodeEnvelope, member, readIdentity;
import flint.engine.mcp.internal.registry : BeginTool;
import flint.engine.mcp.protocol : Headers, Protocol, Reply;
import flint.engine.mcp.sys.storage : releaseStorage, reserveStorage;

@safe:
package(flint.engine.mcp):

alias ReplyConsumer = Error delegate(scope const ref Reply, scope const(ubyte)[]) @safe nothrow @nogc;
alias StdioOutput = Error delegate(scope const(ubyte)[], ref Context) @safe nothrow @nogc;

private struct InputMetadata
{
    bool http;
    bool invalid;
    bool terminate;
    char[64] revisionText;
    char[128] methodText;
    char[1536] nameText;
    char[64] sessionText;
    size_t revisionLength;
    size_t methodLength;
    size_t nameLength;
    size_t sessionLength;

    void store(scope const ref Headers input) scope nothrow @nogc
    {
        http = input.http;
        invalid = input.invalid;
        terminate = input.terminate;
        revisionLength = input.release.length;
        methodLength = input.method.length;
        nameLength = input.name.length;
        sessionLength = input.session.length;
        revisionText[0 .. revisionLength] = input.release;
        methodText[0 .. methodLength] = input.method;
        nameText[0 .. nameLength] = input.name;
        sessionText[0 .. sessionLength] = input.session;
    }

    Headers view() const return nothrow @nogc
    {
        return Headers(http, invalid, revisionText[0 .. revisionLength],
                methodText[0 .. methodLength], nameText[0 .. nameLength], sessionText[0 .. sessionLength], terminate);
    }
}

private struct Operation
{
    bool occupied;
    bool detached;
    bool cancellable;
    shared bool began;
    shared bool completed;
    size_t length;
    Identity id;
    // The owner's decoding of the copied input, reused by the worker when present.
    Envelope envelope;
    Status envelopeStatus;
    size_t envelopeOffset;
    bool decoded;
    InputMetadata metadata;
    CancelSource cancellation;
    Reply reply;
    size_t responseLength;
}

/// The owner publishes copied input through the channel. The worker publishes a
/// reply through completed, and every slot remains reserved until both are finished.
final class Operations
{
    private Protocol protocol;
    private size_t maximum;
    private uint capacity;
    private size_t stride;
    private ubyte[] bytes;
    private Operation[64] operations;
    private Channel!uint queue;
    private StdioOutput stdio;
    // Frames are written under transport teardown only: a request cancellation must not cut a
    // reply that has started, or the next frame would continue the same stdout line.
    private CancelSource frames;
    private Background worker;
    private bool opened;
    private shared bool stopping;
    private shared bool stopped;
    private shared int failureStatus;
    this(Protocol protocol, size_t maximum, uint capacity, StdioOutput stdio = null)
    {
        this.protocol = protocol;
        this.maximum = maximum;
        this.capacity = capacity;
        this.stdio = stdio;
    }

    Error open()
    {
        const storage = maximum * 5 + 16_384;
        stride = storage;
        bytes = reserveStorage(storage * capacity);
        if (bytes is null)
            return Error(Status.outOfMemory, "unable to reserve MCP operation slots");
        auto channel = Channel!uint.create(64);
        if (!channel.ok())
        {
            releaseStorage(bytes);
            return channel.error;
        }
        auto teardown = CancelSource.create(Context.init, Deadline.none());
        if (!teardown.ok())
        {
            queue.close();
            releaseStorage(bytes);
            return teardown.error;
        }
        import core.lifetime : move;

        move(channel.value, queue);
        move(teardown.value, frames);
        const started = startBackground(&run, worker);
        if (started.code != Status.ok)
        {
            queue.close();
            frames.close();
            releaseStorage(bytes);
            return started;
        }
        opened = true;
        return Error.init;
    }

    Result!uint submit(scope const(ubyte)[] document, scope const ref Headers headers, ref Context parent,
            bool legacy, bool detach = false) nothrow @nogc
    {
        const cancellable = legacy || !headers.http;
        Result!Envelope parsed;
        if (cancellable && opened && !atomicLoad(stopping) && document.length <= maximum)
            parsed = decodeEnvelope(document, maximum);
        return admit(document, parsed, cancellable, headers, parent, legacy, detach);
    }

    /// Submit input whose envelope the owner already decoded with this queue's byte limit.
    Result!uint submitDecoded(scope const(ubyte)[] document, scope const ref Result!Envelope parsed,
            scope const ref Headers headers, ref Context parent, bool legacy, bool detach = false) nothrow @nogc
    {
        return admit(document, parsed, true, headers, parent, legacy, detach);
    }

    private Result!uint admit(scope const(ubyte)[] document, scope const ref Result!Envelope parsed,
            bool decoded, scope const ref Headers headers, ref Context parent, bool legacy, bool detach) nothrow @nogc
    {
        if (!opened || atomicLoad(stopping) || document.length > maximum)
            return Result!uint(uint.max, Error(Status.conflict, "MCP operation queue is closed"));
        Identity id;
        const cancellable = legacy || !headers.http;
        if (cancellable)
        {
            id = parsed.ok() ? parsed.value.id : Identity.init;
            if (id.present && activeId(id, headers.session))
                return Result!uint(uint.max, Error(Status.conflict, "MCP request ID is already active"));
        }

        const position = vacancy();
        if (position == uint.max)
            return Result!uint(uint.max, Error(Status.resourceExhausted, "MCP operation queue is full"));
        scope operation = &operations[position];
        auto source = CancelSource.create(parent, Deadline.none());
        if (!source.ok())
            return Result!uint(uint.max, source.error);

        import core.lifetime : move;

        move(source.value, operation.cancellation);
        auto storage = block(position);
        storage[0 .. document.length] = document;
        operation.length = document.length;
        operation.metadata.store(headers);
        operation.cancellable = cancellable;
        operation.id = id;
        operation.decoded = decoded;
        if (decoded)
        {
            operation.envelope = parsed.value;
            operation.envelopeStatus = parsed.error.code;
            operation.envelopeOffset = parsed.error.offset;
        }
        operation.occupied = true;
        operation.detached = detach;
        atomicStore(operation.began, false);
        atomicStore(operation.completed, false);
        const offered = queue.trySend(position);
        if (offered != Status.ok)
        {
            retire(position);
            return Result!uint(uint.max, Error(offered, "MCP operation queue rejected work"));
        }
        return Result!uint(position);
    }

    private uint vacancy() nothrow @nogc
    {
        foreach (position; 0 .. capacity)
        {
            scope operation = &operations[position];
            if (operation.occupied && operation.detached && atomicLoad(operation.completed))
                retire(position);
            if (!operation.occupied)
                return position;
        }
        return uint.max;
    }

    private void retire(uint position) nothrow @nogc
    {
        scope operation = &operations[position];
        operation.cancellation.close();
        operation.occupied = false;
        operation.detached = false;
    }

    bool entered(uint position) nothrow @nogc
    {
        return atomicLoad(operations[position].began);
    }

    bool complete(uint position) nothrow @nogc
    {
        return atomicLoad(operations[position].completed);
    }

    void detach(uint position, bool cancel) nothrow @nogc
    {
        if (cancel)
            operations[position].cancellation.cancel();
        operations[position].detached = true;
    }

    Error consume(uint position, scope ReplyConsumer consumer) nothrow @nogc
    {
        scope operation = &operations[position];
        if (!operation.occupied || !atomicLoad(operation.completed) || consumer is null)
            return Error(Status.conflict, "MCP operation reply is not available");
        scope (exit)
            retire(position);
        const bodySize = operation.responseLength;
        return consumer(operation.reply, block(position)[$ - bodySize .. $]);
    }

    private bool activeId(scope const ref Identity id, scope const(char)[] session) nothrow @nogc
    {
        foreach (ref operation; operations[0 .. capacity])
        {
            if (sameActive(operation, id, session))
                return true;
        }
        return false;
    }

    void cancel(scope const ref Identity id, scope const(char)[] session) nothrow @nogc
    {
        foreach (ref operation; operations[0 .. capacity])
        {
            if (sameActive(operation, id, session))
                operation.cancellation.cancel();
        }
    }

    private static bool sameActive(ref scope Operation operation, scope const ref Identity id,
            scope const(char)[] session) nothrow @nogc
    {
        return operation.occupied && operation.cancellable && !atomicLoad(operation.completed)
            && operation.id.matches(id) && operation.metadata.view().session == session;
    }

    Error check() const scope nothrow @nogc
    {
        const status = cast(Status) atomicLoad(failureStatus);
        return status == Status.ok ? Error.init : Error(status, "MCP operation output failed");
    }

    Error close(ref scope Context context) nothrow @nogc
    {
        if (!opened)
            return Error.init;
        atomicStore(stopping, true);
        queue.close();
        frames.cancel();
        foreach (ref operation; operations[0 .. capacity])
        {
            if (operation.occupied)
                operation.cancellation.cancel();
        }
        const deadline = context.withDeadline(Deadline.afterMillis(5_000));
        while (!atomicLoad(stopped))
        {
            if (deadline.deadline().monotonicNanoseconds <= Deadline.afterMillis(0).monotonicNanoseconds)
                return Error(Status.timedOut, "MCP worker is still retiring pending operations");
            waitUntil(Deadline.afterMillis(1));
        }
        worker.join();
        foreach (position; 0 .. capacity)
        {
            if (operations[position].occupied)
                retire(position);
        }
        frames.close();
        releaseStorage(bytes);
        opened = false;
        return Error.init;
    }

    private ubyte[] block(uint position) return scope nothrow @nogc
    {
        const start = stride * position;
        return bytes[start .. start + stride];
    }

    private void run() nothrow @nogc
    {
        scope (exit)
            atomicStore(stopped, true);
        for (;;)
        {
            const next = queue.tryReceive();
            if (next.ok())
                execute(next.value);
            else if (atomicLoad(stopping))
                return;
            else
                waitUntil(Deadline(Deadline.afterMillis(0).monotonicNanoseconds + 50_000));
        }
    }

    private void execute(uint position) nothrow @nogc
    {
        scope operation = &operations[position];
        scope (exit)
            atomicStore(operation.completed, true);
        operation.responseLength = 0;
        operation.reply = Reply.init;
        auto context = operation.cancellation.context();
        if (context.cancelled())
        {
            operation.reply.error = Error(Status.cancelled, "MCP operation was cancelled");
            return;
        }
        scope storage = block(position);
        const scratchEnd = maximum * 3 + 8192;
        const outputEnd = scratchEnd + maximum + 8192;
        auto work = RequestArena(storage[maximum .. scratchEnd]);
        auto output = RequestArena(storage[scratchEnd .. outputEnd]);
        scope const headers = operation.metadata.view();
        if (headers.terminate)
        {
            operation.reply.status = protocol.terminate(headers.session);
            return;
        }
        scope BeginTool began = () @safe nothrow @nogc { atomicStore(operation.began, true); };
        const message = storage[0 .. operation.length];
        if (operation.decoded)
        {
            const parsed = Result!Envelope(operation.envelope, Error(operation.envelopeStatus,
                    "invalid JSON-RPC envelope", operation.envelopeOffset));
            operation.reply = protocol.dispatchEnvelope(parsed, message, headers, work, output, context, began);
        }
        else
            operation.reply = protocol.dispatch(message, headers, work, output, context, began);
        if (context.cancelled())
        {
            operation.reply.error = Error(Status.cancelled, "MCP operation was cancelled");
            return;
        }
        if (operation.reply.body == Buffer.init)
            return;
        const borrowed = output.read(operation.reply.body, (scope const(ubyte)[] response) @safe nothrow @nogc {
            if (stdio !is null)
            {
                auto transport = frames.context();
                const sent = stdio(response, transport);
                if (sent.code != Status.ok && !atomicLoad(stopping))
                    atomicStore(failureStatus, cast(int) sent.code);
            }
            else
            {
                operation.responseLength = response.length;
                storage[$ - response.length .. $] = response;
            }
        });
        if (borrowed != Status.ok)
            operation.reply.error = Error(borrowed, "MCP worker reply was not live");
    }
}

bool cancellationRequest(scope const(ubyte)[] document, size_t maximum, out Identity target) nothrow @nogc
{
    const message = decodeEnvelope(document, maximum);
    return cancellation(document, message, target);
}

/// Classify an already decoded envelope as a cancellation notification.
bool cancellation(scope const(ubyte)[] raw, scope const ref Result!Envelope parsed, out Identity id) nothrow @nogc
{
    if (!parsed.ok() || parsed.value.id.present || parsed.value.verb() != "notifications/cancelled")
        return false;
    const params = parsed.value.params.get(raw);
    const request = member(params, "requestId");
    if (!request.ok() || !readIdentity(request.value.get(params), id))
        id = Identity.init;
    return true;
}
