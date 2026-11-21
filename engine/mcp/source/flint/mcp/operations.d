/// Bounded owner/worker handoff for cooperative tool cancellation.
module flint.mcp.operations;

import core.atomic : atomicLoad, atomicStore;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : CancelSource, Channel, Context, Deadline, startBackground;
import flint.conc.wait : waitUntil;
import flint.mcp.jsonrpc : Identity, decodeEnvelope, member, readIdentity;
import flint.mcp.protocol : Headers, Protocol, Reply;
import flint.mcp.sys.storage : releaseStorage, reserveStorage;

@safe:
package(flint.mcp):

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
        import core.lifetime : move;

        move(channel.value, queue);
        const started = startBackground(&run);
        if (started.code != Status.ok)
        {
            queue.close();
            releaseStorage(bytes);
            return started;
        }
        opened = true;
        return Error.init;
    }

    Result!uint submit(scope const(ubyte)[] document, scope const ref Headers headers, ref Context parent,
            bool legacy, bool detach = false) nothrow @nogc
    {
        if (!opened || atomicLoad(stopping) || document.length > maximum)
            return Result!uint(uint.max, Error(Status.conflict, "MCP operation queue is closed"));
        Identity id;
        const cancellable = legacy || !headers.http;
        if (cancellable)
        {
            const identity = decodeEnvelope(document, maximum);
            id = identity.ok() ? identity.value.id : Identity.init;
            if (id.present && activeId(id, headers.session))
                return Result!uint(uint.max, Error(Status.conflict, "MCP request ID is already active"));
        }

        const position = admit();
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

    private uint admit() nothrow @nogc
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
        foreach (position; 0 .. capacity)
        {
            if (operations[position].occupied)
                retire(position);
        }
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
        operation.reply = protocol.dispatch(storage[0 .. operation.length], headers, work, output,
                context, () @safe nothrow @nogc { atomicStore(operation.began, true); });
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
                const sent = stdio(response, context);
                if (sent.code != Status.ok && sent.code != Status.cancelled)
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
    if (!message.ok() || message.value.id.present || message.value.verb() != "notifications/cancelled")
        return false;
    const params = message.value.params.get(document);
    const request = member(params, "requestId");
    if (!request.ok() || !readIdentity(request.value.get(params), target))
        target = Identity.init;
    return true;
}
