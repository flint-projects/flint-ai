module flint.ai.sse_behavior;

import flint.ai.sse : SseParser;
import flint.arena : Error, Status;

@safe:

@("all byte splits preserve CRLF, UTF-8 and joined data")
unittest
{
    enum wire = "\xef\xbb\xbf: hello\r\nevent: sample\r\ndata: fox 🦊\r\ndata: café\r\n\r\n" ~ "data:tail\r\r";
    const input = cast(const(ubyte)[]) wire;
    foreach (split; 0 .. input.length + 1)
    {
        ubyte[128] line, event;
        scope SseParser parser = SseParser(line[], event[]);
        uint seen;
        scope collect = (scope const(char)[] type, scope const(ubyte)[] bytes) @safe nothrow @nogc {
            ++seen;
            const text = cast(const(char)[]) bytes;
            assert((seen == 1 && type == "sample" && text == "fox 🦊\ncafé") || (seen == 2
                    && type == "message" && text == "tail"));
            return Error.init;
        };
        assert(parser.feed(input[0 .. split], collect).code == Status.ok);
        assert(parser.feed(input[split .. $], collect).code == Status.ok);
        assert(parser.finish().code == Status.ok && seen == 2);
    }
}

@("exact one-mebibyte data with BOM passes and the next byte fails")
unittest
{
    enum limit = 1024 * 1024;
    auto line = new ubyte[limit + 9];
    auto event = new ubyte[limit];
    auto wire = new ubyte[limit + 11];
    wire[0 .. 9] = cast(const(ubyte)[]) "\xef\xbb\xbfdata: ";
    wire[9 .. limit + 9] = 'x';
    wire[limit + 9 .. $] = cast(const(ubyte)[]) "\n\n";
    uint seen;
    scope receive = (scope const(char)[] type, scope const(ubyte)[] data) @safe nothrow @nogc {
        assert(type == "message" && data.length == limit);
        ++seen;
        return Error.init;
    };
    auto exact = SseParser(line, event);
    assert(exact.feed(wire, receive).code == Status.ok && seen == 1);
    auto excess = SseParser(line, event);
    wire[limit + 9] = 'y';
    assert(excess.feed(wire, receive).code == Status.resourceExhausted && seen == 1);
}

@("incomplete events, overflow and consumer cancellation stay terminal")
unittest
{
    ubyte[20] firstLine, secondLine, thirdLine;
    ubyte[6] firstOutput, secondOutput, thirdOutput;
    scope SseParser incomplete = SseParser(firstLine[], firstOutput[]);
    scope SseParser oversized = SseParser(secondLine[], secondOutput[]);
    scope SseParser stopped = SseParser(thirdLine[], thirdOutput[]);
    uint calls;
    scope reject = (scope const(char)[], scope const(ubyte)[]) @safe nothrow @nogc {
        ++calls;
        return Error(Status.cancelled, "fixture cancelled");
    };
    assert(incomplete.feed(cast(const(ubyte)[]) "data: abc\n", reject).code == Status.ok);
    assert(incomplete.finish().code == Status.ioError);
    assert(oversized.feed(cast(const(ubyte)[]) "data:abc\ndata:def\n\n", reject).code == Status.resourceExhausted);
    assert(oversized.finish().code == Status.resourceExhausted && calls == 0);
    assert(stopped.feed(cast(const(ubyte)[]) "data:abc\n\ndata:def\n\n", reject).code == Status.cancelled);
    assert(stopped.feed(null, reject).code == Status.cancelled && calls == 1);
}
