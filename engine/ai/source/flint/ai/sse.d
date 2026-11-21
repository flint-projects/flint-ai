/// Incremental server-sent events over caller-owned storage.
module flint.ai.sse;

import flint.arena : Error, Status;

@safe:

/// The event type and its joined data bytes are valid for this callback.
alias SseConsumer = Error delegate(scope const(char)[] type, scope const(ubyte)[] data) @safe nothrow @nogc;

/// Parse SSE across arbitrary transport chunk boundaries without allocating.
struct SseParser
{
@safe:
nothrow:
@nogc:

    private ubyte[] lineBytes;
    private ubyte[] eventBytes;
    private size_t lineLength;
    private size_t eventLength;
    private char[256] eventName;
    private uint nameLength;
    private bool firstLine = true;
    private bool skipLf;
    private bool dataSeen;
    private bool feeding;
    private Status failure;

    @disable this(this);
    @disable void opAssign(SseParser value);

    /// Borrow separate workspaces for the current line and the joined event payload.
    this(return scope ubyte[] line, return scope ubyte[] event)
    {
        const limit = 1024 * 1024;
        if (line.length == 0 || line.length > limit + 9 || event.length == 0 || event.length > limit)
            failure = Status.invalidArgument;
        else
        {
            lineBytes = line;
            eventBytes = event;
        }
    }

    /// Consume fragments. Callback rejection is terminal for this parser.
    Error feed(scope const(ubyte)[] input, scope SseConsumer consumer) scope
    {
        if (failure != Status.ok)
            return Error(failure, "SSE parser has stopped");
        if (feeding)
            return Error(Status.conflict, "SSE callback cannot reenter its parser");
        if (consumer is null || eventBytes.length == 0)
            return Error(Status.invalidArgument, "SSE storage and callback are required");
        feeding = true;
        scope (exit)
            feeding = false;
        foreach (value; input)
        {
            auto accepted = accept(value, consumer);
            if (accepted.code != Status.ok)
            {
                failure = accepted.code;
                return accepted;
            }
        }
        return Error.init;
    }

    /// Confirm that the transport ended between complete events.
    Error finish() const scope
    {
        if (failure != Status.ok)
            return Error(failure, "SSE parser has stopped");
        if (lineLength != 0 || dataSeen || nameLength != 0)
            return Error(Status.ioError, "transport ended within an SSE event");
        return Error.init;
    }

    /// Keep the parser's current callback state at a stable address.
    void opPostMove(scope const ref SseParser original) scope
    {
        assert(!original.feeding, "cannot move an active SSE parser");
    }

    private Error accept(ubyte value, scope SseConsumer consumer) scope
    {
        const suppress = skipLf && value == '\n';
        skipLf = value == '\r';
        if (suppress)
            return Error.init;
        if (value == '\r' || value == '\n')
        {
            const result = completeLine(lineBytes[0 .. lineLength], consumer);
            lineLength = 0;
            return result;
        }
        if (lineLength == lineBytes.length)
            return Error(Status.resourceExhausted, "SSE line exceeds the configured limit");
        lineBytes[lineLength++] = value;
        return Error.init;
    }

    private Error completeLine(scope const(ubyte)[] line, scope SseConsumer consumer) scope
    {
        if (firstLine)
        {
            firstLine = false;
            if (line.length >= 3 && line[0 .. 3] == cast(const(ubyte)[]) "\xef\xbb\xbf")
                line = line[3 .. $];
        }
        if (line.length == 0)
            return dispatch(consumer);
        size_t split;
        while (split < line.length && line[split] != ':')
            ++split;
        const field = cast(const(char)[]) line[0 .. split];
        auto content = split < line.length ? line[split + 1 .. $] : line[$ .. $];
        if (content.length != 0 && content[0] == ' ')
            content = content[1 .. $];
        switch (field)
        {
        case "data":
            return appendData(content);
        case "event":
            if (content.length > eventName.length)
                return Error(Status.resourceExhausted, "SSE event name is too long");
            nameLength = cast(uint) content.length;
            eventName[0 .. nameLength] = cast(const(char)[]) content;
            return Error.init;
        default:
            return Error.init;
        }
    }

    private Error appendData(scope const(ubyte)[] content) scope
    {
        const separator = cast(size_t) dataSeen;
        const available = eventBytes.length - eventLength;
        if (separator > available || content.length > available - separator)
            return Error(Status.resourceExhausted, "SSE event exceeds the configured limit");
        if (dataSeen)
            eventBytes[eventLength++] = '\n';
        eventBytes[eventLength .. eventLength + content.length] = content;
        eventLength += content.length;
        dataSeen = true;
        return Error.init;
    }

    private Error dispatch(scope SseConsumer consumer) scope
    {
        const kind = nameLength == 0 ? "message" : eventName[0 .. nameLength];
        const result = dataSeen ? consumer(kind, eventBytes[0 .. eventLength]) : Error.init;
        eventLength = 0;
        nameLength = 0;
        dataSeen = false;
        return result;
    }
}
