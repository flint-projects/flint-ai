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
        auto accepted = scan(input, consumer);
        if (accepted.code != Status.ok)
            failure = accepted.code;
        return accepted;
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

    // Lines are located in bulk. A line that ends inside the current fragment is parsed in place and
    // only a line split across fragments is staged, so the hot path copies each data byte once.
    private Error scan(scope const(ubyte)[] input, scope SseConsumer consumer) scope
    {
        size_t cursor;
        while (cursor < input.length)
        {
            if (skipLf)
            {
                skipLf = false;
                if (input[cursor] == '\n')
                {
                    ++cursor;
                    continue;
                }
            }
            const end = terminator(input, cursor);
            const run = end - cursor;
            if (run > lineBytes.length - lineLength)
                return Error(Status.resourceExhausted, "SSE line exceeds the configured limit");
            if (end == input.length)
            {
                lineBytes[lineLength .. lineLength + run] = input[cursor .. end];
                lineLength += run;
                return Error.init;
            }
            skipLf = input[end] == '\r';
            Error result;
            if (lineLength == 0)
                result = completeLine(input[cursor .. end], consumer);
            else
            {
                lineBytes[lineLength .. lineLength + run] = input[cursor .. end];
                const staged = lineLength + run;
                lineLength = 0;
                result = completeLine(lineBytes[0 .. staged], consumer);
            }
            if (result.code != Status.ok)
                return result;
            cursor = end + 1;
        }
        return Error.init;
    }

    /// Index of the next CR or LF at or after `cursor`, or `input.length`.
    private static size_t terminator(scope const(ubyte)[] input, size_t cursor) pure
    {
        enum ulong ones = 0x0101_0101_0101_0101UL;
        enum ulong highs = 0x8080_8080_8080_8080UL;
        while (input.length - cursor >= 8)
        {
            const ubyte[8] lane = input[cursor .. cursor + 8];
            ulong word;
            static foreach (shift; 0 .. 8)
                word |= cast(ulong) lane[shift] << (shift * 8);
            const lf = word ^ (ones * '\n');
            const cr = word ^ (ones * '\r');
            // A zero byte in either XOR marks a terminator. The test may report a false candidate
            // only above a true zero byte, so the byte loop below resolves the exact position.
            if ((((lf - ones) & ~lf) | ((cr - ones) & ~cr)) & highs)
                break;
            cursor += 8;
        }
        while (cursor < input.length && input[cursor] != '\r' && input[cursor] != '\n')
            ++cursor;
        return cursor;
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
